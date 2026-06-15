// =============================================
//  Buy menu — CS-style two-level weapon/equipment shop
// =============================================
//
// A short text menu navigated by number keys 1-9 OR the mouse.  Opened via
// the "buymenu" console command (bind a key, e.g. `bind b buymenu`).
//
//   Screen 0 (categories): 1.Handguns 2.Shotguns 3.SMG 4.Snipers
//                          5.Rifles 6.LMG 7.Melee 8.Equipment
//   Screen 1 (items):      that category's weapons + price; Equipment also
//                          lists Kevlar / Kevlar+Helmet / Defuse Kit.
//
// Number / click on an item purchases it and closes the menu; ESC backs out
// one level then closes.  Items you can't afford — and whole categories where
// nothing is affordable — are greyed out.  Purchase is sent via `cmd buy
// <id>`; the server (SV_ParseClientCommand) re-validates funds and grants the
// weapon/item.  Affordability for the greyout is computed here from the synced
// STAT_MONEY — no extra networking.
//
// Price + category data live in the SHARED manifest (sh_weapon_manifest.qc:
// WeaponManifest_Price/BuyCat, BuyCat_Weapon/Count/Label, BuyItem_*).  The
// team-menu gates (TeamMenu_IsModServer / TeamMenuIsOpen / TeamMenuMainMenuOpen)
// are forward-declared in cl_radio.qc, which compiles before this file.

float buymenu_open;       // 0 closed, 1 open
float buymenu_state;      // 0 = category screen, 1 = item screen
float buymenu_category;   // active BUYCAT_* when on the item screen
float buymenu_cursor_on;  // mirror of setcursormode() state

// Panel geometry — shared by draw + mouse hit-test so they always agree.
const float BUY_PANEL_X  = 12;
const float BUY_PANEL_W  = 320;
const float BUY_LINE_H   = 16;
const float BUY_PAD_X    = 14;
const float BUY_PAD_Y    = 10;
const float BUY_TITLE_H  = 24;
const float BUY_FONT     = 12;   // GoogleMed size, loaded as hud_font_mono

float() Buy_CanOpen =
{
    if (!TeamMenu_IsModServer())
        return FALSE;
    if (TeamMenuIsOpen())
        return FALSE;
    if (TeamMenuMainMenuOpen())
        return FALSE;
    if (getstatf(STAT_IS_DEAD))
        return FALSE;
    if (getstati(STAT_PLAYERTEAM) <= TEAM_NONE)
        return FALSE;
    return TRUE;
};

void() Buy_SetCursor =
{
    // Show the cursor while open so clicks register; restore normal look on
    // close.  Mutually exclusive with the team menu (Buy_CanOpen gates on
    // it), so there's no cursor-owner fight.
    if (buymenu_open && !buymenu_cursor_on)
    {
        setcursormode(TRUE, "gfx/xhair", [16, 16], cvar("vid_conautoscale"));
        buymenu_cursor_on = TRUE;
    }
    else if (!buymenu_open && buymenu_cursor_on)
    {
        setcursormode(FALSE);
        buymenu_cursor_on = FALSE;
    }
};

void() Buy_Close =
{
    buymenu_open = 0;
    buymenu_state = 0;
    Buy_SetCursor();
};

void() Buy_Open =
{
    if (!Buy_CanOpen())
        return;
    buymenu_open = 1;
    buymenu_state = 0;
    Buy_SetCursor();
};

void() Buy_Toggle =
{
    if (buymenu_open)
        Buy_Close();
    else
        Buy_Open();
};

float() Buy_IsOpen =
{
    if (!buymenu_open)
        return FALSE;
    if (!Buy_CanOpen())
    {
        Buy_Close();
        return FALSE;
    }
    return TRUE;
};

// --- item / price / affordability helpers ---

// Rows on the current item screen (grenades, + armor/kit for Equipment).
float() Buy_ItemRowCount =
{
    float n = BuyCat_Count(buymenu_category);
    if (buymenu_category == BUYCAT_EQUIPMENT)
        n = n + BUYITEM_COUNT;
    return n;
};

// Weapon id / buy-item id for item-screen row r (1-based), or NONE.
float(float r) Buy_RowId =
{
    float gren = BuyCat_Count(buymenu_category);
    if (r >= 1 && r <= gren)
        return BuyCat_Weapon(buymenu_category, r);
    if (buymenu_category == BUYCAT_EQUIPMENT && r > gren && r <= gren + BUYITEM_COUNT)
        return BuyItem_ByIndex(r - gren);
    return WMF_WEP_NONE;
};

string(float id) Buy_IdName =
{
    if (BuyItem_IsItem(id))
        return BuyItem_Name(id);
    return WeaponManifest_MenuName(id);
};

float(float id) Buy_IdPrice =
{
    if (BuyItem_IsItem(id))
        return BuyItem_Price(id);
    return WeaponManifest_Price(id);
};

float(float id) Buy_Affordable =
{
    return getstatf(STAT_MONEY) >= Buy_IdPrice(id);
};

// TRUE if at least one item in `cat` is affordable (drives category greyout).
float(float cat) Buy_CategoryAffordable =
{
    float money = getstatf(STAT_MONEY);
    float n = BuyCat_Count(cat);
    float i;
    for (i = 1; i <= n; i = i + 1)
        if (money >= WeaponManifest_Price(BuyCat_Weapon(cat, i)))
            return TRUE;
    if (cat == BUYCAT_EQUIPMENT)
        for (i = 1; i <= BUYITEM_COUNT; i = i + 1)
            if (money >= BuyItem_Price(BuyItem_ByIndex(i)))
                return TRUE;
    return FALSE;
};

// Rows on the current screen (8 categories, or the item count).
float() Buy_ScreenRowCount =
{
    if (buymenu_state == 0)
        return BUYCAT_LAST;
    return Buy_ItemRowCount();
};

float() Buy_PanelHeight =
{
    return BUY_TITLE_H + BUY_LINE_H * Buy_ScreenRowCount() + BUY_PAD_Y * 2;
};

float() Buy_PanelTop =
{
    return g_height * 0.5 - Buy_PanelHeight() * 0.5;
};

// 1-based row under the mouse cursor, or 0 if none.
float() Buy_RowAtCursor =
{
    float rowcount = Buy_ScreenRowCount();
    float rows_top = Buy_PanelTop() + BUY_PAD_Y + BUY_TITLE_H;
    float row;
    if (cursor_pos_x < BUY_PANEL_X || cursor_pos_x > BUY_PANEL_X + BUY_PANEL_W)
        return 0;
    if (cursor_pos_y < rows_top)
        return 0;
    row = floor((cursor_pos_y - rows_top) / BUY_LINE_H);
    if (row < 0 || row >= rowcount)
        return 0;
    return row + 1;
};

// --- actions ---

void(float id) Buy_Purchase =
{
    if (id == WMF_WEP_NONE)
        return;
    if (!Buy_Affordable(id))
        return;   // server re-checks anyway; skip the pointless round-trip
    // `cmd buy <id>` -> SV_ParseClientCommand on the server.
    localcmd(sprintf("cmd buy %g\n", id));
    Buy_Close();
};

void(float cat) Buy_EnterCategory =
{
    float n;
    if (cat < BUYCAT_HANDGUN || cat > BUYCAT_EQUIPMENT)
        return;
    if (buymenu_state != 0)
        return;
    n = BuyCat_Count(cat);
    if (cat == BUYCAT_EQUIPMENT)
        n = n + BUYITEM_COUNT;
    if (n <= 0)
        return;                          // empty category
    if (!Buy_CategoryAffordable(cat))
        return;                          // nothing affordable -> stays greyed
    buymenu_category = cat;
    buymenu_state = 1;
};

// --- input ---

float(float evtype, float scanx, float chary, float devid) Buy_InputEvent =
{
    float row;
    float pick;

    if (evtype != IE_KEYDOWN)
        return FALSE;

    // ESC backs out one level, then closes.
    if (scanx == K_ESCAPE)
    {
        if (buymenu_state == 1)
            buymenu_state = 0;
        else
            Buy_Close();
        return TRUE;
    }

    // Re-pressing the bound buy key closes the menu.
    if (getkeybind(scanx) == "buymenu")
    {
        Buy_Close();
        return TRUE;
    }

    // Mouse click — act on the row under the cursor (swallow all clicks
    // while open so they don't leak to +attack).
    if (scanx == K_MOUSE1)
    {
        row = Buy_RowAtCursor();
        if (row > 0)
        {
            if (buymenu_state == 0)
                Buy_EnterCategory(row);
            else
                Buy_Purchase(Buy_RowId(row));
        }
        return TRUE;
    }

    // Number keys 1-9.  Category screen picks a category (1-8); item screen
    // buys that row (rows >9 are mouse-only).
    if (scanx >= '1' && scanx <= '9')
    {
        pick = scanx - '0';
        if (buymenu_state == 0)
            Buy_EnterCategory(pick);
        else if (pick <= Buy_ItemRowCount())
            Buy_Purchase(Buy_RowId(pick));
        return TRUE;
    }

    return FALSE;
};

// --- draw ---  (called from the HUD pass in cl_main.qc; GoogleMed font)
void() Buy_Draw =
{
    float prev_font;
    float rowcount, panel_h, top, fs, money, hover, i, id, price, pw, afford;
    string label, title, pricestr;
    vector tp, rp, col;

    if (!Buy_IsOpen())
        return;

    prev_font = drawfont;
    drawfont = hud_font_mono;

    rowcount = Buy_ScreenRowCount();
    panel_h  = Buy_PanelHeight();
    top      = Buy_PanelTop();
    fs       = BUY_FONT;
    money    = getstatf(STAT_MONEY);
    hover    = Buy_RowAtCursor();

    // Background panel + top accent bar.
    drawfill([BUY_PANEL_X, top], [BUY_PANEL_W, panel_h], '0 0 0', 0.7, 0);
    drawfill([BUY_PANEL_X, top], [BUY_PANEL_W, 2], '0.4 0.7 1', 0.9, 0);

    // Title (+ current cash on the right).
    if (buymenu_state == 0)
        title = "BUY MENU";
    else
        title = BuyCat_Label(buymenu_category);
    tp = [BUY_PANEL_X + BUY_PAD_X, top + BUY_PAD_Y, 0];
    drawstring(tp, title, [fs, fs], '0.9 0.9 0.4', 1.0, 0);
    pricestr = sprintf("$%g", money);
    pw = stringwidth(pricestr, FALSE, [fs, fs]);
    drawstring([BUY_PANEL_X + BUY_PANEL_W - BUY_PAD_X - pw, tp_y], pricestr, [fs, fs], '0.6 1 0.6', 1.0, 0);

    rp = [BUY_PANEL_X + BUY_PAD_X, top + BUY_PAD_Y + BUY_TITLE_H, 0];
    for (i = 1; i <= rowcount; i = i + 1)
    {
        if (buymenu_state == 0)
        {
            label = sprintf("%g. %s", i, BuyCat_Label(i));
            afford = Buy_CategoryAffordable(i);
        }
        else
        {
            id = Buy_RowId(i);
            label = sprintf("%g. %s", i, Buy_IdName(id));
            price = Buy_IdPrice(id);
            afford = Buy_Affordable(id);
            // Right-aligned price column.
            pricestr = sprintf("$%g", price);
            pw = stringwidth(pricestr, FALSE, [fs, fs]);
            drawstring([BUY_PANEL_X + BUY_PANEL_W - BUY_PAD_X - pw, rp_y], pricestr, [fs, fs],
                       afford ? '0.6 1 0.6' : '0.55 0.35 0.35', 0.95, 0);
        }

        if (!afford)
            col = '0.45 0.45 0.45';   // greyed (unaffordable / empty)
        else if (i == hover)
            col = '1 1 0.5';          // mouse hover highlight
        else
            col = '1 1 1';

        drawstring(rp, label, [fs, fs], col, 0.97, 0);
        rp_y = rp_y + BUY_LINE_H;
    }

    drawfont = prev_font;
};
