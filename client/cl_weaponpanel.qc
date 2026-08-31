// ============================================================
//  client/cl_weaponpanel.qc  -  F5 in-game weapon debug panel
//
//  The fifth of the dev-overlay family: F1 cvars, F2 server browser,
//  F3 car tuning, F4 NPC test bench, F5 this.  Same shape as all of
//  them - a floating, draggable CSQC overlay with cursor takeover,
//  drawn over live gameplay so the server keeps ticking underneath.
//
//  It reuses cl_debugpanel.qc's visual constants and Debug_Button
//  outright rather than restating them, so the panels cannot drift
//  apart visually.  That file compiles earlier in cl_progs.src.
//
//  TWO MODES, and the distinction is not cosmetic:
//
//    EQUIP  ->  cmd wep_give <id>     the weapon goes into your hands
//    SPAWN  ->  cmd wep_spawn <tok>   a pickup drops on the floor
//
//  The 16 GoldSrc/Sven ALIAS classnames appear in SPAWN mode only.
//  They are not separate weapons: all 16 collapse onto 11 existing
//  WEP_ ids and differ ONLY in the world model lying on the ground,
//  which is replaced the moment you touch it.  Equipping
//  "weapon_tommygun" and "weapon_m16a1" produces a byte-identical
//  result, so in EQUIP mode they would be duplicate rows that lie.
//  On the floor they are the only way to see those models at all.
//
//  NO NEW NETWORKING.  shared/sh_weapon_manifest.qc compiles into
//  CSQC as well as SSQC, so the client already knows every weapon's
//  name and slot.  The panel is a pure view over it.
//
//  It deliberately does NOT use WeaponManifest_DebugWeapon /
//  _DebugCount, even though those exist and look like the right
//  accessors.  They key off debug_order, and this panel should keep
//  working whether or not that stays contiguous - direct manifest
//  iteration is the honest source.
//
//  Compiled for CSQC only via cl_progs.src.
// ============================================================

const float WPN_ROW_H     = 17;
const float WPN_HEADER_H  = 19;   // the "Half-Life" / "CrossFire" section bars
const float WPN_PAD       = 6;
const float WPN_TITLE_H   = 24;
const float WPN_TAB_H     = 20;
const float WPN_BOTTOM_H  = 26;
const float WPN_COLS      = 2;
const float WPN_MAX_ALIAS = 24;

const float WPNTAB_PRIMARY   = 0;
const float WPNTAB_SECONDARY = 1;
const float WPNTAB_MELEE     = 2;
const float WPNTAB_UTILITY   = 3;
const float WPNTAB_ALIAS     = 4;
const float WPNTAB_COUNT     = 5;

const float WPNMODE_EQUIP = 0;
const float WPNMODE_SPAWN = 1;

string wpn_alias_class[WPN_MAX_ALIAS];   // the classname sent to the server
string wpn_alias_label[WPN_MAX_ALIAS];   // what the button says
float  wpn_alias_count;

float  wpn_panel_open;
float  wpn_panel_init;
vector wpn_panel_pos;
vector wpn_panel_size;
float  wpn_panel_dragging;
vector wpn_panel_drag_offset;
float  wpn_cursor_active;
float  wpn_panel_tab;
float  wpn_panel_mode;
float  wpn_spawn_count;        // how many each SPAWN button drops; seeded in Init
                               // (an initialiser here would make fteqcc treat it
                               // as a const — same note as npc_spawn_count)
vector wpn_scroll;

// Per-game layout, rebuilt each frame by WPN_DrawWeaponList.  Sized
// WMF_GAME_LAST + 1 so index 0 (WMF_GAME_NONE) has a slot of its own: an
// untagged weapon then gets a visible "Other" section instead of vanishing,
// which is the failure this file's header already argues for over the
// debug_order accessors.  fteqcc wants a literal array size, so the constant
// cannot be used here — keep the two in step.
float wpn_game_count[10];   // weapons in the active slot belonging to that game
float wpn_game_y[10];       // y of that game's header, or -1 when it has none
float wpn_game_seen[10];    // running placement index during the draw pass

void(string cls, string label) WPN_AddAlias =
{
	if (wpn_alias_count >= WPN_MAX_ALIAS)
		return;
	wpn_alias_class[wpn_alias_count] = cls;
	wpn_alias_label[wpn_alias_count] = label;
	wpn_alias_count = wpn_alias_count + 1;
};

// The alias registry, mirroring the standalone spawn functions in
// server/sv_goldsrc_pickups.qc.  Hand-kept for the same reason NPC_Add is: the
// server owns the real list and CSQC cannot enumerate it.  Drift is visible
// rather than silent — the server prints "no such weapon" for a classname it
// does not recognise.
//
// The nine plain GoldSrc names (weapon_shotgun, weapon_9mmAR, weapon_mp5, …)
// are deliberately absent: they are name-only aliases that spawn the mod's own
// world model, so they would be duplicate rows here too.
void() WPN_PanelInit =
{
	if (wpn_panel_init)
		return;
	wpn_panel_init = TRUE;

	wpn_spawn_count = 1;
	wpn_panel_pos   = [110, 60];
	wpn_panel_size  = [440, 360];

	// The parenthetical means "this map classname is really OUR weapon X" - it is
	// an honesty label for a stand-in, not decoration.  Most of this list no
	// longer needs one: each of these names now resolves to a weapon this tree
	// implements outright, so labelling them after the gun they used to borrow is
	// simply wrong on screen.  Two are still genuine stand-ins and keep theirs.
	WPN_AddAlias("weapon_tommygun",      "Tommygun");
	WPN_AddAlias("weapon_m16a1",         "M16A1");
	WPN_AddAlias("weapon_greasegun",     "Grease Gun");
	WPN_AddAlias("weapon_uzi",           "Uzi");
	WPN_AddAlias("weapon_uziakimbo",     "Akimbo Uzis");
	WPN_AddAlias("weapon_sawedoff",      "Sawed-off");
	WPN_AddAlias("weapon_colt1911",      "Colt 1911");
	WPN_AddAlias("weapon_m14",           "M14");
	WPN_AddAlias("weapon_sniperrifle",   "M40A1");
	WPN_AddAlias("weapon_pipewrench",    "Pipe Wrench");
	WPN_AddAlias("weapon_spanner",       "Spanner");
	WPN_AddAlias("weapon_teslagun",      "Tesla Gun");
	WPN_AddAlias("weapon_minigun",       "Minigun");
	WPN_AddAlias("weapon_sporelauncher", "Spore Launcher");
	WPN_AddAlias("weapon_eagle",         "Desert Eagle");

	// weapon_m16 has left this note: it resolves to WMF_WEP_SVM16 now, on both
	// the classname path and the string-key one, so the stand-in label was the
	// last thing still claiming it was an HL SMG.
	WPN_AddAlias("weapon_m16",           "M16");

	// The tactical shield.  It is EQUIPMENT, not a weapon — no slot, no WEP_ id,
	// no manifest row — so the four slot tabs structurally cannot show it and
	// this alias table is the only list on the panel that can.  It is drawn
	// again as a button on the bottom bar so EQUIP mode can reach it too; see
	// WPN_DrawBottomBar.
	WPN_AddAlias("weapon_shield",        "Tactical Shield");

	// THE TABLE NO LONGER HOLDS A STAND-IN.  weapon_penguin used to sit here
	// labelled "Penguin ^7(Snark)" because it had no implementation of its own -
	// it was a GoldSrc_AliasSetup model swap onto WEP_SNARK.  It is a real weapon
	// now (shared/weapons/sh_wpn_oppenguin.qc), so it comes through the manifest
	// like every other one and draws in the Utility tab; listing it here as well
	// would show it twice.
};

float() WPN_PanelOpen = { return wpn_panel_open; };

void() WPN_PanelToggle =
{
	WPN_PanelInit();
	wpn_panel_open = !wpn_panel_open;

	if (wpn_panel_open && !wpn_cursor_active)
	{
		setcursormode(TRUE, "gfx/xhair", '16 16 0', cvar("vid_conautoscale"));
		wpn_cursor_active = 1;
	}
	else if (!wpn_panel_open && wpn_cursor_active)
	{
		setcursormode(FALSE);
		wpn_cursor_active = 0;
	}
};

float(float evtype, float scanx, float chary, float devid) WPN_PanelInputEvent =
{
	if (!wpn_panel_open)
		return FALSE;

	if (evtype == IE_KEYDOWN && (scanx == K_F5 || scanx == K_ESCAPE))
	{
		WPN_PanelToggle();
		return TRUE;
	}

	// FORWARD into SUI, then absorb.  SUI owns the cursor position and does the
	// hit testing for sui_action_element, so returning TRUE without forwarding
	// leaves every widget inert while still looking correct — the exact bug
	// documented at cl_npcpanel.qc:152-166.  Returning TRUE afterwards is what
	// stops the click also reaching +attack.
	sui_input_event(evtype, scanx, chary, devid);
	return TRUE;
};

// The manifest slot this tab lists.  WPNTAB_ALIAS has no slot — it is handled
// by its own draw function.
float(float tab) WPN_TabSlot =
{
	if (tab == WPNTAB_PRIMARY)   return WMF_SLOT_PRIMARY;
	if (tab == WPNTAB_SECONDARY) return WMF_SLOT_SECONDARY;
	if (tab == WPNTAB_MELEE)     return WMF_SLOT_MELEE;
	return WMF_SLOT_UTILITY;
};

// Should this weapon appear at all?  Two weapons have no world pickup AND no
// branch in SV_DebugSpawnWeaponId (sv_player.qc:626): WEP_MELEE is intrinsic
// fists, and WEP_DODBINOCS is deliberately absent because the manifest gives it
// an empty world-model string (sh_weapon_manifest.qc:464) — a spawned entity
// would come up with modelindex 0 and be dropped.  That is the reported "the
// binoculars despawn as soon as you spawn them and try to swap".  Both stay in
// EQUIP mode, where wep_give is the supported route and works.
//
// The server-side guard in WepDbg_Spawn is the load-bearing half: it also covers
// a bare `wep_spawn 41` from the console, which this filter cannot reach.
float(float wep) WPN_Listable =
{
	if (!WeaponManifest_Load(wep))
		return FALSE;
	if (wpn_panel_mode == WPNMODE_SPAWN
	    && (wep == WEP_MELEE || wep == WEP_DODBINOCS))
		return FALSE;
	return TRUE;
};

// ============================================================
//  drawing
// ============================================================
void() WPN_DrawTitleBar =
{
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	sui_fill([0, 0], [wpn_panel_size_x, WPN_TITLE_H], DBG_TITLE_BG, 1, 0);
	sui_text([WPN_PAD, 8], DBG_FONT, "Weapon debug  ^7(F5)", DBG_TEXT_1, 1, 0);

	// Registered narrower than the bar so it does not swallow the close button.
	sui_action_element([0, 0], [wpn_panel_size_x - 26, WPN_TITLE_H],
	                   "wpn_titlebar", sui_noop);

	if (Debug_Button("wpn_close", [wpn_panel_size_x - 22, 4], [18, 16], "X",
	                 DBG_BTN_CLOSE, DBG_BTN_CLOSE_BORD))
		WPN_PanelToggle();
};

void(string label, float tab_id, float x, float w) WPN_DrawOneTab =
{
	vector col = DBG_BTN_OFF;
	if (wpn_panel_tab == tab_id)
		col = DBG_BTN_ON;
	if (Debug_Button(strcat("wpn_tab", ftos(tab_id)), [x, WPN_TITLE_H],
	                 [w, WPN_TAB_H - 2], label, col, DBG_BTN_OFF_BORD))
	{
		wpn_panel_tab = tab_id;
		wpn_scroll = '0 0 0';
	}
};

void() WPN_DrawTabStrip =
{
	// Five tabs in SPAWN mode, four in EQUIP — the alias tab only exists where
	// the world model is the thing being tested.
	float ntabs = (wpn_panel_mode == WPNMODE_SPAWN) ? 5 : 4;
	float w = floor(wpn_panel_size_x / ntabs);

	WPN_DrawOneTab("Primary",   WPNTAB_PRIMARY,   0,     w);
	WPN_DrawOneTab("Secondary", WPNTAB_SECONDARY, w,     w);
	WPN_DrawOneTab("Melee",     WPNTAB_MELEE,     w * 2, w);
	if (ntabs == 5)
	{
		WPN_DrawOneTab("Utility", WPNTAB_UTILITY, w * 3, w);
		WPN_DrawOneTab("GoldSrc", WPNTAB_ALIAS,   w * 4,
		               wpn_panel_size_x - w * 4);
	}
	else
		WPN_DrawOneTab("Utility", WPNTAB_UTILITY, w * 3,
		               wpn_panel_size_x - w * 3);
};

// Shared body geometry for both list drawers.
float() WPN_BodyTop    = { return WPN_TITLE_H + WPN_TAB_H; };
float() WPN_BodyHeight = { return wpn_panel_size_y - WPN_BodyTop() - WPN_BOTTOM_H; };

// The weapon list: every manifest id whose slot matches the active tab,
// GROUPED UNDER ITS SOURCE GAME.
//
// The dense `idx` this used to carry could not survive grouping: it derived cy
// straight from the row number, which only works when every row is the same
// height and there is nothing between them.  With headers interleaved the
// layout is a running y, so the pass below measures per game first and then
// places against those offsets.
//
// It stays TWO passes over the manifest, exactly as before — a per-game bucket
// pass replaces the old count pass, so the panel does no more manifest work
// than it did flat.  The naive shape (outer loop over games, inner over
// weapons) would have multiplied it by WMF_GAME_LAST, and this panel redraws
// every frame while it is open.
void() WPN_DrawWeaponList =
{
	float body_w = wpn_panel_size_x;
	float body_h = WPN_BodyHeight();
	float slot   = WPN_TabSlot(wpn_panel_tab);
	float wep, g;

	// Pass 1 — bucket the visible weapons by game.
	for (g = 0; g <= WMF_GAME_LAST; g = g + 1)
	{
		wpn_game_count[g] = 0;
		wpn_game_seen[g]  = 0;
	}
	for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
	{
		if (!WPN_Listable(wep))                continue;
		if (WeaponManifest_Slot(wep) != slot)  continue;
		float gm = WeaponManifest_Game(wep);
		wpn_game_count[gm] = wpn_game_count[gm] + 1;
	}

	// Section offsets, in WMF_GAME_* order.  A game with nothing in this slot
	// contributes no header at all — an empty "Day of Defeat" bar above the
	// melee tab would be noise.
	float y = 0;
	for (g = 0; g <= WMF_GAME_LAST; g = g + 1)
	{
		if (!wpn_game_count[g]) { wpn_game_y[g] = -1; continue; }
		wpn_game_y[g] = y;
		y = y + WPN_HEADER_H + ceil(wpn_game_count[g] / WPN_COLS) * WPN_ROW_H;
	}
	float content_h = y + WPN_PAD;

	sui_push_frame([0, WPN_BodyTop()], [body_w, body_h]);
	sui_scroll_view_begin("wpn_body_scroll", [0, 0], [body_w, body_h],
	                      [body_w - DBG_VBAR_W, content_h], wpn_scroll,
	                      [0, DBG_VBAR_W]);

	float colw = (body_w - DBG_VBAR_W - WPN_PAD * 3) / WPN_COLS;

	// Cull rows outside the viewport or a 48-row tab blows MAX_ACTION_ELEMENTS
	// (256, and it is shared with every other open panel).  Same guard as
	// Debug_DrawBody, cl_debugpanel.qc:527-544.
	float vp_top    = wpn_scroll_y - WPN_ROW_H;
	float vp_bottom = wpn_scroll_y + body_h + WPN_ROW_H;

	// Pass 2 — place.  Weapon ids ascend, so each game's running index lands
	// its members in id order under its own header.
	for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
	{
		if (!WPN_Listable(wep))                continue;
		if (WeaponManifest_Slot(wep) != slot)  continue;

		float gme  = WeaponManifest_Game(wep);
		float base = wpn_game_y[gme];
		float k    = wpn_game_seen[gme];
		wpn_game_seen[gme] = k + 1;

		// The header goes down with its first member, so it needs no second
		// walk over the games and cannot be emitted for an empty section.
		if (k == 0 && base + WPN_HEADER_H >= vp_top && base <= vp_bottom)
		{
			sui_fill([0, base], [body_w - DBG_VBAR_W, WPN_HEADER_H - 3],
			         DBG_TITLE_BG, 0.85, 0);
			sui_text([WPN_PAD, base + 4], DBG_FONT,
			         WeaponManifest_GameLabel(gme), DBG_TEXT_1, 1, 0);
		}

		float cx = WPN_PAD + (k % WPN_COLS) * (colw + WPN_PAD);
		float cy = base + WPN_HEADER_H + floor(k / WPN_COLS) * WPN_ROW_H;

		if (cy + WPN_ROW_H < vp_top || cy > vp_bottom)
			continue;

		if (Debug_Button(strcat("wpn_w", ftos(wep)), [cx, cy],
		                 [colw, WPN_ROW_H - 2], WeaponManifest_MenuName(wep),
		                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
		{
			if (wpn_panel_mode == WPNMODE_EQUIP)
				localcmd(sprintf("cmd wep_give %g\n", wep));
			else
				localcmd(sprintf("cmd wep_spawn %g %g\n", wep, wpn_spawn_count));
		}
	}

	sui_scroll_view_end();
	sui_pop_frame();
};

// The GoldSrc/Sven alias list.  SPAWN mode only — see the file header.
void() WPN_DrawAliasList =
{
	float body_w = wpn_panel_size_x;
	float body_h = WPN_BodyHeight();
	float content_h = ceil(wpn_alias_count / WPN_COLS) * WPN_ROW_H + WPN_PAD;

	sui_push_frame([0, WPN_BodyTop()], [body_w, body_h]);
	sui_scroll_view_begin("wpn_alias_scroll", [0, 0], [body_w, body_h],
	                      [body_w - DBG_VBAR_W, content_h], wpn_scroll,
	                      [0, DBG_VBAR_W]);

	float colw = (body_w - DBG_VBAR_W - WPN_PAD * 3) / WPN_COLS;
	float vp_top    = wpn_scroll_y - WPN_ROW_H;
	float vp_bottom = wpn_scroll_y + body_h + WPN_ROW_H;
	float i;

	for (i = 0; i < wpn_alias_count; i = i + 1)
	{
		float cx = WPN_PAD + (i % WPN_COLS) * (colw + WPN_PAD);
		float cy = floor(i / WPN_COLS) * WPN_ROW_H;

		if (cy + WPN_ROW_H < vp_top || cy > vp_bottom)
			continue;

		if (Debug_Button(strcat("wpn_a", ftos(i)), [cx, cy],
		                 [colw, WPN_ROW_H - 2], wpn_alias_label[i],
		                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
			localcmd(strcat("cmd wep_spawn ", wpn_alias_class[i], " ",
			                ftos(wpn_spawn_count), "\n"));
	}

	sui_scroll_view_end();
	sui_pop_frame();
};

void() WPN_DrawBottomBar =
{
	float y = wpn_panel_size_y - WPN_BOTTOM_H + 3;
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

	// Mode toggle.  Leaving SPAWN while the alias tab is active would render an
	// empty body, so clamp the tab on the way out.
	if (Debug_Button("wpn_mode_e", [WPN_PAD, y], [58, 18], "EQUIP",
	                 (wpn_panel_mode == WPNMODE_EQUIP) ? DBG_BTN_ON : DBG_BTN_OFF,
	                 DBG_BTN_OFF_BORD))
	{
		wpn_panel_mode = WPNMODE_EQUIP;
		if (wpn_panel_tab == WPNTAB_ALIAS)
			wpn_panel_tab = WPNTAB_PRIMARY;
		wpn_scroll = '0 0 0';
	}
	if (Debug_Button("wpn_mode_s", [WPN_PAD + 62, y], [58, 18], "SPAWN",
	                 (wpn_panel_mode == WPNMODE_SPAWN) ? DBG_BTN_ON : DBG_BTN_OFF,
	                 DBG_BTN_OFF_BORD))
	{
		wpn_panel_mode = WPNMODE_SPAWN;
		wpn_scroll = '0 0 0';
	}

	// Spawn count, SPAWN mode only.
	if (wpn_panel_mode == WPNMODE_SPAWN)
	{
		if (Debug_Button("wpn_cnt_d", [WPN_PAD + 130, y], [18, 18], "-",
		                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
			wpn_spawn_count = max(1, wpn_spawn_count - 1);
		sui_text([WPN_PAD + 152, y + 5], DBG_FONT, ftos(wpn_spawn_count),
		         DBG_TEXT_1, 1, 0);
		if (Debug_Button("wpn_cnt_u", [WPN_PAD + 168, y], [18, 18], "+",
		                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
			wpn_spawn_count = min(10, wpn_spawn_count + 1);
	}

	if (Debug_Button("wpn_strip", [wpn_panel_size_x - 66, y], [60, 18], "STRIP",
	                 DBG_BTN_CLOSE, DBG_BTN_CLOSE_BORD))
		localcmd("cmd wep_strip\n");

	// SHIELD.  On the bottom bar rather than in a tab because it belongs to
	// neither: the four tabs are manifest SLOTS and the shield has no slot, and
	// the GoldSrc tab is SPAWN-only.  Sitting here it works in both modes, which
	// matters — EQUIP puts it on your arm (dropping your primary, since the two
	// are mutually exclusive), SPAWN drops the pickup so the world model and the
	// touch path get tested too.
	if (Debug_Button("wpn_shield", [wpn_panel_size_x - 132, y], [62, 18], "SHIELD",
	                 DBG_BTN_OFF, DBG_BTN_OFF_BORD))
	{
		if (wpn_panel_mode == WPNMODE_EQUIP)
			localcmd("cmd wep_give shield\n");
		else
			localcmd(sprintf("cmd wep_spawn weapon_shield %g\n", wpn_spawn_count));
	}

	// The hint earns its space: EQUIP drops whatever was in the slot, so
	// repeated clicking litters the floor, and that surprises people.
	string hint = (wpn_panel_mode == WPNMODE_EQUIP)
	              ? "^7equip: the old gun drops at your feet"
	              : "^7spawn: pickups land in front of you";
	sui_text([WPN_PAD + 200, y + 5], DBG_FONT, hint, DBG_TEXT_2, 1, 0);
};

void() WPN_HandleDrag =
{
	float held = sui_is_held("wpn_titlebar");

	if (held && !wpn_panel_dragging)
	{
		wpn_panel_dragging      = 1;
		wpn_panel_drag_offset_x = _cursor_position_x - wpn_panel_pos_x;
		wpn_panel_drag_offset_y = _cursor_position_y - wpn_panel_pos_y;
	}

	if (held && wpn_panel_dragging)
	{
		wpn_panel_pos_x = _cursor_position_x - wpn_panel_drag_offset_x;
		wpn_panel_pos_y = _cursor_position_y - wpn_panel_drag_offset_y;

		// Keep at least 80 px of title bar reachable.
		if (wpn_panel_pos_x < -wpn_panel_size_x + 80)
			wpn_panel_pos_x = -wpn_panel_size_x + 80;
		if (wpn_panel_pos_x > g_width - 80)
			wpn_panel_pos_x = g_width - 80;
		if (wpn_panel_pos_y < 0)
			wpn_panel_pos_y = 0;
		if (wpn_panel_pos_y > g_height - WPN_TITLE_H)
			wpn_panel_pos_y = g_height - WPN_TITLE_H;
	}

	if (!held)
		wpn_panel_dragging = 0;
};

void() WPN_PanelDraw =
{
	if (!wpn_panel_open)
		return;
	WPN_PanelInit();

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	sui_fill([wpn_panel_pos_x + 3, wpn_panel_pos_y + 3], wpn_panel_size,
	         DBG_SHADOW, 0.45, 0);

	if (wpn_panel_pos_x > g_width - 80)
		wpn_panel_pos_x = g_width - 80;
	if (wpn_panel_pos_y > g_height - WPN_TITLE_H)
		wpn_panel_pos_y = g_height - WPN_TITLE_H;

	sui_push_frame(wpn_panel_pos, wpn_panel_size);

	sui_fill([0, 0], wpn_panel_size, DBG_BG, 0.94, 0);
	sui_border_box([0, 0], wpn_panel_size, 2, DBG_BORDER, 1, 0);

	WPN_DrawTitleBar();
	WPN_DrawTabStrip();

	if (wpn_panel_tab == WPNTAB_ALIAS && wpn_panel_mode == WPNMODE_SPAWN)
		WPN_DrawAliasList();
	else
		WPN_DrawWeaponList();

	WPN_DrawBottomBar();
	WPN_HandleDrag();

	sui_pop_frame();
};
