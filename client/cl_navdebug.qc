// client/cl_navdebug.qc
// ----------------------------------------------------------------------------
// Debug visualisation for the bot navigation graph + per-bot AI state.
//
// Entirely server-driven: when sv_nav_debug 1, the server (sv_bots.qc) streams
//   * CSQC_EVENT_NAV_GRAPH  — the nav graph in chunks (node positions + links)
//   * CSQC_EVENT_BOT_DEBUG  — each live bot's state (origin, state, enemy, mag)
// and this file caches + draws them.  No cvar is read client-side: if nothing is
// streamed the caches go stale and nothing draws, so there's zero cost when off.
//
// 3D draws (node markers, links, enemy lines) use CSQC_DebugBeam and must run in
// the scene pass (NavDebug_DrawScene, called next to CSQC_DrawDebugImpacts).
// 2D labels use project() and must run after renderscene (NavDebug_DrawText).
//
// Compile order: after cl_debuginfo.qc (CSQC_DebugBeam) + cl_debugpanel.qc,
// before cl_main.qc (the parse + draw hooks).
// ----------------------------------------------------------------------------

const float NAVDBG_MAX   = 512;		// drawn-node cap (client side)
const float NAVDBG_LINKS = 16;		// MUST match server NAV_LINK_MAX
const float NAVDBG_STALE = 2.0;		// stop drawing this long after the last packet

vector navdbg_pos[NAVDBG_MAX];
float  navdbg_linkcount[NAVDBG_MAX];
float  navdbg_link[NAVDBG_MAX * NAVDBG_LINKS];
float  navdbg_count;			// total nodes reported by the stream header
float  navdbg_have;			// highest node index +1 received so far
float  navdbg_last;			// cltime of the last nav packet

const float BOTDBG_MAX = 32;
float  botdbg_ent[BOTDBG_MAX];
vector botdbg_pos[BOTDBG_MAX];
float  botdbg_state[BOTDBG_MAX];
float  botdbg_enemy[BOTDBG_MAX];
float  botdbg_wep[BOTDBG_MAX];
float  botdbg_mag[BOTDBG_MAX];
float  botdbg_n;
float  botdbg_last;

// Spectated-bot path (NAVDBG_SF_PATHS) — node indices into navdbg_pos[] so the
// payload stays tiny; the client resolves world positions from the graph it has.
const float BOTDBG_PATHLEN = 24;	// MUST match sv_bots.qc BOT_PATHLEN
float  botpath_ent[BOTDBG_MAX];
float  botpath_len[BOTDBG_MAX];
float  botpath_cur[BOTDBG_MAX];
float  botpath_goal[BOTDBG_MAX];
float  botpath_node[BOTDBG_MAX * BOTDBG_PATHLEN];
float  botpath_n;
float  botpath_last;

// --- receive (called from CSQC_Parse_Event) ---------------------------------

void() NavDebug_Parse =
{
	float total = readshort();
	float start = readshort();
	float n     = readbyte();
	navdbg_count = total;
	navdbg_last  = cltime;

	float i, k;
	for (i = 0; i < n; i = i + 1)
	{
		float idx = start + i;
		vector p;
		p_x = readcoord();
		p_y = readcoord();
		p_z = readcoord();
		float lc = readbyte();

		float store = (idx >= 0 && idx < NAVDBG_MAX);
		if (store)
		{
			navdbg_pos[idx]       = p;
			navdbg_linkcount[idx] = (lc > NAVDBG_LINKS) ? NAVDBG_LINKS : lc;
			if (idx + 1 > navdbg_have)
				navdbg_have = idx + 1;
		}
		for (k = 0; k < lc; k = k + 1)
		{
			float nb = readshort();		// always consume, even past the cap
			if (store && k < NAVDBG_LINKS)
				navdbg_link[idx * NAVDBG_LINKS + k] = nb;
		}
	}
};

void() BotDebug_Parse =
{
	float n = readbyte();
	botdbg_last = cltime;
	botdbg_n = (n > BOTDBG_MAX) ? BOTDBG_MAX : n;

	float i;
	for (i = 0; i < n; i = i + 1)
	{
		float ent = readbyte();
		vector p;
		p_x = readcoord();
		p_y = readcoord();
		p_z = readcoord();
		float st  = readbyte();
		float en  = readbyte();
		float wep = readbyte();
		float mag = readbyte();
		if (i < BOTDBG_MAX)
		{
			botdbg_ent[i]   = ent;
			botdbg_pos[i]   = p;
			botdbg_state[i] = st;
			botdbg_enemy[i] = en;
			botdbg_wep[i]   = wep;
			botdbg_mag[i]   = mag;
		}
	}
};

void() NavPath_Parse =
{
	float n = readbyte();
	botpath_last = cltime;
	botpath_n = (n > BOTDBG_MAX) ? BOTDBG_MAX : n;

	float i, k;
	for (i = 0; i < n; i = i + 1)
	{
		float ent  = readbyte();
		float plen = readbyte();
		float cur  = readbyte();
		float goal = readshort();
		float storei = (i < BOTDBG_MAX);
		if (storei)
		{
			botpath_ent[i]  = ent;
			botpath_len[i]  = (plen > BOTDBG_PATHLEN) ? BOTDBG_PATHLEN : plen;
			botpath_cur[i]  = cur;
			botpath_goal[i] = goal;
		}
		for (k = 0; k < plen; k = k + 1)
		{
			float node = readshort();		// always consume, even past the cap
			if (storei && k < BOTDBG_PATHLEN)
				botpath_node[i * BOTDBG_PATHLEN + k] = node;
		}
	}
};

// CSQC_Ent_Update handler for the nav_debug_proxy.  The CSQC_ENT_NAV_DEBUG byte was
// already consumed by CSQC_Ent_Update; read the section bits then the present sections
// in fixed order GRAPH, BOTS, PATHS — must match NavDbg_SendEntity (sv_bots.qc).
void() NavDebug_EntUpdate =
{
	float bits = readbyte();
	if (bits & NAVDBG_SF_GRAPH) NavDebug_Parse();
	if (bits & NAVDBG_SF_BOTS)  BotDebug_Parse();
	if (bits & NAVDBG_SF_PATHS) NavPath_Parse();
};

// --- draw -------------------------------------------------------------------

string(float st) NavDebug_StateName =
{
	if (st == 2) return "ENGAGE";
	if (st == 1) return "HUNT";
	return "ROAM";
};

// 3D: node markers + links + bot->enemy lines.  Call in the scene pass.
void() NavDebug_DrawScene =
{
	float i, k;

	if (navdbg_count > 0 && (cltime - navdbg_last) < NAVDBG_STALE)
	{
		float cap = navdbg_have;
		if (cap > NAVDBG_MAX) cap = NAVDBG_MAX;
		for (i = 0; i < cap; i = i + 1)
		{
			vector p = navdbg_pos[i];
			// small 3D marker cross at each node
			CSQC_DebugBeam(p - '5 0 0', p + '5 0 0', 2, '0.3 1 0.4', 0.7);
			CSQC_DebugBeam(p - '0 5 0', p + '0 5 0', 2, '0.3 1 0.4', 0.7);
			CSQC_DebugBeam(p - '0 0 6', p + '0 0 6', 2, '0.3 1 0.4', 0.7);
			// links — draw each undirected edge once (only toward higher index)
			float lc = navdbg_linkcount[i];
			for (k = 0; k < lc; k = k + 1)
			{
				float nb = navdbg_link[i * NAVDBG_LINKS + k];
				if (nb > i && nb >= 0 && nb < cap)
					CSQC_DebugBeam(p, navdbg_pos[nb], 1.5, '0.2 0.55 1', 0.35);
			}
		}
	}

	if (botdbg_n > 0 && (cltime - botdbg_last) < NAVDBG_STALE)
	{
		for (i = 0; i < botdbg_n; i = i + 1)
		{
			if (botdbg_state[i] == 2 && botdbg_enemy[i] >= 1)
			{
				entity ep = findfloat(world, vis_owner_entnum, botdbg_enemy[i]);
				if (ep)
					CSQC_DebugBeam(botdbg_pos[i], ep.origin + '0 0 28', 2.5, '1 0.25 0.25', 0.5);
			}
		}
	}

	// Spectated bot's A* path — amber polyline through its waypoints, a bright marker
	// on the current waypoint, a purple marker on the roam goal.  Node indices resolve
	// against the cached graph (navdbg_pos), bounds-checked vs navdbg_have.
	if (spec_target >= 1 && botpath_n > 0
	    && (cltime - botpath_last) < NAVDBG_STALE
	    && navdbg_count > 0 && (cltime - navdbg_last) < NAVDBG_STALE)
	{
		float j = -1;
		for (i = 0; i < botpath_n; i = i + 1)
			if (botpath_ent[i] == spec_target) { j = i; break; }
		if (j >= 0)
		{
			float plen = botpath_len[j];
			float cur  = botpath_cur[j];
			vector prev = '0 0 0';
			float have_prev = FALSE;
			for (k = 0; k < plen; k = k + 1)
			{
				float node = botpath_node[j * BOTDBG_PATHLEN + k];
				if (node < 0 || node >= navdbg_have)
					continue;			// unresolved node index
				vector wp = navdbg_pos[node];
				if (have_prev)
					CSQC_DebugBeam(prev, wp, 2.5, '1 0.7 0.15', 0.75);
				prev = wp;
				have_prev = TRUE;
				if (k == cur)
				{	// current waypoint — bigger + brighter
					CSQC_DebugBeam(wp - '10 0 0', wp + '10 0 0', 4, '1 1 0.3', 0.95);
					CSQC_DebugBeam(wp - '0 10 0', wp + '0 10 0', 4, '1 1 0.3', 0.95);
					CSQC_DebugBeam(wp - '0 0 14', wp + '0 0 14', 4, '1 1 0.3', 0.95);
				}
				else
				{
					CSQC_DebugBeam(wp - '5 0 0', wp + '5 0 0', 2.5, '1 0.7 0.15', 0.85);
					CSQC_DebugBeam(wp - '0 5 0', wp + '0 5 0', 2.5, '1 0.7 0.15', 0.85);
				}
			}
			float gnode = botpath_goal[j];
			if (gnode >= 0 && gnode < navdbg_have)
			{
				vector gp = navdbg_pos[gnode];
				CSQC_DebugBeam(gp - '8 0 0', gp + '8 0 0', 3, '0.8 0.3 1', 0.9);
				CSQC_DebugBeam(gp - '0 8 0', gp + '0 8 0', 3, '0.8 0.3 1', 0.9);
				CSQC_DebugBeam(gp - '0 0 18', gp + '0 0 18', 3, '0.8 0.3 1', 0.9);
			}
		}
	}
};

// 2D: floating "state / weapon / mag" label over each bot.  Call after renderscene.
void() NavDebug_DrawText =
{
	if (botdbg_n <= 0 || (cltime - botdbg_last) >= NAVDBG_STALE)
		return;

	float prev_font = drawfont;
	drawfont = hud_font;
	float i;
	for (i = 0; i < botdbg_n; i = i + 1)
	{
		vector scr = project(botdbg_pos[i]);
		if (scr_z <= 0)
			continue;				// behind the camera

		float st = botdbg_state[i];
		vector col = '0.5 0.9 1';
		if (st == 2)      col = '1 0.35 0.35';
		else if (st == 1) col = '1 0.9 0.4';

		string lbl = sprintf("#%g %s  %s  %g",
			botdbg_ent[i], NavDebug_StateName(st),
			Weapon_DisplayName(botdbg_wep[i]), botdbg_mag[i]);

		vector sz = '8 8 0';
		float w = stringwidth(lbl, 1, sz);
		float sx = scr_x - w * 0.5;
		float sy = scr_y;
		drawstring([sx + 1, sy + 1], lbl, sz, '0 0 0', 0.7, 0);
		drawstring([sx, sy], lbl, sz, col, 0.95, 0);
	}

	// Fixed status panel for the spectated bot: state / target / weapon / path.
	if (spec_target >= 1)
	{
		float sj = -1, si;
		for (si = 0; si < botdbg_n; si = si + 1)
			if (botdbg_ent[si] == spec_target) { sj = si; break; }
		if (sj >= 0)
		{
			float sst = botdbg_state[sj];
			vector scol = '0.5 0.9 1';
			if (sst == 2)      scol = '1 0.35 0.35';
			else if (sst == 1) scol = '1 0.9 0.4';

			string tgt = "-";
			if (botdbg_enemy[sj] >= 1)
			{
				string tn = getplayerkeyvalue(botdbg_enemy[sj] - 1, INFOKEY_P_NAME);
				tgt = (tn != "") ? tn : sprintf("#%g", botdbg_enemy[sj]);
			}

			float pj = -1, pk;
			for (pk = 0; pk < botpath_n; pk = pk + 1)
				if (botpath_ent[pk] == spec_target) { pj = pk; break; }

			float px = 18, py = g_height * 0.45;
			drawstring([px, py],      sprintf("BOT #%g  %s", spec_target, NavDebug_StateName(sst)), '11 11 0', scol, 0.95, 0);
			drawstring([px, py + 16], sprintf("target: %s", tgt), '9 9 0', '1 1 1', 0.9, 0);
			drawstring([px, py + 28], sprintf("weapon: %s  mag %g", Weapon_DisplayName(botdbg_wep[sj]), botdbg_mag[sj]), '9 9 0', '1 1 1', 0.9, 0);
			if (pj >= 0 && (cltime - botpath_last) < NAVDBG_STALE)
				drawstring([px, py + 40], sprintf("path: %g/%g  goal #%g", botpath_cur[pj], botpath_len[pj], botpath_goal[pj]), '9 9 0', '0.8 0.85 1', 0.9, 0);
		}
	}

	drawfont = prev_font;
};
