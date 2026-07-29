// =============================================
//  Update panel — top-right of the main menu
// =============================================
//
// Surfaces the engine's in-game delta updater (engine/common/qkupdate.c).  The engine does all
// the work; this file is a read-only view of nine cvars plus three console commands.  Nothing
// here has any knowledge of manifests, hashes or HTTP.
//
//   update_state       disabled/idle/checking/uptodate/available/downloading/applying/
//                      restart/launcher/error
//   update_files       update_files_done      update_bytes      update_done_bytes
//   update_rate        update_current         update_version    update_error
//
// Why cvars and not new builtins: a new builtin has to be registered in the engine's
// pr_menu.c and would collide with future upstream builtin numbers — renumbering silently
// breaks a prebuilt menu.dat.  Cvars also work identically on a dedicated server, which has no
// menu VM at all, so the whole updater stayed testable from the console while it was built.
//
// Compiled after menu/m_loading.qc so it can borrow m_loading_format_bytes and
// m_loading_progress_bar (including that function's indeterminate pct<0 mode).  It deliberately
// does NOT use m_loading_track_rate: that holds file-scope state shared with the connect-time
// download card, and two panels sampling it would fight.  The engine publishes update_rate for
// exactly this reason.

// FONT SIZES MUST COME FROM menu_font's native list: 8 12 16 18 24 36 48 60 72
// (menu/m_main.qc:157 — loadfont("hud", "gfx/RobotoEB", "8 12 16 18 24 36 48 60 72", ...)).
// Anything off that list forces FTE to stretch the cached glyph atlas and the text renders
// blurred; see the rule at menu/m_menu.qc:26-33. The CSQC VM loads a DIFFERENT list
// (client/cl_main.qc:279-281, which also has 32) — do not borrow sizes from it.
const float UPD_PANEL_W     = 230;  // wide enough for "Update installed · restart to finish"
const float UPD_RIGHT_PAD   = 14;
const float UPD_TOP_PAD     = 14;
const float UPD_TITLE_SZ    = 16;   // native. matches FLOAT_MENU_SMALL_SIZE, the menu's own small rows
const float UPD_TEXT_SZ     = 8;    // native. matches LD_STAT_SZ (m_loading.qc:25), the small-readout precedent
const float UPD_ACTION_SZ   = 12;   // native
const float UPD_BAR_H       = 6;    // geometry, not type — the native rule does not apply
const float UPD_ROW_GAP     = 5;

vector UPD_COL_TITLE = '1 1 1';
vector UPD_COL_DIM   = '0.62 0.64 0.68';
vector UPD_COL_GOOD  = '0.55 1 0.6';
vector UPD_COL_WARN  = '1 0.85 0.18';
vector UPD_COL_BAD   = '0.95 0.32 0.32';

// "uptodate" is reassuring for a moment and then it is just clutter, so it fades itself out.
// Tracked here rather than in the engine because it is a presentation decision.
float  upd_uptodate_since;
string upd_last_state;

const float UPD_UPTODATE_HOLD = 4;

// The once-per-session automatic check.  The engine's "update_check auto" is itself
// idempotent, but main_menu() runs every frame and issuing a console command 60 times a
// second to be told "no" is silly.
float upd_autocheck_sent;

void() Update_KickAutoCheck =
{
	if (upd_autocheck_sent)
		return;
	upd_autocheck_sent = TRUE;
	localcmd("update_check auto\n");
};

// Percentage complete, or -1 for "no idea" (which m_loading_progress_bar renders as a
// sliding indeterminate chunk rather than an empty trough).
float() Update_Percent =
{
	float total = cvar("update_bytes");
	if (total <= 0)
		return -1;
	return bound(0, (cvar("update_done_bytes") / total) * 100, 100);
};

void(vector menu_size) Update_DrawPanel =
{
	string st = cvar_string("update_state");

	// Nothing to say.
	if (st == "" || st == "disabled" || st == "idle")
	{
		upd_last_state = st;
		return;
	}

	if (st != upd_last_state)
	{
		if (st == "uptodate")
			upd_uptodate_since = time;
		upd_last_state = st;
	}

	// Auto-hide the all-clear.  Every other state stays until the player acts on it.
	if (st == "uptodate" && upd_uptodate_since > 0
	    && time - upd_uptodate_since > UPD_UPTODATE_HOLD)
		return;

	// ---- decide the content before laying it out, so the height can be exact ----
	string title;
	string detail = "";
	string action = "";
	string action_id = "";
	string action_cmd = "";
	vector title_col = UPD_COL_TITLE;
	vector action_col = UPD_COL_GOOD;
	float  want_bar = FALSE;
	float  pct = -1;

	if (st == "checking")
	{
		title = "Checking for updates…";
		title_col = UPD_COL_DIM;
		want_bar = TRUE;
	}
	else if (st == "uptodate")
	{
		title = "Up to date";
		title_col = UPD_COL_DIM;
		detail = cvar_string("update_version");
	}
	else if (st == "available")
	{
		float nfiles = cvar("update_files");
		title  = "Update available";
		detail = sprintf("%d file%s · %s", nfiles, (nfiles == 1) ? "" : "s",
		                 m_loading_format_bytes(cvar("update_bytes")));
		action = "Update now";
		action_id = "upd_apply";
		action_cmd = "update_apply\n";
		action_col = UPD_COL_GOOD;
	}
	else if (st == "downloading")
	{
		float rate = cvar("update_rate");
		title  = "Downloading update";
		title_col = UPD_COL_DIM;
		pct = Update_Percent();
		want_bar = TRUE;
		detail = sprintf("%s / %s%s",
		                 m_loading_format_bytes(cvar("update_done_bytes")),
		                 m_loading_format_bytes(cvar("update_bytes")),
		                 (rate > 0) ? sprintf("  ·  %s/s", m_loading_format_bytes(rate)) : "");
		action = "Cancel";
		action_id = "upd_cancel";
		action_cmd = "update_cancel\n";
		action_col = UPD_COL_BAD;
	}
	else if (st == "applying")
	{
		// No buttons here on purpose: files are being renamed over on disk and there is
		// nothing safe for a click to do mid-way.
		title = "Installing…";
		title_col = UPD_COL_DIM;
		want_bar = TRUE;
	}
	else if (st == "restart")
	{
		// The engine never offers "keep playing" after an apply.  14 pk3s stay open for the
		// session and assets are cached in RAM; the nastiest mixed state is a changed
		// csprogs.dat whose CRC no longer matches what a server expects, which silently
		// blocks the player from connecting anywhere.
		title  = "Update installed";
		title_col = UPD_COL_GOOD;
		detail = "Restart Quakers to finish";
		action = "Quit";
		action_id = "upd_quit";
		action_cmd = "quit\n";
		action_col = UPD_COL_WARN;
	}
	else if (st == "launcher")
	{
		title  = "Update needs the launcher";
		title_col = UPD_COL_WARN;
		detail = cvar_string("update_error");
	}
	else if (st == "error")
	{
		title  = "Update failed";
		title_col = UPD_COL_BAD;
		detail = cvar_string("update_error");
		action = "Retry";
		action_id = "upd_retry";
		action_cmd = "update_check force\n";
		action_col = UPD_COL_GOOD;
	}
	else
		return;		// an engine state this menu.dat predates — say nothing rather than guess

	// ---- layout ----
	float h = UPD_TITLE_SZ;
	if (detail != "")
		h += UPD_ROW_GAP + UPD_TEXT_SZ;
	if (want_bar)
		h += UPD_ROW_GAP + UPD_BAR_H;
	if (action != "")
		h += UPD_ROW_GAP + UPD_ACTION_SZ;

	float px = menu_size_x - UPD_PANEL_W - UPD_RIGHT_PAD;
	float py = UPD_TOP_PAD;

	// A separate top-anchored frame, so the main menu's own hardcoded block height (which
	// bottom-anchors everything at 85% of screen height) is completely untouched.  The
	// top-right corner is free: sprays and playermodels bottom-anchor, the build tag is
	// bottom-right.
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	sui_push_frame([px, py], [UPD_PANEL_W, h]);

	// Right-align every row: the panel is pinned to the right screen edge, so a ragged right
	// margin reads as broken.  Under SUI_ALIGN_END on x, sui_transform_box (sui_sys.qc:83-112)
	// resolves to frame.right - element.width + pos_x, i.e. pos_x is an offset from the
	// element's OWN right edge — so [0, y] means "flush with the frame's right edge".
	// sui_text substitutes its measured string width as the element box (sui_sys.qc:1091-1097),
	// which is what turns this into real text right-alignment rather than a right-aligned
	// fixed rectangle.
	//
	// NOTE: sui_push_frame always resets its child to START/START (sui_sys.qc:161), so this has
	// to be set AFTER the push, not before.
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);

	// No panel background — matches the floating, background-free aesthetic the rest of the
	// main menu uses.  Double-drawn text (as in Float_TextOption) keeps it legible over the
	// menumap backdrop.
	float y = 0;

	sui_text([0, y], [UPD_TITLE_SZ, UPD_TITLE_SZ, 0], title, title_col, 1.0, 0);
	sui_text([0, y], [UPD_TITLE_SZ, UPD_TITLE_SZ, 0], title, title_col, 1.0, 0);
	y += UPD_TITLE_SZ;

	if (detail != "")
	{
		y += UPD_ROW_GAP;
		sui_text([0, y], [UPD_TEXT_SZ, UPD_TEXT_SZ, 0], detail, UPD_COL_DIM, 1.0, 0);
		y += UPD_TEXT_SZ;
	}

	if (want_bar)
	{
		y += UPD_ROW_GAP;
		// The bar is a fixed-width box, not text, so it wants the frame's left edge as its
		// origin. Align is sticky for the whole frame and m_loading_progress_bar draws through
		// sui_fill/sui_border_box, which honour it — so switch back explicitly rather than
		// relying on the fact that a frame-width box happens to transform identically under
		// START and END.
		sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
		// frame-local coords: we are inside sui_push_frame, same as m_loading's own callers
		m_loading_progress_bar([0, y, 0], [UPD_PANEL_W, UPD_BAR_H, 0], pct);
		sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
		y += UPD_BAR_H;
	}

	if (action != "")
	{
		y += UPD_ROW_GAP;
		// Float_TextOption for free hover wash, hold-darken, click.ogg/submit.ogg and a
		// hit-zone sized to the actual label width.
		//
		// This works right-aligned because sui_action_element registers its rect through the
		// SAME sui_transform_box as sui_text (sui_sys.qc:618) — there is no separate path and
		// no START assumption — and Float_TextOption passes the same pos and the same measured
		// width to both. So the hit zone lands exactly on the glyphs. This is the first
		// END-aligned Float_TextOption in the tree, so it is worth re-checking with
		// sui_debug_draw_action_elements (sui_sys.qc:1317) after any change here.
		if (Float_TextOption(action_id, [0, y, 0], UPD_ACTION_SZ, action, action_col))
			localcmd(action_cmd);
	}

	sui_pop_frame();
	// sui_pop_frame does NOT restore the parent's align (sui_sys.qc:164-167), so leave it as we
	// found it rather than making the rest of main_menu depend on our last state.
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
};
