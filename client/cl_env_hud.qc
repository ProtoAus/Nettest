//
// cl_env_hud.qc — client receivers for HL env_fade / env_message
//
// env_fade is a simple full-screen drawfill driven by a server event.
// env_message resolves its message key against titles.txt on the client
// so the same map/mod text file controls position, colour, and timing.
//

const float ENVFADE_FROM           = 1;
const float ENVFADE_MODULATE       = 2;
const float ENVHUD_DRAWFLAG_MODULATE = 2;
const float ENVHUD_EVENT_FADE      = 1;
const float ENVHUD_EVENT_MESSAGE   = 2;
const float ENVHUD_PENDING_MAX     = 32;
const float ENVHUD_DEFER_WINDOW    = 60;

float  env_fade_start;
float  env_fade_duration;
float  env_fade_hold;
float  env_fade_alpha;
float  env_fade_flags;
vector env_fade_colour;

// Two parallel message slots so HL's "big centered title" and the
// stream of bottom-left credits (CR1..CRN) can coexist on screen.
// Slot 0 = centered title (env_msg_pos.y < 0 i.e. -1 -1 auto-centre).
// Slot 1 = positioned credit (specific 0..1 fraction in titles.txt).
// Each pump/parse routes into the correct slot based on the resolved
// position from titles.txt; same-slot messages still overwrite each
// other (HL semantics — a new credit replaces the previous one in
// the same screen position).
//
// The legacy single-slot fields (env_msg_text, env_msg_start, etc.)
// are aliased into slot 0 via helper macros for the existing draw /
// alpha helpers to keep working without a sweeping rename — those
// helpers take an implicit slot via the `current_slot` global below.
float  current_slot;     // implicit "active" slot for the alpha / draw helpers

// Four slots, not two.  GoldSrc game_text carries an explicit `channel`
// key (1..4) and HL keeps each channel independent, so two messages on
// different channels coexist.  Measured on pizza_ya_san1: 74 game_texts
// split across channels 1 (68) and 2 (6), and every one of them has
// y >= 0 — so under the old position-based routing ALL 74 collapsed into
// slot 1 and overwrote each other.
//
// Slot 0 stays the "centred title" slot that env_message / titles.txt
// routes into by position, so existing behaviour is unchanged for those.
const float ENVHUD_SLOTS = 4;

string env_msg_text_s[ENVHUD_SLOTS];
float  env_msg_start_s[ENVHUD_SLOTS];
float  env_msg_effect_s[ENVHUD_SLOTS];
vector env_msg_pos_s[ENVHUD_SLOTS];
vector env_msg_colour_s[ENVHUD_SLOTS];
vector env_msg_colour2_s[ENVHUD_SLOTS];
float  env_msg_fadein_s[ENVHUD_SLOTS];
float  env_msg_fadeout_s[ENVHUD_SLOTS];
float  env_msg_hold_s[ENVHUD_SLOTS];
float  env_msg_fxtime_s[ENVHUD_SLOTS];

// Scratch variables the parser / draw helpers read.  Routed to the
// per-slot fields by EnvHud_SlotLoad / EnvHud_SlotStore below.
string env_msg_text;
float  env_msg_start;
float  env_msg_effect;
vector env_msg_pos;
vector env_msg_colour;
vector env_msg_colour2;
float  env_msg_fadein;
float  env_msg_fadeout;
float  env_msg_hold;
float  env_msg_fxtime;

void(float s) EnvHud_SlotLoad =
{
    s = bound(0, s, ENVHUD_SLOTS - 1);
    env_msg_text    = env_msg_text_s[s];
    env_msg_start   = env_msg_start_s[s];
    env_msg_effect  = env_msg_effect_s[s];
    env_msg_pos     = env_msg_pos_s[s];
    env_msg_colour  = env_msg_colour_s[s];
    env_msg_colour2 = env_msg_colour2_s[s];
    env_msg_fadein  = env_msg_fadein_s[s];
    env_msg_fadeout = env_msg_fadeout_s[s];
    env_msg_hold    = env_msg_hold_s[s];
    env_msg_fxtime  = env_msg_fxtime_s[s];
};

void(float s) EnvHud_SlotStore =
{
    s = bound(0, s, ENVHUD_SLOTS - 1);
    env_msg_text_s[s]    = env_msg_text;
    env_msg_start_s[s]   = env_msg_start;
    env_msg_effect_s[s]  = env_msg_effect;
    env_msg_pos_s[s]     = env_msg_pos;
    env_msg_colour_s[s]  = env_msg_colour;
    env_msg_colour2_s[s] = env_msg_colour2;
    env_msg_fadein_s[s]  = env_msg_fadein;
    env_msg_fadeout_s[s] = env_msg_fadeout;
    env_msg_hold_s[s]    = env_msg_hold;
    env_msg_fxtime_s[s]  = env_msg_fxtime;
};

float  envhud_pending_count;
float  envhud_pending_base_time;
float  envhud_pending_flush_time;
float  envhud_pending_deferred;
float  envhud_pending_type[32];
float  envhud_pending_delay[32];
vector envhud_pending_colour[32];
float  envhud_pending_alpha[32];
float  envhud_pending_duration[32];
float  envhud_pending_hold[32];
float  envhud_pending_flags[32];
string envhud_pending_message[32];

float() EnvHud_Debug =
{
    return cvar("cl_envhud_debug");
};

float() EnvHud_PlayerReady =
{
    float team = getstati(STAT_PLAYERTEAM);
    return (team == TEAM_BLUE || team == TEAM_RED);
};

string(string s) EnvHud_Chomp =
{
    float n = strlen(s);
    while (n > 0)
    {
        float c = str2chr(s, n - 1);
        if (c != 10 && c != 13)
            break;
        s = substring(s, 0, n - 1);
        n = n - 1;
    }
    return s;
};

string(string s) EnvHud_Trim =
{
    s = EnvHud_Chomp(s);
    float n = strlen(s);
    float a = 0;
    while (a < n)
    {
        float c = str2chr(s, a);
        if (c != 32 && c != 9)
            break;
        a = a + 1;
    }

    float b = n;
    while (b > a)
    {
        float c2 = str2chr(s, b - 1);
        if (c2 != 32 && c2 != 9)
            break;
        b = b - 1;
    }
    return substring(s, a, b - a);
};

vector(float r, float g, float b) EnvHud_Colour255 =
{
    return [bound(0, r, 255) * (1.0 / 255.0),
            bound(0, g, 255) * (1.0 / 255.0),
            bound(0, b, 255) * (1.0 / 255.0)];
};

void() EnvHud_DefaultTitle =
{
    env_msg_pos      = '-1 -1 0';
    env_msg_effect   = 0;
    env_msg_colour   = '1 1 1';
    env_msg_colour2  = '1 1 1';
    env_msg_fadein   = 0.5;
    env_msg_fadeout  = 0.5;
    env_msg_hold     = 4.0;
    env_msg_fxtime   = 0.25;
};

void() EnvHud_ClearPending =
{
    float i;
    for (i = 0; i < ENVHUD_PENDING_MAX; i = i + 1)
    {
        if (envhud_pending_message[i] != "")
            strunzone(envhud_pending_message[i]);
        envhud_pending_message[i] = "";
        envhud_pending_type[i] = 0;
    }

    envhud_pending_count = 0;
    envhud_pending_base_time = 0;
    envhud_pending_flush_time = 0;
    envhud_pending_deferred = 0;
};

void() EnvHud_PopPending =
{
    if (envhud_pending_count <= 0)
        return;

    if (envhud_pending_message[0] != "")
        strunzone(envhud_pending_message[0]);

    float i;
    for (i = 1; i < envhud_pending_count; i = i + 1)
    {
        float dst = i - 1;
        envhud_pending_type[dst]     = envhud_pending_type[i];
        envhud_pending_delay[dst]    = envhud_pending_delay[i];
        envhud_pending_colour[dst]   = envhud_pending_colour[i];
        envhud_pending_alpha[dst]    = envhud_pending_alpha[i];
        envhud_pending_duration[dst] = envhud_pending_duration[i];
        envhud_pending_hold[dst]     = envhud_pending_hold[i];
        envhud_pending_flags[dst]    = envhud_pending_flags[i];
        envhud_pending_message[dst]  = envhud_pending_message[i];
    }

    envhud_pending_count = envhud_pending_count - 1;
    envhud_pending_type[envhud_pending_count] = 0;
    envhud_pending_message[envhud_pending_count] = "";
};

float() EnvHud_ShouldDeferEvent =
{
    if (!EnvHud_PlayerReady())
        return TRUE;

    if (envhud_pending_deferred
        && envhud_pending_base_time > 0
        && envhud_pending_flush_time > 0
        && cltime - envhud_pending_base_time < ENVHUD_DEFER_WINDOW)
    {
        float script_elapsed = cltime - envhud_pending_base_time;
        float replay_elapsed = cltime - envhud_pending_flush_time;
        if (script_elapsed > replay_elapsed)
            return TRUE;
    }

    return FALSE;
};

float() EnvHud_QueueSlot =
{
    if (envhud_pending_count >= ENVHUD_PENDING_MAX)
    {
        if (EnvHud_Debug())
            print("[envhud] pending queue full; dropping event\n");
        return -1;
    }

    if (!envhud_pending_deferred)
    {
        envhud_pending_deferred = TRUE;
        envhud_pending_base_time = cltime;
        envhud_pending_flush_time = 0;
    }

    float slot = envhud_pending_count;
    envhud_pending_count = envhud_pending_count + 1;
    envhud_pending_delay[slot] = cltime - envhud_pending_base_time;
    if (envhud_pending_delay[slot] < 0)
        envhud_pending_delay[slot] = 0;
    return slot;
};

void(vector col, float alpha, float duration_s, float hold_s, float flags) EnvHud_StartFade =
{
    env_fade_colour  = col;
    env_fade_alpha   = alpha;
    env_fade_duration = duration_s;
    env_fade_hold    = hold_s;
    env_fade_flags   = flags;
    env_fade_start   = cltime;

    if (EnvHud_Debug())
        print(sprintf("[envhud] fade start colour=%v alpha=%.2f duration=%.2f hold=%.2f flags=%g\n",
                      col, alpha, duration_s, hold_s, flags));
};

void(vector col, float alpha, float duration_s, float hold_s, float flags) EnvHud_QueueFade =
{
    float slot = EnvHud_QueueSlot();
    if (slot < 0)
        return;

    envhud_pending_type[slot]     = ENVHUD_EVENT_FADE;
    envhud_pending_colour[slot]   = col;
    envhud_pending_alpha[slot]    = alpha;
    envhud_pending_duration[slot] = duration_s;
    envhud_pending_hold[slot]     = hold_s;
    envhud_pending_flags[slot]    = flags;

    if (EnvHud_Debug())
        print(sprintf("[envhud] queued fade delay=%.2f ready=%g\n",
                      envhud_pending_delay[slot], EnvHud_PlayerReady()));
};

void(string msg) EnvHud_QueueMessage =
{
    float slot = EnvHud_QueueSlot();
    if (slot < 0)
        return;

    envhud_pending_type[slot] = ENVHUD_EVENT_MESSAGE;
    envhud_pending_message[slot] = strzone(msg);

    if (EnvHud_Debug())
        print(sprintf("[envhud] queued message '%s' delay=%.2f ready=%g\n",
                      msg, envhud_pending_delay[slot], EnvHud_PlayerReady()));
};

void(string line) EnvHud_ApplyTitleCommand =
{
    float argc = tokenize(line);
    if (argc <= 0)
        return;

    string cmd = strtolower(argv(0));
    if (cmd == "$position" && argc >= 3)
    {
        env_msg_pos_x = stof(argv(1));
        env_msg_pos_y = stof(argv(2));
    }
    else if (cmd == "$effect" && argc >= 2)
    {
        env_msg_effect = stof(argv(1));
    }
    else if (cmd == "$color" && argc >= 4)
    {
        env_msg_colour = EnvHud_Colour255(stof(argv(1)), stof(argv(2)), stof(argv(3)));
    }
    else if (cmd == "$color2" && argc >= 4)
    {
        env_msg_colour2 = EnvHud_Colour255(stof(argv(1)), stof(argv(2)), stof(argv(3)));
    }
    else if (cmd == "$fadein" && argc >= 2)
    {
        env_msg_fadein = stof(argv(1));
    }
    else if (cmd == "$fadeout" && argc >= 2)
    {
        env_msg_fadeout = stof(argv(1));
    }
    else if (cmd == "$holdtime" && argc >= 2)
    {
        env_msg_hold = stof(argv(1));
    }
    else if (cmd == "$fxtime" && argc >= 2)
    {
        env_msg_fxtime = stof(argv(1));
    }
};

float(string text) EnvHud_LineCount =
{
    if (text == "")
        return 0;

    float lines = 1;
    float i;
    float n = strlen(text);
    for (i = 0; i < n; i = i + 1)
        if (str2chr(text, i) == 10)
            lines = lines + 1;
    return lines;
};

float(string text, vector sz) EnvHud_MaxLineWidth =
{
    float maxw = 0;
    float start = 0;
    float i;
    float n = strlen(text);
    for (i = 0; i <= n; i = i + 1)
    {
        if (i == n || str2chr(text, i) == 10)
        {
            string line = substring(text, start, i - start);
            float w = stringwidth(line, FALSE, sz);
            if (w > maxw)
                maxw = w;
            start = i + 1;
        }
    }
    return maxw;
};

void(string text, vector colour, float alpha) EnvHud_DrawMultiline =
{
    if (text == "" || alpha <= 0)
        return;

    vector sz = '18 18 0';
    float line_h = 21;
    float lines = EnvHud_LineCount(text);
    float block_h = lines * line_h;
    float maxw = EnvHud_MaxLineWidth(text, sz);

    // cl_envhud_force_center 1 = ignore titles.txt $position and
    // slam every message into the screen centre.  Diagnostic toggle
    // for "I don't see the message — is it off-screen or just not
    // rendering?".  Flip on, fire a message: if it shows centred,
    // the bug is positional; if not, look upstream.
    float force_center = cvar("cl_envhud_force_center");
    float pos_x = force_center ? -1 : env_msg_pos_x;
    float pos_y = force_center ? -1 : env_msg_pos_y;

    float base_x;
    float base_y;
    if (pos_x < 0)
        base_x = g_width * 0.5 - maxw * 0.5;
    else
        base_x = g_width * pos_x;

    if (pos_y < 0)
        base_y = g_height * 0.5 - block_h * 0.5;
    else
        base_y = g_height * pos_y;

    if (EnvHud_Debug())
        print(sprintf("[envhud-draw] '%s' a=%.2f base=(%.0f %.0f) pos=(%.2f %.2f) force=%g\n",
                      text, alpha, base_x, base_y,
                      env_msg_pos_x, env_msg_pos_y, force_center));

    float start = 0;
    float i;
    float n = strlen(text);
    float row = 0;
    for (i = 0; i <= n; i = i + 1)
    {
        if (i == n || str2chr(text, i) == 10)
        {
            string line = substring(text, start, i - start);
            float x = base_x;
            if (pos_x < 0)
                x = g_width * 0.5 - stringwidth(line, FALSE, sz) * 0.5;
            float y = base_y + row * line_h;

            drawstring([x + 1, y + 1, 0], line, sz, '0 0 0', alpha * 0.45, 0);
            drawstring([x, y, 0], line, sz, colour, alpha, 0);

            start = i + 1;
            row = row + 1;
        }
    }
};

float(string title_name) EnvHud_LoadTitle =
{
    filestream f = fopen("titles.txt", FILE_READ);
    if (f < 0)
    {
        if (EnvHud_Debug())
            print(sprintf("[envhud] titles.txt not found; using raw message '%s'\n", title_name));
        return FALSE;
    }

    string want = strtolower(title_name);
    string line = fgets(f);
    while (line)
    {
        line = EnvHud_Trim(line);
        if (line == "" || substring(line, 0, 2) == "//")
        {
            line = fgets(f);
            continue;
        }

        if (substring(line, 0, 1) == "$")
        {
            EnvHud_ApplyTitleCommand(line);
            line = fgets(f);
            continue;
        }

        if (strtolower(line) == want)
        {
            // Skip down to the opening brace.
            line = fgets(f);
            while (line)
            {
                line = EnvHud_Trim(line);
                if (line == "{")
                    break;
                line = fgets(f);
            }

            string text = "";
            line = fgets(f);
            while (line)
            {
                string raw = EnvHud_Chomp(line);
                string t = EnvHud_Trim(raw);
                if (t == "}")
                    break;
                if (text == "")
                    text = raw;
                else
                    text = strcat(text, "\n", raw);
                line = fgets(f);
            }

            fclose(f);
            env_msg_text = strzone(text);
            if (EnvHud_Debug())
                print(sprintf("[envhud] titles.txt '%s' -> '%s'\n", title_name, text));
            return TRUE;
        }

        line = fgets(f);
    }

    fclose(f);
    if (EnvHud_Debug())
        print(sprintf("[envhud] title '%s' not found; using raw text\n", title_name));
    return FALSE;
};

void(string msg) EnvHud_StartMessage =
{
    // Parse into the scratch fields first.
    EnvHud_DefaultTitle();
    if (!EnvHud_LoadTitle(msg))
        env_msg_text = strzone(msg);
    env_msg_start = cltime;

    // Pick the destination slot based on the resolved position.
    // HL's titles.txt uses negative position (-1) to mean "auto-
    // centre"; specific 0..1 fractions are the bottom-left credit
    // style.  Routing on position lets a centered title and a
    // bottom-left credit display simultaneously without one
    // clobbering the other.
    float s = (env_msg_pos_y < 0) ? 0 : 1;

    // Debugging knob — cl_envhud_force_center 1 collapses every
    // message into the centered slot 0, ignoring positional routing.
    // Use to verify rendering: if a "missing" credit suddenly
    // appears once this is on, the bug is in the position math or
    // font/clip at the resolved x/y, not in the store/queue path.
    if (cvar("cl_envhud_force_center"))
    {
        env_msg_pos = '-1 -1 0';
        s = 0;
    }

    if (EnvHud_Debug())
        print(sprintf("[envhud] start '%s' slot=%g pos=%v hold=%.2f effect=%g text='%s'\n",
                      msg, s, env_msg_pos, env_msg_hold,
                      env_msg_effect, env_msg_text));

    // Free the previous text in the destination slot, then commit.
    if (env_msg_text_s[s] != "")
        strunzone(env_msg_text_s[s]);

    EnvHud_SlotStore(s);
    // Clear the scratch text pointer so EnvHud_DefaultTitle's next
    // call doesn't accidentally re-strunzone the slot's owned string.
    env_msg_text = "";
};

float() EnvHud_MessageAlpha =
{
    float t = cltime - env_msg_start;
    float a = 1;

    // cl_envhud_speed scales the typewriter per-character write
    // interval ONLY ($effect 2).  Below 1.0 makes the text scroll
    // out slower; above 1.0 faster.  Default 1.0 = titles.txt
    // fadein as authored.  fade/hold are left alone so the
    // titles.txt timings still control how long the message stays
    // on screen — slowing the speed shouldn't make centered titles
    // sit there longer, it should just type slower.
    float speed = cvar("cl_envhud_speed");
    if (speed <= 0) speed = 1;
    speed = bound(0.05, speed, 10);
    float inv = 1.0 / speed;

    float fadein  = env_msg_fadein;       // unscaled — controls non-typewriter fade-in
    float hold    = env_msg_hold;
    float fadeout = env_msg_fadeout;

    if (env_msg_effect == 2)
    {
        // Typewriter — scale the per-char reveal interval but leave
        // hold/fadeout authored.  fadein doubles as the per-char
        // write interval (matched in DrawMessages so the visible-char
        // count tracks).
        float typed_fadein = env_msg_fadein * inv;
        float write_time = typed_fadein * strlen(env_msg_text);
        if (write_time < 0)
            write_time = 0;
        if (t < write_time + hold)
            return 1;
        if (fadeout <= 0)
            return 0;
        a = 1 - (t - write_time - hold) / fadeout;
        return bound(0, a, 1);
    }

    if (fadein > 0 && t < fadein)
        a = t / fadein;
    else if (t < fadein + hold)
        a = 1;
    else if (fadeout > 0)
        a = 1 - (t - fadein - hold) / fadeout;
    else
        a = 0;

    a = bound(0, a, 1);
    // HL "flicker" effect (1) used per-frame random() during fade-in,
    // which strobed harshly at high refresh rates.  Swap to a smooth
    // time-driven sin wobble: same "the text is settling in" feel
    // without the seizure-inducing flash.  Wobble depth scales down
    // as we approach full fade-in so the message lands clean.
    if (env_msg_effect == 1 && fadein > 0 && t < fadein)
    {
        // Gentle "settling" wobble during fade-in.  Depth tapers off
        // toward the end of fadein so the text lands clean at full
        // alpha.  Previous 0.20 dipped to 80% of base which combined
        // with the fade-in ramp made the text noticeably dark for
        // ~half the fadein window; 0.06 is just enough to read as a
        // subtle pulse, never visibly dark.
        float fade_frac = t / fadein;
        float wobble = sin(t * 12) * 0.5 + 0.5;        // 0..1, ~2 Hz
        float depth  = (1.0 - fade_frac) * 0.06;       // 0.06 -> 0
        a = a * (1.0 - depth + wobble * depth);
    }
    return a;
};

void() CSQC_EnvHud_Reset =
{
    env_fade_start = 0;

    // Free the per-slot owned strings.  The scratch env_msg_text
    // pointer is just a copy view of one of the slot strings, so
    // strunzoning it would double-free; clear the scratch instead.
    float i;
    for (i = 0; i < ENVHUD_SLOTS; i = i + 1)
    {
        if (env_msg_text_s[i] != "") strunzone(env_msg_text_s[i]);
        env_msg_text_s[i]  = "";
        env_msg_start_s[i] = 0;
    }
    env_msg_text = "";
    env_msg_start = 0;
    EnvHud_ClearPending();
};

void() CSQC_EnvFade_Parse =
{
    vector col;
    float alpha;
    float duration_s;
    float hold_s;
    float flags;

    col_x      = readbyte() * (1.0 / 255.0);
    col_y      = readbyte() * (1.0 / 255.0);
    col_z      = readbyte() * (1.0 / 255.0);
    alpha      = readbyte() * (1.0 / 255.0);
    duration_s = readfloat();
    hold_s     = readfloat();
    flags      = readbyte();

    if (EnvHud_ShouldDeferEvent())
        EnvHud_QueueFade(col, alpha, duration_s, hold_s, flags);
    else
        EnvHud_StartFade(col, alpha, duration_s, hold_s, flags);
};

// ---------------------------------------------------------------------------
// CSQC_GameText_Parse — GoldSrc game_text.
//
// env_message resolves its styling client-side out of titles.txt; game_text
// carries the same styling INLINE on the map entity, so the server ships the
// resolved values and we fill the scratch fields directly rather than going
// through EnvHud_LoadTitle.
//
// Routing is by `channel`, not by position — see the ENVHUD_SLOTS comment.
// ---------------------------------------------------------------------------
void() CSQC_GameText_Parse =
{
    float  chan   = readbyte();
    float  px     = readcoord();
    float  py     = readcoord();
    float  fx     = readbyte();
    vector c1     = EnvHud_Colour255(readbyte(), readbyte(), readbyte());
    vector c2     = EnvHud_Colour255(readbyte(), readbyte(), readbyte());
    float  fadein = readfloat();
    float  fadeout= readfloat();
    float  hold   = readfloat();
    float  fxtime = readfloat();
    string msg    = readstring();

    if (msg == "")
        return;

    EnvHud_DefaultTitle();
    env_msg_pos     = [px, py, 0];
    env_msg_effect  = fx;
    env_msg_colour  = c1;
    env_msg_colour2 = c2;
    if (fadein  > 0) env_msg_fadein  = fadein;
    if (fadeout > 0) env_msg_fadeout = fadeout;
    if (hold    > 0) env_msg_hold    = hold;
    if (fxtime  > 0) env_msg_fxtime  = fxtime;
    env_msg_text  = strzone(msg);
    env_msg_start = cltime;

    // HL channels are 1-based; channel 0 / out of range lands in the last
    // slot rather than stomping slot 0 (the centred-title slot that
    // env_message owns).
    float s = chan - 1;
    if (s < 0 || s >= ENVHUD_SLOTS)
        s = ENVHUD_SLOTS - 1;

    if (cvar("cl_envhud_force_center"))
    {
        env_msg_pos = '-1 -1 0';
        s = 0;
    }

    if (EnvHud_Debug())
        print(sprintf("[envhud] game_text chan=%g slot=%g pos=%v effect=%g hold=%.2f text='%s'\n",
                      chan, s, env_msg_pos, env_msg_effect, env_msg_hold, msg));

    if (env_msg_text_s[s] != "")
        strunzone(env_msg_text_s[s]);
    EnvHud_SlotStore(s);
    env_msg_text = "";
};

void() CSQC_EnvMessage_Parse =
{
    string msg = readstring();
    if (EnvHud_ShouldDeferEvent())
        EnvHud_QueueMessage(msg);
    else
        EnvHud_StartMessage(msg);
};

void() CSQC_EnvHud_PumpPending =
{
    if (!EnvHud_PlayerReady())
        return;

    if (!envhud_pending_deferred)
        return;

    if (envhud_pending_flush_time <= 0)
    {
        envhud_pending_flush_time = cltime;
        if (EnvHud_Debug())
            print(sprintf("[envhud] replaying %g deferred event(s) after spawn\n",
                          envhud_pending_count));
    }

    float elapsed = cltime - envhud_pending_flush_time;
    while (envhud_pending_count > 0 && envhud_pending_delay[0] <= elapsed)
    {
        // No alpha gate: HL's credit roll relies on each new CRn
        // REPLACING the previous credit in the same slot the instant
        // the server's multi_manager fires it.  Holding the new
        // message back until the old faded made every credit after
        // the first one invisible while the first credit's hold
        // window was still active.  The one-per-frame break below
        // is still in place to prevent multiple queued events from
        // collapsing into the same tick — that's what kept us from
        // showing every credit when low fps grouped several delays
        // into one frame.
        float fired_type = envhud_pending_type[0];
        if (fired_type == ENVHUD_EVENT_FADE)
        {
            EnvHud_StartFade(envhud_pending_colour[0],
                             envhud_pending_alpha[0],
                             envhud_pending_duration[0],
                             envhud_pending_hold[0],
                             envhud_pending_flags[0]);
        }
        else if (fired_type == ENVHUD_EVENT_MESSAGE)
        {
            EnvHud_StartMessage(envhud_pending_message[0]);
        }

        EnvHud_PopPending();

        // After firing a message, bail — the next frame's pump will
        // wait for it to finish (see the env_msg_start gate above)
        // before popping the next entry.  Fades layer harmlessly so
        // we let them cascade in the same tick.
        if (fired_type == ENVHUD_EVENT_MESSAGE)
            break;
    }

    if (envhud_pending_count <= 0
        && envhud_pending_base_time > 0
        && cltime - envhud_pending_base_time > ENVHUD_DEFER_WINDOW)
    {
        envhud_pending_deferred = 0;
        envhud_pending_base_time = 0;
        envhud_pending_flush_time = 0;
    }
};

void(float s) EnvHud_DrawOneSlot =
{
    EnvHud_SlotLoad(s);
    if (env_msg_start <= 0 || env_msg_text == "")
        return;

    // Compute how far into the message's full timeline we are.  Only
    // expire the slot once the message has actually played through —
    // alpha == 0 at the very start of fade-in is NOT "done".  Without
    // this gate, the first frame after start (t=0, fadein > 0 ⇒
    // alpha = 0/fadein = 0) flagged the slot as expired before any
    // [envhud-draw] could fire, so credits with $effect 1 (and any
    // other effect with a non-zero fade-in) silently disappeared.
    // Typewriter ($effect 2) wasn't affected because its alpha path
    // returns 1 during the write+hold window, never bottoming to 0
    // until after fade-out.
    float t = cltime - env_msg_start;
    float total_life = env_msg_fadein + env_msg_hold + env_msg_fadeout;
    if (env_msg_effect == 2)
    {
        // Typewriter timeline = write_time + hold + fadeout, where
        // write_time scales with cl_envhud_speed.
        float typespeed = cvar("cl_envhud_speed");
        if (typespeed <= 0) typespeed = 1;
        typespeed = bound(0.05, typespeed, 10);
        float scaled_fadein = env_msg_fadein / typespeed;
        total_life = scaled_fadein * strlen(env_msg_text) + env_msg_hold + env_msg_fadeout;
    }
    if (t >= total_life)
    {
        env_msg_start = 0;
        EnvHud_SlotStore(s);   // persist the cleared start time
        return;
    }

    float alpha = EnvHud_MessageAlpha();
    if (alpha <= 0)
        return;     // mid-cycle dip (effect 1 RNG, fade boundaries) — keep alive

    string text = env_msg_text;
    vector col = env_msg_colour;
    if (env_msg_effect == 2)
    {
        // Match the scaling EnvHud_MessageAlpha applies so the
        // per-char reveal speed tracks cl_envhud_speed.  Only the
        // typewriter reveal uses the speed cvar — fadein/hold/fadeout
        // are taken straight from titles.txt so the message stays on
        // screen exactly as authored.
        float speed = cvar("cl_envhud_speed");
        if (speed <= 0) speed = 1;
        speed = bound(0.05, speed, 10);
        float reveal_fadein = env_msg_fadein / speed;

        float visible = strlen(text);
        if (reveal_fadein > 0)
            visible = floor((cltime - env_msg_start) / reveal_fadein);
        visible = bound(0, visible, strlen(text));
        text = substring(text, 0, visible);

        // HL's write-out effect uses color2 as the leading highlight.
        // A compact approximation: tint the whole reveal toward color2
        // while the text is still scanning out.
        if (visible < strlen(env_msg_text))
            col = env_msg_colour2;
    }
    else if (env_msg_effect == 1)
    {
        // HL's flicker effect blended toward colour2 on a per-frame
        // random gate (8% chance per frame).  That reads as strobing
        // at high refresh rates — swap to a smooth sin-driven mix so
        // the colour eases toward colour2 and back instead of
        // hard-snapping each frame.  Mix capped at 0.12 (down from
        // 0.4) so the shimmer is a subtle hint of colour2 rather
        // than a noticeable colour shift that reads as "the text
        // keeps changing colour mid-credit".
        float mix = (sin(cltime * 8) * 0.5 + 0.5) * 0.12;   // 0..0.12
        col = col + (env_msg_colour2 - col) * mix;
    }

    float prev_font = drawfont;
    drawfont = hud_font_mono;
    EnvHud_DrawMultiline(text, col, alpha);
    drawfont = prev_font;
};

void() CSQC_EnvHud_DrawMessages =
{
    // Render both message slots — the centered title (slot 0) and
    // the positioned credit (slot 1) display independently.
    float si;
    for (si = 0; si < ENVHUD_SLOTS; si = si + 1)
        EnvHud_DrawOneSlot(si);
};

void() CSQC_EnvHud_DrawFade =
{
    if (env_fade_start <= 0 || env_fade_duration <= 0 || env_fade_alpha <= 0)
        return;

    float t = cltime - env_fade_start;
    float a = 0;

    if (env_fade_flags & ENVFADE_FROM)
    {
        if (t < env_fade_hold)
            a = env_fade_alpha;
        else if (env_fade_duration > 0)
            a = env_fade_alpha * (1 - ((t - env_fade_hold) / env_fade_duration));
    }
    else
    {
        if (t < env_fade_duration)
            a = env_fade_alpha * (t / env_fade_duration);
        else if (t < env_fade_duration + env_fade_hold)
            a = env_fade_alpha;
        else
            a = 0;
    }

    a = bound(0, a, env_fade_alpha);
    if (a <= 0)
    {
        if (t > env_fade_hold + env_fade_duration)
            env_fade_start = 0;
        return;
    }

    float flags = (env_fade_flags & ENVFADE_MODULATE) ? ENVHUD_DRAWFLAG_MODULATE : 0;
    drawfill('0 0 0', [g_width, g_height, 0], env_fade_colour, a, flags);
};

void() CSQC_EnvHud_Draw =
{
    CSQC_EnvHud_PumpPending();
    CSQC_EnvHud_DrawMessages();
    CSQC_EnvHud_DrawFade();
};
