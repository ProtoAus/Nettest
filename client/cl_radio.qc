// =============================================
//  Radio quick-chat overlay
// =============================================
//
// CS-style 1-8 radio menu. Bound key (registered as the "radio" console
// command) toggles the overlay; while open, number keys 1-8 send the
// matching radio choice to the server and close the panel. Auto-closes
// after RADIO_AUTO_CLOSE_SECS of inactivity. Other input passes through
// so the player can keep aiming and moving while picking a command.
//
// Server entry point: void CSEv_radio_f(float choice) — see
// server/sv_radio.qc for the broadcast path.

const float RADIO_AUTO_CLOSE_SECS = 10;
const float RADIO_COMMAND_COUNT   = 8;

string radio_labels[RADIO_COMMAND_COUNT] = {
    "1. Affirmative",
    "2. Negative",
    "3. Over There!",
    "4. I Saw Someone",
    "5. Plant the bomb",
    "6. Defuse the bomb",
    "7. Thank you",
    "8. Fuck"
};

float radio_menu_open;       // 0 = closed, 1 = open
float radio_menu_open_time;  // cltime when opened, used for auto-close

// Client-side radio playback sequence.  Server sends a single
// CSQC_EVENT_RADIO_CALL with the resolved voice-line path; we play
// beep1 immediately and schedule the voice + beep2 at their offsets
// using soundlength().  Times are absolute cltime values; zero means
// "no stage pending".
string radio_seq_voice_path;
float  radio_seq_voice_at;
float  radio_seq_beep2_at;

#define RADIO_BEEP1_PATH "sounds/radio/beep1.ogg"
#define RADIO_BEEP2_PATH "sounds/radio/beep2.ogg"
#define RADIO_FALLBACK_DUR 1.5  // used if soundlength returns 0 (unrecognised codec)

// Forward declarations from the team menu module (m_teamselect.qc).
// We reuse its server-identity and main-menu gates so the radio panel
// disappears in exactly the same situations the team menu treats as
// "not gameplay".
float() TeamMenu_IsModServer;
float() TeamMenuIsOpen;
float() TeamMenuMainMenuOpen;

float() Radio_CanOpen =
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

void() Radio_Close =
{
    radio_menu_open = 0;
    radio_menu_open_time = 0;
};

void() Radio_Open =
{
    if (!Radio_CanOpen())
        return;
    radio_menu_open = 1;
    radio_menu_open_time = cltime;
};

void() Radio_Toggle =
{
    if (radio_menu_open)
        Radio_Close();
    else
        Radio_Open();
};

float() Radio_IsOpen =
{
    if (!radio_menu_open)
        return FALSE;
    // Gate revalidation each frame — if the player dies / opens main
    // menu / etc. while the panel is up, the next IsOpen query forces
    // a close so the input handler stops swallowing 1-8.
    if (!Radio_CanOpen())
    {
        Radio_Close();
        return FALSE;
    }
    if (cltime - radio_menu_open_time > RADIO_AUTO_CLOSE_SECS)
    {
        Radio_Close();
        return FALSE;
    }
    return TRUE;
};

void(float choice) Radio_Send =
{
    if (choice < 1 || choice > RADIO_COMMAND_COUNT)
        return;
    // sendevent("radio", "f", choice) dispatches to CSEv_radio_f on
    // the server. Builtin #359; see ftedefs/csqcsysdefs.qc.
    sendevent("radio", "f", choice);
    Radio_Close();
};

// Input handler — only consumes scan codes we actively want, so
// movement and weapon fire keep working while the panel is up.
// Returns TRUE iff the event was consumed.
float(float evtype, float scanx, float chary, float devid) Radio_InputEvent =
{
    if (evtype != IE_KEYDOWN)
        return FALSE;

    // ESC always closes.
    if (scanx == K_ESCAPE)
    {
        Radio_Close();
        return TRUE;
    }

    // Re-pressing the bound radio key closes the panel. Looking the
    // bind up by scan code means we follow whatever the user picked
    // in the settings menu without needing to track it here.
    if (getkeybind(scanx) == "radio")
    {
        Radio_Close();
        return TRUE;
    }

    // Number keys '1'..'8' = scan codes 49..56. Each picks a radio
    // choice and closes the panel.
    if (scanx >= '1' && scanx <= '8')
    {
        Radio_Send(scanx - '0');
        return TRUE;
    }

    return FALSE;
};

// Draw the panel — left side, vertically centred. Uses GoogleMed 12
// (loaded as hud_font_mono in CSQC_Init). Caller is responsible for
// saving / restoring drawfont if it cares.
void() Radio_Draw =
{
    if (!Radio_IsOpen())
        return;

    float prev_font = drawfont;
    drawfont = hud_font_mono;

    float line_h    = 14;        // 12 px glyphs + 2 px breathing room
    float padding_x = 10;
    float padding_y = 8;
    float title_h   = 18;
    float panel_w   = 220;
    float panel_h   = title_h + line_h * RADIO_COMMAND_COUNT + padding_y * 2;

    vector pos;
    pos_x = 12;
    pos_y = g_height * 0.5 - panel_h * 0.5;
    pos_z = 0;

    vector title_pos;
    title_pos_x = pos_x + padding_x;
    title_pos_y = pos_y + padding_y;
    title_pos_z = 0;
    drawstring(title_pos + '1 1 0', "RADIO", [12, 12], '0 0 0', 0.6, 0);
    drawstring(title_pos, "RADIO", [12, 12], '0.9 0.9 0.4', 1.0, 0);

    vector text_pos;
    text_pos_x = pos_x + padding_x;
    text_pos_y = pos_y + padding_y + title_h;
    text_pos_z = 0;

    float i;
    for (i = 0; i < RADIO_COMMAND_COUNT; i = i + 1)
    {
        drawstring(text_pos + '1 1 0', radio_labels[i], [12, 12], '0 0 0', 0.6, 0);
        drawstring(text_pos, radio_labels[i], [12, 12], '1 1 1', 0.95, 0);
        text_pos_y = text_pos_y + line_h;
    }

    drawfont = prev_font;
};

// --- playback sequence ---

// Returns soundlength(path), or RADIO_FALLBACK_DUR if the engine
// can't read it (file not loaded, codec unsupported, etc.).
float(string path) Radio_Duration =
{
    float dur = soundlength(path);
    if (dur > 0) return dur;
    return RADIO_FALLBACK_DUR;
};

// Start playback: beep1 now, voice after beep1, beep2 after voice.
// Called from CSQC_EVENT_RADIO_CALL parse with the resolved voice
// path. Overwrites any in-flight sequence — second radio call within
// the first's duration restarts cleanly with the new line.
void(string voice_path) Radio_StartSequence =
{
    if (voice_path == "")
        return;

    // Play beep1 immediately.  CHAN_AUTO so it can mix with whatever
    // else is on the local sound channels (and so two near-simultaneous
    // radio calls don't fight over a single channel).
    localsound(RADIO_BEEP1_PATH, CHAN_AUTO, 1);

    float beep1_dur = Radio_Duration(RADIO_BEEP1_PATH);
    float voice_dur = Radio_Duration(voice_path);

    radio_seq_voice_path = voice_path;
    radio_seq_voice_at   = cltime + beep1_dur;
    radio_seq_beep2_at   = cltime + beep1_dur + voice_dur;
};

// Drives the sequence forward.  Called every frame from
// CSQC_UpdateView; cheap when nothing is pending.
void() Radio_TickSequence =
{
    if (radio_seq_voice_at > 0 && cltime >= radio_seq_voice_at)
    {
        if (radio_seq_voice_path != "")
            localsound(radio_seq_voice_path, CHAN_AUTO, 1);
        radio_seq_voice_at = 0;
    }
    if (radio_seq_beep2_at > 0 && cltime >= radio_seq_beep2_at)
    {
        localsound(RADIO_BEEP2_PATH, CHAN_AUTO, 1);
        radio_seq_beep2_at = 0;
    }
};
