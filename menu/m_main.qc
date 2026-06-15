
float menu_active;

float splash_time;

string(string line) Menu_MapListEntryFromLine =
{
    float argc = tokenize(line);
    if (argc <= 0)
        return "";

    string token = argv(0);
    if (token == "//" || substring(token, 0, 1) == "#")
        return "";

    string lower = strtolower(token);
    float len = strlen(token);

    if (len > 5 && substring(lower, 0, 5) == "maps/")
    {
        token = substring(token, 5, len - 5);
        lower = strtolower(token);
        len = strlen(token);
    }

    if (len > 4 && substring(lower, len - 4, 4) == ".bsp")
        token = substring(token, 0, len - 4);

    return token;
};

// Pick a random map name from a simple map-list file. One map per line;
// blank lines and comment lines are skipped. Entries may be either bare
// map names (`2fort`) or BSP-style paths (`maps/2fort.bsp`).
//
// Two passes: count valid lines, then re-open and grab the Nth.  QC
// has no dynamic arrays and string temporaries can evaporate between
// frames; a second fopen is simpler than juggling preallocated buffers.
string(string path) Menu_PickMapFromListedFile =
{
    float f = fopen(path, FILE_READ);
    if (f < 0)
        return "";

    float count = 0;
    string line = fgets(f);
    while (line)
    {
        if (Menu_MapListEntryFromLine(line) != "")
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

    f = fopen(path, FILE_READ);
    if (f < 0)
        return "";

    string chosen = "";
    float i = 0;
    line = fgets(f);
    while (line)
    {
        string entry = Menu_MapListEntryFromLine(line);
        if (entry != "")
        {
            if (i == pick)
            {
                chosen = entry;
                break;
            }
            i = i + 1;
        }
        line = fgets(f);
    }
    fclose(f);

    return chosen;
};

// Single source of truth for the map cycle: data/maps.txt — used by the
// menu backdrop picker, the F2 rcon panel, and the server's round-end
// cycle. The legacy gamedir-level maps.txt fallback was removed so admins
// don't have to keep two copies in sync.
string() Menu_PickMapFromFile =
{
    return Menu_PickMapFromListedFile("data/maps.txt");
};

// Boot the menu-backdrop listen server on `menumap`.  m_init calls this UNLESS the engine flagged
// cl_launchintogame (a command-line +connect / +map / demo), in which case the backdrop is skipped so the
// launch command lands where intended instead of being clobbered by the backdrop's own `map`.
void(string menumap) Menu_StartBackdrop =
{
	// Force >=2 maxclients + deathmatch so FTE's PAUSE_AUTO logic doesn't freeze the single-slot listen
	// server (and halt the backdrop camera cycling) while a menu/console is up.  Make it invisible +
	// unjoinable (sv_public -1 + random password) so LAN/master browsers can't join the backdrop.
	localcmd("sv_public -1\n");
	localcmd(sprintf("password backdrop_%g_%g\n", random() * 1000000, gettime(0)));
	localcmd("hostname \"menu backdrop (private)\"\n");
	localcmd("set cl_menu_backdrop_active 1\n");
	// sv_backdrop_pending latch — worldspawn consumes it into sv_backdrop; a bare console `map X` never
	// sets it, so it comes up as a real game.
	localcmd("set sv_backdrop_pending 1\n");
	// Bind the backdrop socket to port 0 — the OS assigns a free ephemeral port
	// (engine net_wins.c treats 0 as ephemeral), so the backdrop NEVER occupies
	// 27500, leaving it free for a real local/dedicated server.  The local
	// backdrop client still connects over the internal loopback socket.
	localcmd("sv_port 0\n");
	localcmd("deathmatch 1\n");
	localcmd("maxclients 2\n");
	// nettest (P26): on-demand mount the backdrop map's game if it's an external (fs_load) one.
	create_server_mount_for_map(menumap, 0);
	localcmd(sprintf("map %s\n", menumap));
	localcmd("togglemenu\n");
};

void() m_init =
{
	splash_time = 0;
	registercommand("togglemenu2");
	setcursormode(TRUE,"gfx/xhair", [16, 16], cvar("vid_conautoscale"));
	menu_font = loadfont("hud", "gfx/RobotoEB", "8 12 16 18 24 36 48 60 72", -1, 0, 0);
	current_menu = MENU_MAIN;
	localcmd("set _nettest_menu_active 0\n");

	// UI sound effects for the floating main menu — hover-enter
	// plays click.ogg, click registers play submit.ogg.  See
	// Float_TextOption in menu/m_menu.qc.
	precache_sound("sounds/ui/click.ogg");
	precache_sound("sounds/ui/submit.ogg");

	// Permanent binds — not configurable
	localcmd("bind escape togglemenu\n");
	localcmd("bind ` toggleconsole\n");
	localcmd("bind ~ toggleconsole\n");
	localcmd("bind f9 screenshot\n");
	localcmd("bind f10 quit\n");

	Menu_LoadConfig();

	// nettest (P26): build data/maps_index.txt now (offline, cheap — no game is mounted) so the
	// create-server menu has its per-game map list ready. With fs_lazyaddons 1 the external games
	// aren't mounted at boot, so the menu reads this index instead of scanning mounted searchpaths.
	localcmd("fs_indexmaps\n");

	// Background map — start a local listen server on this map so the main
	// menu renders over a live world instead of a black void.  The map's
	// "camera" entities cycle via the team-select camera system (the local
	// player is TEAM_NONE on launch).  The togglemenu afterwards reopens the
	// main menu, because the engine auto-closes it when transitioning into
	// a map load.  Blank cl_menumap to disable the whole thing.
	//
	// Map picked from data/maps.txt first (with legacy maps.txt fallback),
	// so the backdrop and the live server map cycle can share one editable
	// pool file. cl_menumap is used as the fallback when both files are
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
	// 1 = m_draw forces vid_conautoscale based on screen height (default,
	// keeps the menu legible on 4K + 720p without per-user tuning).
	// 0 = m_draw leaves vid_conautoscale alone, user controls it directly.
	registercvar("cl_menu_autoscale", "1", 0);
	string menumap = Menu_PickMapFromFile();
	if (menumap == "")
		menumap = cvar_string("cl_menumap");
	// nettest: SKIP the backdrop when the user launched straight into a game.  The engine sets
	// cl_launchintogame=1 from a command-line +connect / +map / demo (in Host_Init, right before M_Init, with
	// CVAR_NORESET so the gamedir-change reset doesn't wipe it).  Without this, the backdrop's own `map` would
	// clobber the launch command and dump the user back on the menu world.  Reliable because the engine sets
	// the cvar before m_init runs — unlike watching constate, where the launch command runs LATER (boot cbuf).
	if (menumap != "" && menumap != "none" && cvar("cl_launchintogame") == 0)
		Menu_StartBackdrop(menumap);
};

vector() randomofs = { return [random() - 0.5, random() - 0.5] * 2; };

// Tracks last-frame "we're in a real game" state so m_draw can fire m_close
// only on the rising edge (transition into a real server). Without the edge
// gate the menu would slam shut every frame whenever the user opened it
// while in-game (ESC during a match), defeating its own purpose.
float prev_in_real_game;
// Same edge-gate idea, but for the connecting/downloading phase.  Catches
// `connect <ip>` typed at the console: the menu was over the loading
// progress and the console was open on top, both hiding the actual
// progress indicator.  Closing both lets the loading panel surface.
float prev_in_connect;
// Tracks the "loading panel is up but main menu isn't" state so we can
// bump keydest to menu mode for input routing on the rising edge and
// restore keydest=0 when loading ends.
float prev_loading_active;

// One-shot init flag for m_draw — the very first frame initialises every
// rising-edge tracker to TRUE so the boot sequence (backdrop server
// connect/load cycles `constate=connecting` during normal startup)
// doesn't spuriously fire the connect-edge handler and slam the menu
// shut + open the console at game start.
float m_draw_inited;

// Forward decl — m_open is defined further down. m_draw needs to call
// it on the disconnect→backdrop trailing edge to re-push kdm_menu.
void() m_open;

// mm_returning_to_backdrop is declared in m_menu.qc (compiles first).
// Set by Menu_DisconnectAndReturnToMenuMap; the connect-edge handler
// below skips its m_close + toggleconsole branch while it's TRUE so the
// menu stays visibly up through the disconnect→backdrop map-load (no
// console flash). Cleared on the trailing edge once we've landed on
// the backdrop.

void(vector screensize) m_draw =
{
//	clearscene();

	// First-frame seeding — without this, every prev_* tracker starts at
	// 0 and the boot sequence (backdrop server connect cycling through
	// constate="connecting") trips the connect-edge handler immediately,
	// closing the main menu and toggling the console open as if the
	// user had typed `connect <ip>`.  Setting them to TRUE on the very
	// first frame means a TRUE state on that frame doesn't qualify as
	// a rising edge.
	if (!m_draw_inited)
	{
		m_draw_inited = TRUE;
		prev_in_real_game   = TRUE;
		prev_in_connect     = TRUE;
		prev_loading_active = TRUE;
	}

	// Auto-close when the user transitions from menu/backdrop into a real
	// game via any path the menu didn't initiate (typically `connect <ip>`
	// from the console). The Connect/Disconnect menu buttons already call
	// m_close() explicitly, so this only matters for console-driven paths.
	// Gate on rising edge so opening the menu mid-game doesn't insta-close.
	float in_real_game =
	    (serverkey("constate") == "active") &&
	    (serverkey("sv_backdrop") != "1");
	if (menu_active && in_real_game && !prev_in_real_game)
		m_close();
	prev_in_real_game = in_real_game;

	// While the loading panel is up but the main menu isn't, route input
	// to the menu (SUI) so the disconnect button is clickable AND the
	// menu's Menu_InputEvent handles ~/toggleconsole — without this,
	// keydest stays at 0 (game) during the loading plaque and the user
	// has to press ESC first to bring the menu up before ~ works.
	// Restore keydest=0 on the trailing edge so game input resumes once
	// loading is done.  (When menu_active is TRUE the existing m_open /
	// m_close paths own keydest, so we leave them alone.)
	float loading_active = m_loading_should_show() && !menu_active;
	if (loading_active && !prev_loading_active)
		setkeydest(2);
	else if (!loading_active && prev_loading_active && !menu_active)
		setkeydest(0);
	prev_loading_active = loading_active;

	// Same close-on-rising-edge for the CONNECTING / DOWNLOADING phase.
	// `connect <ip>` from console drops the user into a state where the
	// engine is downloading content, but the main menu (still on top)
	// hides the progress.  Detecting the rising edge here lets us drop
	// the menu out of the way as soon as the load actually starts, AND
	// dismiss the console on top.
	//
	// Gate on `menu_active` BEFORE m_close: when the user typed connect
	// from console, the menu was up underneath and the console on top —
	// closing both is the right outcome.  When the user clicked a
	// Connect button in the UI, that button already called m_close
	// (menu_was_open=FALSE here), so we skip the toggleconsole — the
	// console wasn't open and unconditionally calling toggleconsole
	// would OPEN it, which is the opposite of what the user wants.
	float in_connect = (serverkey("constate") == "connecting")
	                || m_loading_should_show();
	if (in_connect && !prev_in_connect)
	{
		float menu_was_open = menu_active;
		// mm_returning_to_backdrop: we're mid-Disconnect-to-menumap and
		// want the menu to stay up through the load. The toggleconsole
		// here exists for the `connect <ip> from console` scenario
		// (menu underneath, console on top — toggle closes the console)
		// and would do the wrong thing for our path: close the menu
		// AND potentially OPEN the console if it wasn't already up.
		if (menu_was_open && !mm_returning_to_backdrop)
		{
			m_close();
			localcmd("toggleconsole\n");
		}
	}

	// Trailing edge for disconnect→backdrop: fire the moment in_connect
	// falls (loading+connecting both done). Re-opens the main menu so the
	// user lands on it instead of a blank backdrop. Doesn't depend on
	// sv_backdrop serverinfo — that key has propagation latency that
	// would leave the menu blank for a few frames between load-finished
	// and serverinfo-arrived. Engine's PF_cl_setkeydest unlinks the
	// MenuQC menu from kdm_menu during the map tear-down, so even with
	// menu_active=TRUE the menu doesn't render until we re-push via
	// setkeydest(2); m_open does that.
	if (mm_returning_to_backdrop && !in_connect && prev_in_connect)
	{
		mm_returning_to_backdrop = FALSE;
		m_open();
	}
	prev_in_connect = in_connect;


	// Auto-pick a sane vid_conautoscale based on physical screen height
	// so the menu doesn't render at headache-tiny font sizes on 4K
	// displays or pixelated mush on 720p.  GATED on cl_menu_autoscale
	// so the user can opt out — set `cl_menu_autoscale 0` from console
	// to take control of vid_conautoscale manually (e.g. force 1 for
	// native pixels on a 1440p display).
	if (cvar("cl_menu_autoscale"))
	{
		vector realsize = getproperty(VF_SCREENPSIZE);
		float target_conauto = 2;
		if (realsize_y < 600) target_conauto = 1;
		else if (realsize_y < 1440) target_conauto = 2;
		else target_conauto = 4;

		if (target_conauto != cvar("vid_conautoscale"))
			localcmd(sprintf("vid_conautoscale %f\n", target_conauto));
	}
	
	
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

void() mm_flush_name;  // defined in m_menu.qc

void() m_close =
{
	// Commit any pending name-field edit before saving — otherwise a
	// rename typed into the main menu and then dismissed with Esc
	// wouldn't reach the server (we no longer cvar_set per keystroke).
	mm_flush_name();
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
		// Enter on the name field commits the pending name to the `name`
		// cvar / server. Let the event continue to SUI's default handling
		// so focus behavior is preserved — we just piggy-back a flush.
		if ((scanx == K_ENTER || scanx == K_KP_ENTER)
		    && sui_is_last_clicked("mm_name"))
			mm_flush_name();

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
		case "toggleconsole":
			// Let ~/backtick drop the console over the menu without
			// needing to close the menu first. The menu stays visible
			// behind the console (engine handles layering).
			localcmd("toggleconsole\n");
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
	// Respect the engine's requested mode. wantmode is set by FTE's
	// MP_Toggle(int mode) caller chain (engine pr_menu.c):
	//   0 = engine wants the menu CLOSED (Menu_PopAll forced-unlink path,
	//       MP_TryRelease, etc). If we were already closed, do nothing —
	//       calling m_open here would re-grab kdm_menu after the engine
	//       just unlinked it, which trips its "Menuqc retook key grabs
	//       when ordered to yield. Killing." guard and unloads the
	//       entire MenuQC VM (after which ESC falls back to FTE's
	//       legacy Quake menu).
	//   1 = engine wants the menu OPEN (normal togglemenu / ESC path
	//       when nothing else handled it).
	//   anything else = pure flip-flop (legacy callers).
	if (wantmode == 0)
	{
		if (menu_active) m_close();
		return;
	}
	if (wantmode == 1)
	{
		if (!menu_active) m_open();
		return;
	}
	if (menu_active) m_close();
	else m_open();
};

void() m_shutdown =
{
	Menu_SaveConfig();
	localcmd("set _nettest_menu_active 0\n");
};
