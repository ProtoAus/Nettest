/*
 * Copyright (c) 2016-2020 Marco Cawthorne <marco@icculus.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#define SCORE_HEADER_C [255/255,156/255,0]
#define SCORE_LINE_C [255/255,200/255,0]
var bool autocvar_cg_centerScores = true;
var int g_scores_teamplay = 0;
var bool g_scores_scorepoints = false;

void
Scores_Init(void)
{
	g_scores_teamplay = (int)serverkeyfloat("teamplay");
	g_scores_scorepoints = (bool)serverkeyfloat("scorepoints");
}

void
Scores_DrawTeam(ncPlayer pl, vector pos)
{
	drawfill(pos, [290, 1], SCORE_LINE_C, 1.0f, DRAWFLAG_ADDITIVE);

	draw.Text_RGBA(pos + [0,-18], "Teams", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);

	if (g_scores_scorepoints)
		draw.Text_RGBA(pos + [124-32,-18], "kills / deaths / score", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
	else
		draw.Text_RGBA(pos + [124,-18], "kills / deaths", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);

	draw.Text_RGBA(pos + [240,-18], "latency", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
	
	pos[1] += 12;

	for (int t = 1; t <= serverkeyfloat("teams"); t++) {
		float l;
		string temp;
		draw.Text_RGBA(pos, serverkey(sprintf("team_%i", t)), SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
		temp = serverkey(sprintf("teamscore_%i", t));
		l = font.StringWidth(temp, false, FONT_SCOREBOARD);
		draw.Text_RGBA(pos + [150-l, 0], temp, SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
		draw.Text_RGBA(pos + [158, 0], "wins", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
		pos[1] += 16;

		for (int i = -1; i > -32; i--) {
			if (getplayerkeyfloat(i, "*team") != t) {
				continue;
			}

			temp = getplayerkeyvalue(i, "name");

			/* Out of players */
			if (!temp) {
				break;
			} else if (temp == getplayerkeyvalue(pl.entnum-1, "name")) {
				drawfill(pos, [290, 13], [0,0,1], 0.5f, DRAWFLAG_ADDITIVE);
			}

			draw.Text_RGBA(pos + [24,0], getplayerkeyvalue(i, "name"), [1,1,1], 1.0f, FONT_SCOREBOARD);

			if (g_scores_scorepoints) {
				draw.Text_RGBA(pos + [154-32,0], "/", [1,1,1], 1.0f, FONT_SCOREBOARD);

				/* Get the kills and align them left to right */
				temp = getplayerkeyvalue(i, "frags");
				l = font.StringWidth(temp, false, FONT_SCOREBOARD);
				draw.Text_RGBA(pos + [150 - 32 - l,0], temp, [1,1,1], 1.0f, FONT_SCOREBOARD);
				
				draw.Text_RGBA(pos + [154+26,0], "/", [1,1,1], 1.0f, FONT_SCOREBOARD);

				/* Deaths are right to left aligned */
				temp = getplayerkeyvalue(i, "*deaths");
				if (!temp) temp = "0";
				l = font.StringWidth(temp, false, FONT_SCOREBOARD);
				draw.Text_RGBA(pos + [165 - l,0], temp, [1,1,1], 1.0f, FONT_SCOREBOARD);

				/* Deaths are right to left aligned */
				temp = getplayerkeyvalue(i, "*score");
				if (!temp) temp = "0";
				draw.Text_RGBA(pos + [165+32,0], temp, [1,1,1], 1.0f, FONT_SCOREBOARD);
			} else {
				draw.Text_RGBA(pos + [154,0], "/", [1,1,1], 1.0f, FONT_SCOREBOARD);

				/* Get the kills and align them left to right */
				temp = getplayerkeyvalue(i, "frags");
				l = font.StringWidth(temp, false, FONT_SCOREBOARD);
				draw.Text_RGBA(pos + [150 - l,0], temp, [1,1,1], 1.0f, FONT_SCOREBOARD);

				/* Deaths are right to left aligned */
				temp = getplayerkeyvalue(i, "*deaths");
				draw.Text_RGBA(pos + [165,0], temp, [1,1,1], 1.0f, FONT_SCOREBOARD);
			}

			vector tmpColor;
			temp = getplayerkeyvalue(i, "*icon1");
			if (STRING_SET(temp)) {
				tmpColor[0] = getplayerkeyfloat(i, "*icon1_r");
				tmpColor[1] = getplayerkeyfloat(i, "*icon1_g");
				tmpColor[2] = getplayerkeyfloat(i, "*icon1_b");
				atlasPic.Draw_RGB(atlasPic.Load(temp), pos - [8, 0], tmpColor, true);
			}

			temp = getplayerkeyvalue(i, "*icon2");
			if (STRING_SET(temp)) {
				tmpColor[0] = getplayerkeyfloat(i, "*icon2_r");
				tmpColor[1] = getplayerkeyfloat(i, "*icon2_g");
				tmpColor[2] = getplayerkeyfloat(i, "*icon2_b");
				atlasPic.Draw_RGB(atlasPic.Load(temp), pos + [8, 0], tmpColor, true);
			}

			/* Get the latency and align it left to right */
			temp = getplayerkeyvalue(i, "ping");
			l = font.StringWidth(temp, false, FONT_SCOREBOARD);

			draw.Text_RGBA(pos + [290 - l,0], temp, [1,1,1], 1.0f, FONT_SCOREBOARD);
			pos[1] += 20;
		}
		pos[1] += 12;
	}
}

void
Scores_DrawNormal(ncPlayer pl, vector pos)
{
	drawfill(pos, [290, 1], SCORE_LINE_C, 1.0f, DRAWFLAG_ADDITIVE);

	draw.Text_RGBA(pos + [0,-18], "Player", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
	draw.Text_RGBA(pos + [124,-18], "kills / deaths", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
	draw.Text_RGBA(pos + [240,-18], "latency", SCORE_HEADER_C, 1.0f, FONT_SCOREBOARD);
	
	pos[1] += 12;
	for (int i = -1; i > -32; i--) {
		float l;
		string ping;
		string kills;
		string deaths;
		string name;

		if (getplayerkeyfloat(i, "*spec") != 0) {
			continue;
		}

		name = getplayerkeyvalue(i, "name");

		/* Out of players */
		if (!name) {
			break;
		} else if (name == getplayerkeyvalue(pl.entnum-1, "name")) {
			drawfill(pos, [290, 13], [0,0,1], 0.5f, DRAWFLAG_ADDITIVE);
		}

		draw.Text_RGBA(pos, getplayerkeyvalue(i, "name"), [1,1,1], 1.0f, FONT_SCOREBOARD);
		draw.Text_RGBA(pos + [154,0], "/", [1,1,1], 1.0f, FONT_SCOREBOARD);

		/* Get the kills and align them left to right */
		kills = getplayerkeyvalue(i, "frags");
		l = font.StringWidth(kills, false, FONT_SCOREBOARD);
		draw.Text_RGBA(pos + [150 - l,0], kills, [1,1,1], 1.0f, FONT_SCOREBOARD);

		/* Deaths are right to left aligned */
		deaths = getplayerkeyvalue(i, "*deaths");
		draw.Text_RGBA(pos + [165,0], deaths, [1,1,1], 1.0f, FONT_SCOREBOARD);

		/* Get the latency and align it left to right */
		ping = getplayerkeyvalue(i, "ping");
		l = font.StringWidth(ping, false, FONT_SCOREBOARD);

		draw.Text_RGBA(pos + [290 - l,0], ping, [1,1,1], 1.0f, FONT_SCOREBOARD);
		pos[1] += 20;
	}
}

void
Scores_Draw(void)
{
	vector pos;
	ncPlayer pl;
	
	pl = (ncPlayer)pSeat->m_ePlayer;
	int teamCount = teams.TeamCount();
	int c = 6i;

	if (autocvar_cg_centerScores) {
		if (teamCount > 0i) {
			for (int t = 1; t <= serverkeyfloat("teams"); t++) {
				c += 16;

				for (int i = -1; i > -32; i--) {
					string playerName = getplayerkeyvalue(i, "name");

					if (getplayerkeyfloat(i, "*team") != t) {
						continue;
					}

					/* Out of players */
					if (!STRING_SET(playerName)) {
						break;
					}
					c += 10;
				}
				c += 6;
			}
		} else {
			for (int i = -1; i > -32; i--) {
				string playerName = getplayerkeyvalue(i, "name");

				if (!STRING_SET(playerName)) {
					break;
				}

				c += 10;
			}
		}
		pos = video_mins + [(g_vidsize[0] / 2) - 145, (g_vidsize[1] / 2) - c];
	} else {
		pos = video_mins + [(g_vidsize[0] / 2) - 145, 30];
	}

	if (Util_IsTeamplay()) {
		Scores_DrawTeam(pl, pos);
	} else {
		Scores_DrawNormal(pl, pos);
	}
}
