//
//  cl_vote.qc  —  CSQC half of trigger_vote
//
//  A corner prompt with the question, a countdown, a live tally and two answer
//  keys.  Deliberately NOT a cursor panel: both votes in pizza_ya_san1 fire
//  during normal gameplay, and taking the mouse mid-firefight to answer a
//  question would get people killed.  So this follows cl_radio.qc's
//  selective-consumption model — it eats F1/F2 and nothing else — rather than
//  cl_debugpanel.qc's `return TRUE` swallow.
//
//  Drawn with raw drawstring/drawfill, outside the sui_begin bracket in
//  cl_main.qc.  That bracket exists for cursor panels and sui_begin is not
//  re-entrant, so a vote must not join it.
//

float  vote_open;
string vote_question;
string vote_yes_label;
string vote_no_label;
float  vote_close_time;         // cltime when the prompt expires
float  vote_pass_pct;
float  vote_count_yes;
float  vote_count_no;
float  vote_count_eligible;
float  vote_my_answer;          // 0 none, 1 yes, 2 no — local echo

const float VOTE_KEY_YES = K_F1;
const float VOTE_KEY_NO  = K_F2;

void() Vote_Close =
{
    if (!vote_open)
        return;
    vote_open = 0;
    // Strings arrived from the wire via readstring(), which returns a
    // tempstring — they were strzone'd on receipt, so release them here or the
    // zone leaks one question per vote for the whole map.
    if (vote_question  != "") { strunzone(vote_question);  vote_question  = ""; }
    if (vote_yes_label != "") { strunzone(vote_yes_label); vote_yes_label = ""; }
    if (vote_no_label  != "") { strunzone(vote_no_label);  vote_no_label  = ""; }
};

float() Vote_IsOpen =
{
    return vote_open;
};

// ---------------------------------------------------------------------------
//  Event parsing
// ---------------------------------------------------------------------------
void() CSQC_Vote_ParseStart =
{
    string q   = readstring();
    string yl  = readstring();
    string nl  = readstring();
    float  dur = readbyte();
    float  pct = readbyte();

    Vote_Close();               // release any previous strings first

    vote_question   = strzone(q);
    vote_yes_label  = strzone(yl);
    vote_no_label   = strzone(nl);
    vote_close_time = cltime + dur;
    vote_pass_pct   = pct;
    vote_my_answer  = 0;
    vote_count_yes  = 0;
    vote_count_no   = 0;
    vote_open       = 1;
};

void() CSQC_Vote_ParseUpdate =
{
    vote_count_yes      = readbyte();
    vote_count_no       = readbyte();
    vote_count_eligible = readbyte();
};

void() CSQC_Vote_ParseEnd =
{
    float outcome = readbyte();
    Vote_Close();
    if (outcome == 1)      print("Vote passed.\n");
    else if (outcome == 2) print("Nobody voted.\n");
    else                   print("Vote failed.\n");
};

// ---------------------------------------------------------------------------
//  Answering
// ---------------------------------------------------------------------------
void(float choice) Vote_Send =
{
    if (!vote_open)
        return;
    if (choice != 1 && choice != 2)
        return;
    vote_my_answer = choice;    // optimistic local echo; the tally that comes
                                // back from the server is authoritative
    sendevent("vote", "f", choice);
};

// Only F1/F2 are consumed, and only while a vote is live.  Everything else —
// movement, firing, the console — passes straight through.
float(float evtype, float scanx, float chary, float devid) Vote_InputEvent =
{
    if (!vote_open)
        return FALSE;
    if (evtype != IE_KEYDOWN)
        return FALSE;

    if (scanx == VOTE_KEY_YES) { Vote_Send(1); return TRUE; }
    if (scanx == VOTE_KEY_NO)  { Vote_Send(2); return TRUE; }
    return FALSE;
};

// Console form so players can bind their own keys: `bind h "vote yes"`.
// Registered in cl_main.qc's registercommand block.
float(string cmd) Vote_ConsoleCommand =
{
    if (argv(0) != "vote")
        return FALSE;
    string a = strtolower(argv(1));
    if (a == "yes" || a == "y" || a == "1") Vote_Send(1);
    else if (a == "no" || a == "n" || a == "2") Vote_Send(2);
    else print("usage: vote yes|no\n");
    return TRUE;
};

// ---------------------------------------------------------------------------
//  Drawing
// ---------------------------------------------------------------------------
void() Vote_Draw =
{
    if (!vote_open)
        return;

    float left = vote_close_time - cltime;
    if (left < 0)
    {
        // The server's END packet is authoritative, but if it is late (or
        // lost) the prompt must not sit on screen forever.
        if (left < -3)
        {
            Vote_Close();       // clears vote_open and frees the wire strings
            return;             // ...so there is nothing left to draw
        }
        left = 0;
    }

    // Bracket the font the way every other panel in client/ does (cl_radio.qc,
    // cl_hud.qc, cl_env_hud.qc, cl_buymenu.qc).  Without this the panel drew in
    // whatever drawfont was ambient — the CSQC_Init default, whose size list is
    // comma-separated and so parses as a SINGLE token under FTE's
    // whitespace-only COM_Parse, baking exactly one size (12).  Every size other
    // than 12 was therefore bilinear-resampled from that one bucket, which is
    // the blur.  hud_font_mono bakes 8/12/16/18/24/32/36/48/60/72, so the sizes
    // below are all real buckets and render 1:1 at native resolution.
    // Keep every drawstring size in this function on that list.
    float prev_font = drawfont;
    drawfont = hud_font_mono;

    float pad = 10;
    vector fs = '12 12 0';
    float  w  = 300;
    float  h  = 92;
    float  x  = g_width - w - 16;
    float  y  = g_height * 0.28;

    drawfill([x, y], [w, h], '0.04 0.04 0.06', 0.85, 0);
    drawfill([x, y], [w, 2], '0.25 0.65 0.35', 0.9, 0);

    drawstring([x + pad, y + 6], sprintf("VOTE  (%ds)", ceil(left)),
               '12 12 0', '0.6 0.9 0.7', 1, 0);

    // The question can be long ("START ?  <pizza_ya_san1>"); clip it to the
    // panel rather than letting it run off the right edge of the screen.
    drawsetcliparea(x + pad, y + 22, w - pad * 2, 20);
    drawstring([x + pad, y + 24], vote_question, fs, '1 1 1', 1, 0);
    drawresetcliparea();

    // Answer keys, highlighted once this client has picked one.
    vector yescol = (vote_my_answer == 1) ? '0.4 1 0.5' : '0.8 0.8 0.8';
    vector nocol  = (vote_my_answer == 2) ? '1 0.5 0.4' : '0.8 0.8 0.8';
    drawstring([x + pad, y + 46],
               sprintf("[F1] %s  %d", vote_yes_label, vote_count_yes),
               fs, yescol, 1, 0);
    drawstring([x + pad + 150, y + 46],
               sprintf("[F2] %s  %d", vote_no_label, vote_count_no),
               fs, nocol, 1, 0);

    // Progress bar: share of those who have VOTED saying yes, against the
    // threshold.  Non-voters are excluded, matching how the server resolves it
    // — showing it against the player count instead would read as "failing"
    // right up until the moment it passes.
    float voted = vote_count_yes + vote_count_no;
    float frac  = voted > 0 ? (vote_count_yes / voted) : 0;
    float barw  = w - pad * 2;
    drawfill([x + pad, y + 68], [barw, 8], '0.15 0.15 0.18', 0.9, 0);
    if (frac > 0)
        drawfill([x + pad, y + 68], [barw * frac, 8], '0.3 0.75 0.4', 0.9, 0);
    // Threshold marker
    drawfill([x + pad + barw * (vote_pass_pct / 100) - 1, y + 66], [2, 12],
             '1 0.9 0.3', 0.9, 0);

    drawstring([x + pad, y + 78],
               sprintf("%d%% of %d voted  (need %d%%)",
                       frac * 100, voted, vote_pass_pct),
               '8 8 0', '0.6 0.6 0.65', 1, 0);

    drawfont = prev_font;
};
