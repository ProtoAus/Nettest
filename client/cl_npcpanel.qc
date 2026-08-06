// ============================================================
//  client/cl_npcpanel.qc  -  F4 in-game NPC test panel
//
//  Same shape as the F1 debug panel (cl_debugpanel.qc): a floating,
//  draggable CSQC overlay with cursor takeover, drawn over live
//  gameplay so the server keeps ticking underneath.  F1 is cvars,
//  F2 the server browser, F3 car tuning; F4 is this.
//
//  It reuses cl_debugpanel.qc's visual constants and Debug_Button
//  outright rather than restating them, so the two panels cannot
//  drift apart visually.  That file compiles earlier in cl_progs.src.
//
//  WHY A PANEL AND NOT BINDS.  Every spawn goes through
//  `cmd ai_spawn <class>`, which a bind can do just as well — but a
//  bind cannot show you the CLASS LIST, cannot page through 37 of
//  them, and cannot show live per-monster state next to the button
//  that spawned it.  The status readout is the point: every bug in
//  the NPC work so far showed up as the wrong SCHEDULE, and that is
//  what the right-hand column prints.
//
//  Compiled for CSQC only via cl_progs.src.
// ============================================================

const float NPC_MAX_CLASSES = 48;
const float NPC_ROW_H       = 17;
const float NPC_PAD         = 6;
const float NPC_TITLE_H     = 24;
const float NPC_TAB_H       = 20;
const float NPC_COLS        = 2;

const float NPCTAB_SPAWN  = 0;
const float NPCTAB_STATUS = 1;
const float NPCTAB_COUNT  = 2;

string npc_cls_name  [NPC_MAX_CLASSES];	// classname, without the monster_ prefix
string npc_cls_label [NPC_MAX_CLASSES];	// what the button says
float  npc_cls_group [NPC_MAX_CLASSES];	// 0 grunts/allies, 1 aliens, 2 static/water/air, 3 heavy
float  npc_cls_count;

float  npc_panel_open;
float  npc_panel_init;
vector npc_panel_pos;
vector npc_panel_size;
float  npc_panel_dragging;
vector npc_panel_drag_offset;
float  npc_cursor_active;
float  npc_panel_tab;
float  npc_spawn_count;			// how many each button spawns; seeded in NPC_PanelInit
					// (an initialiser here would make fteqcc treat it as a const)
float  npc_scroll;

void(string cls, string label, float grp) NPC_Add =
{
	if (npc_cls_count >= NPC_MAX_CLASSES)
		return;
	npc_cls_name [npc_cls_count] = cls;
	npc_cls_label[npc_cls_count] = label;
	npc_cls_group[npc_cls_count] = grp;
	npc_cls_count = npc_cls_count + 1;
};

// The registry, mirroring AI_ClassHasAI in sv_ai_core.qc.  It is a hand-kept
// list because the server owns the real one and CSQC cannot enumerate it; the
// panel prints a plain error from the server if a class is not registered, so
// the two drifting apart is visible rather than silent.
void() NPC_PanelInit =
{
	if (npc_panel_init)
		return;
	npc_panel_init = TRUE;

	npc_spawn_count = 1;
	npc_panel_pos  = [90, 70];
	npc_panel_size = [430, 330];

	// --- 0: humans, allies, the gun shooters ---
	NPC_Add("monster_human_grunt",       "grunt",         0);
	NPC_Add("monster_human_grunt_ally",  "grunt ally",    0);
	NPC_Add("monster_male_assassin",     "male assassin", 0);
	NPC_Add("monster_human_assassin",    "assassin",      0);
	NPC_Add("monster_hwgrunt",           "hwgrunt",       0);
	NPC_Add("monster_robogrunt",         "robogrunt",     0);
	NPC_Add("monster_shocktrooper",      "shocktrooper",  0);
	NPC_Add("monster_th_grunt_repel",    "repel grunt",   0);
	NPC_Add("monster_barney",            "barney ^2ALLY", 0);
	NPC_Add("monster_otis",              "otis ^2ALLY",   0);
	NPC_Add("monster_bodyguard",         "bodyguard",     0);
	NPC_Add("monster_human_medic_ally",  "medic ^2ALLY",  0);
	NPC_Add("monster_human_torch_ally",  "torch ^2ALLY",  0);
	NPC_Add("monster_scientist",         "scientist ^3FLEES", 0);

	// --- 1: aliens ---
	NPC_Add("monster_headcrab",          "headcrab",      1);
	NPC_Add("monster_zombie",            "zombie",        1);
	NPC_Add("monster_zombie_barney",     "zombie barney", 1);
	NPC_Add("monster_zombie_soldier",    "zombie soldier",1);
	NPC_Add("monster_alien_slave",       "alien slave",   1);
	NPC_Add("monster_alien_grunt",       "alien grunt",   1);
	NPC_Add("monster_houndeye",          "houndeye",      1);
	NPC_Add("monster_bullchicken",       "bullsquid",     1);
	NPC_Add("monster_pitdrone",          "pitdrone",      1);
	NPC_Add("monster_gonome",            "gonome",        1);
	NPC_Add("monster_alien_voltigore",   "voltigore",     1);
	NPC_Add("monster_cockroach",         "roach ^3FLEES", 1);

	// --- 2: static, aquatic, airborne ---
	NPC_Add("monster_sentry",            "sentry",        2);
	NPC_Add("monster_miniturret",        "miniturret",    2);
	NPC_Add("monster_turret",            "turret",        2);
	NPC_Add("monster_barnacle",          "barnacle ^1UP", 2);
	NPC_Add("monster_leech",             "leech ^5WATER", 2);
	NPC_Add("monster_ichthyosaur",       "ichthy ^5WATER",2);
	NPC_Add("monster_alien_controller",  "controller",    2);

	// --- 3: the heavy ones ---
	NPC_Add("monster_gargantua",         "gargantua",     3);
	NPC_Add("monster_babygarg",          "babygarg",      3);
	NPC_Add("monster_stukabat",          "stukabat",      3);
	NPC_Add("monster_kingpin",           "kingpin",       3);
};

float() NPC_PanelOpen = { return npc_panel_open; };

void() NPC_PanelToggle =
{
	NPC_PanelInit();
	npc_panel_open = !npc_panel_open;

	if (npc_panel_open && !npc_cursor_active)
	{
		setcursormode(TRUE, "gfx/xhair", '16 16 0', cvar("vid_conautoscale"));
		npc_cursor_active = 1;
	}
	else if (!npc_panel_open && npc_cursor_active)
	{
		setcursormode(FALSE);
		npc_cursor_active = 0;
	}
};

float(float evtype, float scanx, float chary, float devid) NPC_PanelInputEvent =
{
	if (!npc_panel_open)
		return FALSE;

	if (evtype == IE_KEYDOWN && (scanx == K_F4 || scanx == K_ESCAPE))
	{
		NPC_PanelToggle();
		return TRUE;
	}

	// FORWARD into SUI, then absorb.  This panel used to swallow the mouse and
	// return TRUE without ever handing the event on - which is not "the same
	// contract the F1 panel has", it is the opposite of it.  SUI is where the
	// cursor position lives and where sui_action_element does its hit testing, so
	// an event that never reaches it means no widget is ever under the pointer:
	// every button drew correctly, highlighted never, and did nothing when
	// clicked.  The whole bench looked present and was completely inert.
	//
	// F1 (cl_debugpanel.qc:297), F2 (cl_serverpanel.qc:1026) and F3
	// (cl_carpanel.qc:412) all do exactly this; F4 was the only one that did not.
	//
	// Returning TRUE after forwarding is what stops the click also reaching
	// +attack, which is the part the old code got right.
	sui_input_event(evtype, scanx, chary, devid);
	return TRUE;
};

// ============================================================
//  drawing
// ============================================================
void() NPC_DrawTitleBar =
{
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	sui_fill([0, 0], [npc_panel_size_x, NPC_TITLE_H], DBG_TITLE_BG, 1, 0);
	sui_text([NPC_PAD, 8], DBG_FONT, "NPC test bench  ^7(F4)", DBG_TEXT_1, 1, 0);

	// Drag handle.  Registered narrower than the bar so it does not swallow the
	// close button's clicks.
	sui_action_element([0, 0], [npc_panel_size_x - 26, NPC_TITLE_H],
	                   "npc_titlebar", sui_noop);

	if (Debug_Button("npc_close", [npc_panel_size_x - 22, 4], [18, 16], "X",
	                 DBG_BTN_CLOSE, DBG_BTN_CLOSE_BORD))
		NPC_PanelToggle();
};

void(string label, float tab_id, float x, float w) NPC_DrawOneTab =
{
	vector col = DBG_BTN_OFF;
	if (npc_panel_tab == tab_id)
		col = DBG_BTN_ON;
	if (Debug_Button(strcat("npc_tab", ftos(tab_id)), [x, NPC_TITLE_H],
	                 [w, NPC_TAB_H - 2], label, col, DBG_BTN_OFF_BORD))
	{
		npc_panel_tab = tab_id;
		npc_scroll = 0;
	}
};

void() NPC_DrawTabStrip =
{
	float w = npc_panel_size_x * 0.5;
	NPC_DrawOneTab("Spawn",  NPCTAB_SPAWN,  0, w);
	NPC_DrawOneTab("Status", NPCTAB_STATUS, w, npc_panel_size_x - w);
};

// The spawn grid.  Two columns of buttons; clicking one issues
// `cmd ai_spawn <class> <n>` to the server, which places it where the player is
// LOOKING - so the panel does not need to know anything about the world.
void() NPC_DrawSpawnTab =
{
	float top = NPC_TITLE_H + NPC_TAB_H + NPC_PAD;
	float colw = (npc_panel_size_x - NPC_PAD * 3) / NPC_COLS;
	float i, shown = 0;
	float lastgrp = -1;
	float y = top - npc_scroll;

	for (i = 0; i < npc_cls_count; i = i + 1)
	{
		// A one-line separator whenever the group changes, so the list reads as
		// four families rather than one wall of 37 buttons.
		if (npc_cls_group[i] != lastgrp)
		{
			lastgrp = npc_cls_group[i];
			if (shown & 1)			// finish a half-filled row first
				shown = shown + 1;
			y = top - npc_scroll + floor(shown / NPC_COLS) * NPC_ROW_H
			    + (lastgrp + 1) * 12;
		}

		float cx = NPC_PAD + (shown % NPC_COLS) * (colw + NPC_PAD);
		float cy = top - npc_scroll + floor(shown / NPC_COLS) * NPC_ROW_H
		           + (lastgrp + 1) * 12;

		if (cy > NPC_TITLE_H + NPC_TAB_H && cy < npc_panel_size_y - 40)
		{
			if (Debug_Button(strcat("npc_s", ftos(i)), [cx, cy], [colw, NPC_ROW_H - 2],
			                 npc_cls_label[i], DBG_BTN_OFF, DBG_BTN_OFF_BORD))
				localcmd(strcat("cmd ai_spawn ", npc_cls_name[i], " ",
				                ftos(npc_spawn_count), "\n"));
		}
		shown = shown + 1;
	}
};

// Live status, straight off the replicated monster entities the client already
// has.  Nothing new is networked for this: .frame, .origin and .modelindex are
// already there, so the panel reports what the client can actually see and the
// authoritative per-monster state comes from the server's `ai_status` print.
void() NPC_DrawStatusTab =
{
	float top = NPC_TITLE_H + NPC_TAB_H + NPC_PAD;
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

	sui_text([NPC_PAD, top], DBG_FONT,
	         "Server-side detail prints to the console:", DBG_TEXT_2, 1, 0);

	if (Debug_Button("npc_status", [NPC_PAD, top + 14], [150, 18],
	                 "ai_status -> console", DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		localcmd("cmd ai_status\n");

	if (Debug_Button("npc_list", [NPC_PAD + 158, top + 14], [150, 18],
	                 "ai_list -> console", DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		localcmd("cmd ai_list\n");

	// Client-visible census: how many monster-ish entities the client is
	// currently drawing, which is the fastest way to notice "the server thinks
	// it spawned eight and I can see none".
	float n = 0;
	entity e;
	for (e = world; (e = nextent(e)) != world; )
		if (e.modelindex && substring(e.classname, 0, 8) == "monster_")
			n = n + 1;

	sui_text([NPC_PAD, top + 44], DBG_FONT,
	         strcat("monster entities visible to this client: ^3", ftos(n)),
	         DBG_TEXT_1, 1, 0);

	sui_text([NPC_PAD, top + 62], DBG_FONT,
	         "^7F9-style readout: hp / state / schedule / cond / enemy", DBG_TEXT_2, 1, 0);
	sui_text([NPC_PAD, top + 76], DBG_FONT,
	         "Every NPC bug so far was the wrong SCHEDULE.", DBG_TEXT_2, 1, 0);
};

// Bottom strip: spawn count, freeze, clear, hurt.
void() NPC_DrawBottomBar =
{
	float by = npc_panel_size_y - 26;
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	sui_fill([0, by - 4], [npc_panel_size_x, 30], DBG_HEADER_BG, 1, 0);

	sui_text([NPC_PAD, by + 2], DBG_FONT, strcat("count ^3", ftos(npc_spawn_count)),
	         DBG_TEXT_1, 1, 0);

	if (Debug_Button("npc_cdn", [NPC_PAD + 72, by], [16, 18], "-",
	                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		if (npc_spawn_count > 1)
			npc_spawn_count = npc_spawn_count - 1;

	if (Debug_Button("npc_cup", [NPC_PAD + 90, by], [16, 18], "+",
	                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		if (npc_spawn_count < 16)
			npc_spawn_count = npc_spawn_count + 1;

	if (Debug_Button("npc_freeze", [NPC_PAD + 116, by], [58, 18], "freeze",
	                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		localcmd("cmd ai_freeze\n");

	if (Debug_Button("npc_hurt", [NPC_PAD + 180, by], [48, 18], "hurt",
	                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		localcmd("cmd ai_hurt 25\n");

	if (Debug_Button("npc_clear", [npc_panel_size_x - 66, by], [60, 18], "clear all",
	                 DBG_BTN_CLOSE, DBG_BTN_CLOSE_BORD))
		localcmd("cmd ai_clear\n");
};

void() NPC_HandleDrag =
{
	// sui_is_held on the title-bar action element, the same mechanism
	// Debug_HandleDrag uses - SUI owns the mouse state, so asking it directly is
	// what keeps both panels behaving identically.
	float held = sui_is_held("npc_titlebar");

	if (held && !npc_panel_dragging)
	{
		npc_panel_dragging      = 1;
		npc_panel_drag_offset_x = _cursor_position_x - npc_panel_pos_x;
		npc_panel_drag_offset_y = _cursor_position_y - npc_panel_pos_y;
	}

	if (held && npc_panel_dragging)
	{
		npc_panel_pos_x = _cursor_position_x - npc_panel_drag_offset_x;
		npc_panel_pos_y = _cursor_position_y - npc_panel_drag_offset_y;

		// Keep at least 80 px of title bar reachable.
		if (npc_panel_pos_x < -npc_panel_size_x + 80)
			npc_panel_pos_x = -npc_panel_size_x + 80;
		if (npc_panel_pos_x > g_width - 80)
			npc_panel_pos_x = g_width - 80;
		if (npc_panel_pos_y < 0)
			npc_panel_pos_y = 0;
		if (npc_panel_pos_y > g_height - NPC_TITLE_H)
			npc_panel_pos_y = g_height - NPC_TITLE_H;
	}

	if (!held)
		npc_panel_dragging = 0;
};

void() NPC_PanelDraw =
{
	if (!npc_panel_open)
		return;
	NPC_PanelInit();

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	sui_fill([npc_panel_pos_x + 3, npc_panel_pos_y + 3], npc_panel_size,
	         DBG_SHADOW, 0.45, 0);

	if (npc_panel_pos_x > g_width - 80)
		npc_panel_pos_x = g_width - 80;
	if (npc_panel_pos_y > g_height - NPC_TITLE_H)
		npc_panel_pos_y = g_height - NPC_TITLE_H;

	sui_push_frame(npc_panel_pos, npc_panel_size);

	sui_fill([0, 0], npc_panel_size, DBG_BG, 0.94, 0);
	sui_border_box([0, 0], npc_panel_size, 2, DBG_BORDER, 1, 0);

	NPC_DrawTitleBar();
	NPC_DrawTabStrip();

	if (npc_panel_tab == NPCTAB_SPAWN)
		NPC_DrawSpawnTab();
	else
		NPC_DrawStatusTab();

	NPC_DrawBottomBar();
	NPC_HandleDrag();

	sui_pop_frame();
};
