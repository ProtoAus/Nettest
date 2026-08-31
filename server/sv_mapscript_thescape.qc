// ===========================================================================
//  sv_mapscript_thescape.qc — native stand-ins for th_escape's AngelScript
// ===========================================================================
//
//  th_escape's map cfg says `map_script th_escape/th_escape`, and the map
//  places 17 trigger_script entities.  Every one of them calls a function in
//  that script, and until now every one of them fell through
//  MapScript_Call's "no native stand-in, forwarding chain only" arm — which
//  for this map means: no character assignment, no equipment, no escape timer,
//  no objective feedback, no engine ignition, no controls release and no
//  ending.  The map was unfinishable and most of it never started.
//
//  This file is the port.  It covers all 17, by name:
//
//      SetCharacters        EquipCharacters      StartCharacters
//      TargetItemBattery    TargetItemGasCan     TargetItemToolbox
//      AllItemsDroppedOff   ReadGameCounter
//      VehicleIgnitionOn    VehicleStarted
//      NormalDifficulty     NightmareDifficulty
//      AbortGame            EndGame              GameOutro
//      ShowSurvivors        ShowLosers
//
//  SOURCES, all read rather than inferred:
//      scripts/maps/th_escape/th_escape.as        (620 lines — the entry points)
//      scripts/maps/th_escape/PlayerCharacters.as (255 — the 16-row roster)
//      scripts/maps/th_escape/CustomHUD.as        (386 — timer + objective HUD)
//      scripts/maps/RandNumMath.as                (109 — the random event maths)
//
//  ---------------------------------------------------------------------------
//  WHAT IS NOT PORTED, AND WHY
//  ---------------------------------------------------------------------------
//  * RndBreakables (19.7 KB) — randomises what falls out of named breakables.
//    It is driven from MapInit/MapStart and is NOT one of the 17 trigger_script
//    functions, so it is outside what this file is for.  StartCharacters' one
//    call into it (`RndBreakables::SetMode(difficulty)`) is a no-op here.
//  * LowHealthFX / DrunkFX — screen effects. The drunk characters' 120-second
//    ConcussionEffect has no equivalent in this tree; the two drunks still get
//    their grenade, they just do not stagger.
//  * VehicleCustom (func_vehicle_jp, 36.7 KB) — the tutorial vehicle used
//    before the truck.  StartCharacters swaps Sven's PlayerUse hooks from it to
//    the trackvehicle; here both classes are always driveable by their own
//    code, so the swap has nothing to do.
//  * The three objective SPRITES (sprites/th_escape/item_*_48_{on,off}.spr).
//    Sven draws them as HUD sprite channels; this tree has no HUD-sprite wire
//    format, so the same information goes out as a game_text objective list on
//    its own channel.  See THEsc_SendObjectives.
//
//  ---------------------------------------------------------------------------
//  PLAYER TARGETNAME IS LOAD-BEARING — DO NOT "TIDY" IT
//  ---------------------------------------------------------------------------
//  PlayerCharacters::Set writes the chosen character's name into
//  pPlayer.pev.targetname, and SortPlayers later overwrites it with "winnars",
//  "lastliving" or "ghostboyes".  That is not a scratch variable: th_escape's
//  entity lump addresses players by those names in five different ways —
//
//      trigger_respawn      target "winnars" / "ghostboyes" / "lastliving"
//      info_player_deathmatch  message "winnars"   (a group-restricted spawn)
//      trigger_entity_iterator name_filter "ghostboyes"
//      trigger_changevalue     target "ghostboyes"
//      trigger_renameplayer    netname "lastliving"
//
//  — so the ending only works if the player's real .targetname carries it.  A
//  parallel field would look tidier and would break every one of those.
//
//  The character INDEX is cached separately in .thesc_char (index + 1, 0 for
//  "not playing") precisely because targetname stops naming a character once
//  the sort runs.  Sven has the same problem and simply loses the character at
//  that point; keeping the index means the deferred effect-wear-off and the
//  debug listing still know who was who.
//

// Three forward declarations, all to files that compile AFTER this one.  QC
// forward-declares functions but not fields or constants, and none of these
// three needs either — which is the whole reason this port could sit at
// position 376 instead of being dragged to the bottom of the compile list.
//
//   SV_ApplyConfigFile     sv_main.qc             (454)  — the _skl.cfg load
//   GoldSrc_GiveNamedItem  sv_goldsrc_entities.qc (378)  — character equipment
//   PlayerApplyModel       sv_player.qc           (440)  — character models
void(string cfgpath, float ismapcfg) SV_ApplyConfigFile;
float(entity plyr, string cls, float qty) GoldSrc_GiveNamedItem;
void() PlayerApplyModel;

// ---------------------------------------------------------------------------
//  State
// ---------------------------------------------------------------------------
const float THESC_STATE_NEW      = 0;
const float THESC_STATE_RUNNING  = 1;
const float THESC_STATE_FINISHED = 2;
const float THESC_STATE_FAILED   = 3;

const float THESC_DIFF_NORMAL    = 0;
const float THESC_DIFF_NIGHTMARE = 1;

float thesc_state;
float thesc_difficulty;

// CustomHUD's timer.  g_flStartTime + g_iTimeLimit collapse into one deadline.
float  thesc_timer_active;
float  thesc_timer_deadline;      // `time` at which the limit expires
string thesc_timer_target;        // strzone'd; fired at 0
float  thesc_timer_target_zoned;
float  thesc_warn_secs;           // seconds LEFT at which the warning fires
string thesc_warn_target;         // strzone'd
float  thesc_warn_target_zoned;
float  thesc_warn_fired;
float  thesc_timer_last_shown;    // last whole second pushed to the HUD

// CustomHUD's three status indicators.
const float THESC_ITEM_BATTERY = 0;
const float THESC_ITEM_GASCAN  = 1;
const float THESC_ITEM_TOOLBOX = 2;
const float THESC_ITEM_COUNT   = 3;

float thesc_item_status[3];
float thesc_status_shown;

// InitRandomEvents / ReadGameCounter.
const float THESC_EVT_MAX = 8;
float thesc_evt_pct[8];
float thesc_evt_id[8];
float thesc_evt_count;
float thesc_evt_next;

// PlayerCharacters: which roster rows are already handed out this map.
const float THESC_CHAR_COUNT = 16;
float thesc_char_taken[16];

// The three ending buckets, counted at TheEnd.
float thesc_n_winnars;
float thesc_n_lastliving;
float thesc_n_ghosts;

// Deferred EffectWearOff (PlayerCharacters::Equip schedules it 120 s out).
float thesc_effect_wearoff_at;

// The scratch entity every game_text send borrows.  One per map, made on
// demand; GameText_SendOne reads its styling off `self`, so there has to be an
// entity even though nothing in the map owns it.
entity thesc_hud_ent;

// Per-player.  .targetname carries the GROUP name (see the header); this is the
// roster index + 1, so 0 still means "not playing".
.float thesc_char;

// ---------------------------------------------------------------------------
//  The roster.  PlayerCharacters.as:19-51, transcribed row for row.
//
//  Written as five parallel accessors rather than one table because QC has no
//  array of strings — the same shape FuncTrackTrain_Sound uses for its enum.
//
//    type: p primary, s secondary, d default (used once both pools are dry)
//    effect: "d" = drunk FX (not implemented here, see the header)
// ---------------------------------------------------------------------------
string(float i) THEsc_CharType =
{
    if (i == 0) return "d";
    if (i <= 10) return "p";
    return "s";
};

string(float i) THEsc_CharName =
{
    if (i ==  0) return "player_civilian";
    if (i ==  1) return "player_asylum";
    if (i ==  2) return "player_priest";
    if (i ==  3) return "player_gangster";
    if (i ==  4) return "player_deputy";
    if (i ==  5) return "player_drunk";
    if (i ==  6) return "player_nurse";
    if (i ==  7) return "player_mechanic";
    if (i ==  8) return "player_radio";
    if (i ==  9) return "player_sewer";
    if (i == 10) return "player_conductor";
    if (i == 11) return "player_orderly";
    if (i == 12) return "player_deputy2";
    if (i == 13) return "player_drunk2";
    if (i == 14) return "player_sewer2";
    if (i == 15) return "player_sewer3";
    return "";
};

// Empty on the default row: GetCharacterModel picks one of g_DefaultModels at
// random instead (PlayerCharacters.as:61-70).
string(float i) THEsc_CharModelName =
{
    if (i ==  0) return "";
    if (i ==  1) return "th_patient";
    if (i ==  2) return "th_paul";
    if (i ==  3) return "th_gangster";
    if (i ==  4) return "th_nypdcop";
    if (i ==  5) return "th_neil";
    if (i ==  6) return "th_nurse";
    if (i ==  7) return "th_worker";
    if (i ==  8) return "th_host";
    if (i ==  9) return "th_cl_suit";
    if (i == 10) return "th_dave";
    if (i == 11) return "th_orderly";
    if (i == 12) return "th_jack";
    if (i == 13) return "th_einar";
    if (i == 14) return "th_cl_suit";
    if (i == 15) return "th_cl_suit";
    return "";
};

string(float i) THEsc_CharMessage =
{
    if (i ==  0) return "You are a random civilian.";
    if (i ==  1) return "You are the Asylum Patient.";
    if (i ==  2) return "You are the Priest.";
    if (i ==  3) return "You are Big Paul.";
    if (i ==  4) return "You are a Police Officer.";
    if (i ==  5) return "You are a Drunk.";
    if (i ==  6) return "You are a Paramedic.";
    if (i ==  7) return "You are the Mechanic.";
    if (i ==  8) return "You are the Radio Host.";
    if (i ==  9) return "You are a Water Treatment Engineer.";
    if (i == 10) return "You are the Railroad Engineer.";
    if (i == 11) return "You are a Paramedic.";
    if (i == 12) return "You are a Police Officer.";
    if (i == 13) return "You are a Drunk.";
    if (i == 14) return "You are a Water Treatment Engineer.";
    if (i == 15) return "You are a Water Treatment Engineer.";
    return "";
};

// Semicolon-separated classnames, handed to GoldSrc_GiveNamedItem one at a
// time.  weapon_spanner is a They Hunger custom weapon with no equivalent in
// this tree; the give reports and moves on, which is the correct outcome and is
// why the whole list is not gated on it.
string(float i) THEsc_CharEquip =
{
    if (i ==  4) return "weapon_colt1911;ammo_9mmclip";
    if (i ==  5) return "weapon_handgrenade";
    if (i ==  6) return "weapon_medkit";
    if (i ==  7) return "weapon_spanner";
    if (i == 10) return "weapon_spanner";
    if (i == 11) return "weapon_medkit";
    if (i == 12) return "weapon_357;ammo_357";
    if (i == 13) return "weapon_handgrenade";
    if (i == 15) return "weapon_spanner";
    return "";
};

// g_DefaultModels — the three faces a "random civilian" can wear.
string(float k) THEsc_DefaultModelName =
{
    if (k <= 0) return "th_civpaul";
    if (k == 1) return "th_einstein";
    return "th_slick";
};

string(string nm) THEsc_ModelPath =
{
    if (nm == "" || nm == __NULL__) return "";
    return sprintf("models/player/%s/%s.mdl", nm, nm);
};

// ---------------------------------------------------------------------------
//  HUD plumbing.
//
//  CustomHUD::Message is a HUDTextParams send, i.e. exactly what
//  CSQC_EVENT_GAME_TEXT already carries.  GameText_SendOne / _SendAll read the
//  styling off `self`, so a scratch entity stands in for the game_text the map
//  does not have.
//
//  The message string is strzone'd around the send: sprintf returns a temp that
//  the string heap can recycle, and it has to survive into WriteString.
// ---------------------------------------------------------------------------
entity() THEsc_HudEnt =
{
    if (thesc_hud_ent && !wasfreed(thesc_hud_ent))
        return thesc_hud_ent;

    thesc_hud_ent = spawn();
    thesc_hud_ent.classname  = "thesc_hud";
    thesc_hud_ent.movetype   = MOVETYPE_NONE;
    thesc_hud_ent.solid      = SOLID_NOT;
    setorigin(thesc_hud_ent, '0 0 0');
    return thesc_hud_ent;
};

// One-shot fade suppressor.  Set it immediately before a THEsc_Hud call and that
// ONE send goes out with fadein/fadeout 0; THEsc_Hud clears it again so nothing
// downstream can inherit it.
//
// This exists for the escape clock.  That block is re-sent once per second with a
// new string, and every send restarts the 0.1 s fade-in, so the countdown read as
// a number that flashed on every tick — reported as "the number fades out or in?
// every second, it looks like it 'flashes'".  A fade is right for a message that
// appears once; it is wrong for a field that is being continuously updated in
// place, which is what a clock is.  Sven's CustomHUD has the same split: its
// countdown is a HUD element it redraws, not a HUDTextParams message it re-sends.
//
// A global rather than two more parameters because THEsc_Hud is already at seven
// and QC's fixed arity gives no cheap way to add optional ones.
float thesc_hud_nofade;

// `to` == world means everybody.
void(entity to, float chan, float x, float y, vector col, float hold, string txt) THEsc_Hud =
{
    entity h = THEsc_HudEnt();

    h.channel   = chan;
    h.gt_x      = x;
    h.gt_y      = y;
    h.gt_effect = 0;
    h.color     = col;
    h.color2    = col;
    h.fadein    = 0.1;
    h.fadeout   = 0.3;
    if (thesc_hud_nofade)
    {
        h.fadein  = 0;
        h.fadeout = 0;
    }
    thesc_hud_nofade = FALSE;
    h.holdtime  = hold;
    h.fxtime    = 0.25;
    h.message   = strzone(txt);

    entity oldself = self;
    self = h;
    if (to == world) GameText_SendAll();
    else             GameText_SendOne(to);
    self = oldself;

    strunzone(h.message);
    h.message = "";
};

// CustomHUD::Message — the red centre-screen character/ending text.
void(entity to, string txt) THEsc_Message =
{
    THEsc_Hud(to, 1, -1, 0.65, '255 0 0', 5, txt);
};

// ---------------------------------------------------------------------------
//  Objective indicators.  Sven's three sprites collapse into one text block,
//  see the header.  Channel 3, left edge, held long enough to span the gap
//  between refreshes and re-sent whenever one flips.
// ---------------------------------------------------------------------------
string(float idx) THEsc_ItemLabel =
{
    if (idx == THESC_ITEM_BATTERY) return "BATTERY";
    if (idx == THESC_ITEM_GASCAN)  return "GAS CAN";
    return "TOOLBOX";
};

void(entity to) THEsc_SendObjectives =
{
    if (!thesc_status_shown)
        return;

    string s = "";
    float i;
    for (i = 0; i < THESC_ITEM_COUNT; i = i + 1)
    {
        s = strcat(s, thesc_item_status[i] ? "[x] " : "[ ] ",
                   THEsc_ItemLabel(i), "\n");
    }

    // holdtime 0 would expire the block; it is refreshed only on change, so it
    // has to outlive the whole repair phase.  600 s covers the 9-minute cap.
    THEsc_Hud(to, 3, 0.02, 0.35, '255 176 0', 600, s);
};

void(float idx, float on) THEsc_SetItemStatus =
{
    if (idx < 0 || idx >= THESC_ITEM_COUNT)
        return;
    if (thesc_item_status[idx] == on)
        return;

    thesc_item_status[idx] = on;
    THEsc_SendObjectives(world);
};

void(float visible) THEsc_ToggleStatus =
{
    if (thesc_status_shown == visible)
        return;

    thesc_status_shown = visible;

    if (visible)
    {
        THEsc_SendObjectives(world);
        return;
    }

    // Clearing a channel is a zero-holdtime empty message — the client's slot
    // expires immediately.  There is no "hide element" opcode on this wire.
    THEsc_Hud(world, 3, 0.02, 0.35, '255 176 0', 0.1, " ");
};

// ---------------------------------------------------------------------------
//  The escape timer.
//
//  This is the piece the map cannot do without.  StartCharacters arms it with a
//  target of `timesup_mm` — the multi_manager that blows the truck's engine,
//  dumps headcrabs and prints the fail text — and a 60-second warning target of
//  `lastmin_mm_relay`.  Neither is reachable from any trigger in the entity
//  lump; the script is the ONLY thing that fires them.
// ---------------------------------------------------------------------------
void() THEsc_ClearTimerStrings =
{
    if (thesc_timer_target_zoned)
    {
        strunzone(thesc_timer_target);
        thesc_timer_target_zoned = FALSE;
    }
    thesc_timer_target = "";

    if (thesc_warn_target_zoned)
    {
        strunzone(thesc_warn_target);
        thesc_warn_target_zoned = FALSE;
    }
    thesc_warn_target = "";
};

void(float secs, string tgt) THEsc_SetTimerTarget =
{
    if (thesc_timer_target_zoned)
    {
        strunzone(thesc_timer_target);
        thesc_timer_target_zoned = FALSE;
    }
    thesc_timer_target       = strzone(tgt);
    thesc_timer_target_zoned = TRUE;
    thesc_timer_deadline     = time + secs;
};

void(float secs_left, string tgt) THEsc_SetWarningTarget =
{
    if (secs_left <= 0 || tgt == "")
        return;

    if (thesc_warn_target_zoned)
    {
        strunzone(thesc_warn_target);
        thesc_warn_target_zoned = FALSE;
    }
    thesc_warn_secs         = secs_left;
    thesc_warn_target       = strzone(tgt);
    thesc_warn_target_zoned = TRUE;
    thesc_warn_fired        = FALSE;
};

string(float secs) THEsc_ClockText =
{
    if (secs < 0) secs = 0;
    float m = floor(secs / 60);
    float s = secs - m * 60;
    if (s < 10)
        return sprintf("%g:0%g", m, s);
    return sprintf("%g:%g", m, s);
};

void(entity to, float secs) THEsc_SendClock =
{
    vector col = (secs <= thesc_warn_secs) ? '255 48 48' : '160 255 96';
    // holdtime 1.4 rather than 1.0: the refresh is on a 0.1 s poll and a
    // holdtime equal to the period leaves a visible flicker at the seam.
    //
    // No fade — see thesc_hud_nofade.  The seam is already covered by the extra
    // 0.4 s of holdtime, so a hard cut between one second's text and the next is
    // invisible, whereas the fade-in was visible every single tick.
    thesc_hud_nofade = TRUE;
    THEsc_Hud(to, 4, -1, 0.06, col, 1.4, THEsc_ClockText(secs));
};

void(float visible) THEsc_ToggleTimer =
{
    if (thesc_timer_active == visible)
        return;

    thesc_timer_active = visible;

    if (visible)
    {
        thesc_timer_last_shown = -1;
        return;
    }

    THEsc_Hud(world, 4, -1, 0.06, '160 255 96', 0.1, " ");
};

// Driven from THEsc_Frame below, at 10 Hz.  CustomHUD::Update is on the same
// cadence (g_Scheduler.SetInterval("Update", 0.1, REPEAT_INFINITE_TIMES)).
void() THEsc_TimerTick =
{
    if (!thesc_timer_active)
        return;

    float left = floor(thesc_timer_deadline - time);
    if (left < -1) left = -1;

    if (left == thesc_timer_last_shown)
        return;
    thesc_timer_last_shown = left;

    if (!thesc_warn_fired && thesc_warn_secs > 0 && left <= thesc_warn_secs && left > 0)
    {
        thesc_warn_fired = TRUE;
        print(sprintf("[mapscript] th_escape: %g seconds left — firing \"%s\"\n",
                      left, thesc_warn_target));
        SV_FireTargetsByName(thesc_warn_target, world, USE_ON);
    }

    if (left > 0)
    {
        THEsc_SendClock(world, left);
        return;
    }

    if (left == 0)
    {
        THEsc_SendClock(world, 0);
        print(sprintf("[mapscript] th_escape: out of time — firing \"%s\"\n",
                      thesc_timer_target));
        SV_FireTargetsByName(thesc_timer_target, world, USE_ON);
        return;
    }

    // left == -1: hide, one second after zero, exactly as CustomHUD does.
    THEsc_ToggleTimer(FALSE);
};

// ---------------------------------------------------------------------------
//  RandNumMath — the repair-phase ambush schedule.
//
//  th_escape's repair button drives a game_counter (`veh1_repaircount`) from 0
//  to 100.  Each press fires ReadGameCounter, which fires the next entry of a
//  pseudo-random, monotonically increasing schedule of between 3 and 6 events
//  drawn from the six targets below.  So no two playthroughs get their
//  interruptions at the same percentages, or in the same order.
//
//  IncreasingSequence and ShuffledSequence are ported term for term from
//  RandNumMath.as, including the fact that its iMinEventDist argument is
//  subtracted from the first interval and then never used again — the "minimum
//  distance between two terms" it documents is not actually enforced.  Left as
//  written; it only changes how clumped the events can be.
// ---------------------------------------------------------------------------
const float THESC_REPAIR_MIN      = 3;
const float THESC_REPAIR_MAX      = 97;
const float THESC_EVENTS_MIN      = 3;
const float THESC_EVENTS_MAX      = 6;
const float THESC_MIN_EVENT_DIST  = 4;
const float THESC_MAX_EVENT_DEV   = 0.85;

string(float i) THEsc_EventTarget =
{
    if (i == 0) return "priest_windowcop";
    if (i == 1) return "zspawn_conndr_mm";
    if (i == 2) return "attic_windowcop1";
    if (i == 3) return "attic_windowcop2";
    if (i == 4) return "skychickens";
    return "hotel_door_mm";
};
const float THESC_EVENT_TARGETS = 6;

float(float lo, float hi) THEsc_RandFloat =
{
    return lo + (hi - lo) * random();
};

float(float lo, float hi) THEsc_RandLong =
{
    if (hi <= lo) return lo;
    return lo + floor(random() * (hi - lo + 1) * 0.999999);
};

void() THEsc_InitRandomEvents =
{
    float n = THEsc_RandLong(THESC_EVENTS_MIN, THESC_EVENTS_MAX);
    if (n > THESC_EVENT_TARGETS) n = THESC_EVENT_TARGETS;
    if (n > THESC_EVT_MAX)       n = THESC_EVT_MAX;

    thesc_evt_count = n;
    thesc_evt_next  = 0;

    // --- IncreasingSequence ------------------------------------------------
    float total_dist = THESC_MIN_EVENT_DIST * (n - 1);
    float half_dev   = THESC_MAX_EVENT_DEV * 0.5;
    float ints_left  = n;
    float int_min    = THESC_REPAIR_MIN;
    float int_max    = int_min - total_dist;

    float i;
    for (i = 0; i < n; i = i + 1)
    {
        float range_left = THESC_REPAIR_MAX - int_max;
        float avg_range  = range_left / ints_left;

        if (ints_left > 1)
            int_max = int_min + avg_range * (1 + THEsc_RandFloat(0 - half_dev, half_dev));
        else
            int_max = THESC_REPAIR_MAX;

        thesc_evt_pct[i] = floor(THEsc_RandFloat(int_min, int_max));
        int_min   = int_max;
        ints_left = ints_left - 1;
    }

    // --- ShuffledSequence (Fisher-Yates, as written) -----------------------
    for (i = 0; i < n; i = i + 1)
        thesc_evt_id[i] = i;

    if (n > 1)
    {
        for (i = 0; i < n - 1; i = i + 1)
        {
            float j = i + THEsc_RandLong(0, (n - i) - 1);
            float t = thesc_evt_id[j];
            thesc_evt_id[j] = thesc_evt_id[i];
            thesc_evt_id[i] = t;
        }
    }

    if (cvar("sv_debug_use"))
    {
        for (i = 0; i < n; i = i + 1)
            dprint(sprintf("[mapscript] th_escape event %g at %g%% -> \"%s\"\n",
                           i, thesc_evt_pct[i], THEsc_EventTarget(thesc_evt_id[i])));
    }
};

// ---------------------------------------------------------------------------
//  Characters
// ---------------------------------------------------------------------------
float() THEsc_NumActivePlayers =
{
    float n = 0;
    entity p = player_chain_head;
    while (p)
    {
        if (p.thesc_char > 0) n = n + 1;
        p = p.player_chain_next;
    }
    return n;
};

// Pick a random untaken roster row of the given type, or -1.  Two passes rather
// than a temporary array, because QC has no local arrays: count the candidates,
// choose k, then walk to the k-th.
float(string want_type) THEsc_PickChar =
{
    float i;
    float navail = 0;
    for (i = 0; i < THESC_CHAR_COUNT; i = i + 1)
        if (!thesc_char_taken[i] && THEsc_CharType(i) == want_type)
            navail = navail + 1;

    if (navail <= 0)
        return -1;

    float k = THEsc_RandLong(0, navail - 1);
    for (i = 0; i < THESC_CHAR_COUNT; i = i + 1)
    {
        if (thesc_char_taken[i] || THEsc_CharType(i) != want_type)
            continue;
        if (k <= 0)
            return i;
        k = k - 1;
    }
    return -1;
};

// PlayerCharacters::Set — primaries first, then secondaries, then everybody
// left over becomes the default civilian (which is NOT marked taken, because
// any number of players can be it).
void() THEsc_SetCharacters =
{
    float i;
    for (i = 0; i < THESC_CHAR_COUNT; i = i + 1)
        thesc_char_taken[i] = FALSE;

    // Anything already assigned this map keeps its row.
    entity p = player_chain_head;
    while (p)
    {
        if (p.thesc_char > 0)
            thesc_char_taken[p.thesc_char - 1] = TRUE;
        p = p.player_chain_next;
    }

    p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.thesc_char <= 0)
        {
            float idx = THEsc_PickChar("p");
            if (idx < 0) idx = THEsc_PickChar("s");
            if (idx < 0) idx = 0;                 // the default row
            else         thesc_char_taken[idx] = TRUE;

            p.thesc_char = idx + 1;
            p.targetname = THEsc_CharName(idx);   // load-bearing, see the header

            if (cvar("sv_debug_use"))
                dprint(sprintf("[mapscript] th_escape: %s -> %s\n",
                               p.netname, p.targetname));
        }
        p = nxt;
    }
};

// PlayerCharacters::Start — model, full health, and the "you are the ..." line.
void() THEsc_StartCharacterModels =
{
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.thesc_char > 0)
        {
            float idx = p.thesc_char - 1;

            string nm = THEsc_CharModelName(idx);
            if (nm == "")
                nm = THEsc_DefaultModelName(THEsc_RandLong(0, 2));

            string path = THEsc_ModelPath(nm);
            if (path != "")
            {
                // Runtime precache.  The roster is only known once the map's
                // own chain has called SetCharacters, which is well after
                // spawn — the same late-precache shape sh_modellist.qc's
                // Modellist_PrecacheTargets uses, and the reason the models
                // are not precached in bulk at map load is that a map naming a
                // different script must not pay for sixteen of them.
                precache_model(path);
                p.player_model_override = path;
                entity oldself = self;
                self = p;
                PlayerApplyModel();
                self = oldself;

                // Reported unconditionally, not under a debug cvar.  The
                // th_* models come from the Sven mount rather than this tree,
                // so "did the character model actually resolve" is the one
                // thing about this port that a log has to be able to answer —
                // and a headless run cannot answer it by looking.
                print(sprintf("[mapscript] th_escape: %s is %s (%s), model %s\n",
                              p.netname, THEsc_CharName(idx), THEsc_CharType(idx), path));
            }

            p.health = 100;

            string msg = THEsc_CharMessage(idx);
            if (msg != "")
                THEsc_Message(p, msg);
        }
        p = nxt;
    }
};

// Semicolon splitter.  Hand-rolled rather than tokenizebyseparator because that
// builtin writes GLOBAL tokeniser state and GoldSrc_GiveByClassname's callees
// are free to tokenise — a nested call would corrupt this walk mid-loop.
void(entity plyr, string list) THEsc_GiveList =
{
    if (list == "" || list == __NULL__)
        return;

    string rest = list;
    while (rest != "")
    {
        float cut = strstrofs(rest, ";");
        string one;
        if (cut < 0)
        {
            one  = rest;
            rest = "";
        }
        else
        {
            one  = substring(rest, 0, cut);
            rest = substring(rest, cut + 1, -1);
        }

        if (one != "")
        {
            // GoldSrc_GiveNamedItem needs `self` to be the player —
            // W_GiveWeaponToSlot operates on self rather than an argument.
            entity oldself = self;
            self = plyr;
            float ok = GoldSrc_GiveNamedItem(plyr, one, 1);
            self = oldself;

            if (!ok)
                print(sprintf("[mapscript] th_escape: no equivalent for \"%s\"\n", one));
        }
    }
};

void() THEsc_EquipCharacters =
{
    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.thesc_char > 0)
            THEsc_GiveList(p, THEsc_CharEquip(p.thesc_char - 1));
        p = nxt;
    }

    // g_Scheduler.SetTimeout( "EffectWearOff", 120 ).  The effect it would undo
    // is the drunk concussion, which is not implemented — the timestamp is kept
    // so the hook has somewhere to live if it ever is, and so the debug listing
    // can show it.
    thesc_effect_wearoff_at = time + 120;
};

// ---------------------------------------------------------------------------
//  Endings.  SortPlayers + TriggerEnding, th_escape.as:465-550.
// ---------------------------------------------------------------------------
const string THESC_VOLUME_ENTITY = "detectendplayers";

float(vector org, entity vol) THEsc_PointInVolume =
{
    if (vol == world) return FALSE;
    return (org_x >= vol.absmin_x && org_x <= vol.absmax_x
         && org_y >= vol.absmin_y && org_y <= vol.absmax_y
         && org_z >= vol.absmin_z && org_z <= vol.absmax_z);
};

void() THEsc_SortPlayers =
{
    entity vol = find(world, targetname, THESC_VOLUME_ENTITY);
    if (vol == world)
        print(sprintf("[mapscript] th_escape: volume entity \"%s\" not found\n",
                      THESC_VOLUME_ENTITY));

    thesc_n_winnars    = 0;
    thesc_n_lastliving = 0;
    thesc_n_ghosts     = 0;

    entity p = player_chain_head;
    while (p)
    {
        entity nxt = p.player_chain_next;
        if (p.thesc_char > 0)
        {
            if (p.health > 0)
            {
                if (THEsc_PointInVolume(p.origin, vol))
                {
                    thesc_n_winnars = thesc_n_winnars + 1;
                    p.targetname    = "winnars";
                }
                else
                {
                    thesc_n_lastliving = thesc_n_lastliving + 1;
                    p.targetname       = "lastliving";
                }
            }
            else
            {
                thesc_n_ghosts = thesc_n_ghosts + 1;
                p.targetname   = "ghostboyes";
            }
        }
        p = nxt;
    }

    print(sprintf("[mapscript] th_escape: sorted %g winnars / %g lastliving / %g ghosts\n",
                  thesc_n_winnars, thesc_n_lastliving, thesc_n_ghosts));
};

void() THEsc_TriggerEnding =
{
    string tgt;

    if (thesc_n_winnars > 0)
    {
        if (thesc_n_lastliving > 0)   tgt = "end_mixed1_mm";
        else if (thesc_n_ghosts > 0)  tgt = "end_mixed2_mm";
        else                          tgt = "end_best_mm";
    }
    else
    {
        if (thesc_n_lastliving > 0)   tgt = "end_jail_mm";
        else                          tgt = "everyonedied_rel";
    }

    print(sprintf("[mapscript] th_escape: ending \"%s\"\n", tgt));
    SV_FireTargetsByName(tgt, world, USE_TOGGLE);
};

void() THEsc_TheEnd =
{
    THEsc_ToggleTimer(FALSE);
    THEsc_ToggleStatus(FALSE);
    THEsc_SortPlayers();
    THEsc_TriggerEnding();
};

// CheckEndConditions — every living player dead means the run failed.  Called
// from the death and disconnect paths, which is where the AngelScript hooks it
// (Hooks::Player::PlayerKilled and ::ClientDisconnect).
void() THEsc_CheckEndConditions =
{
    if (thesc_state != THESC_STATE_RUNNING)
        return;

    entity p = player_chain_head;
    while (p)
    {
        if (p.health > 0)
            return;
        p = p.player_chain_next;
    }

    thesc_state = THESC_STATE_FAILED;
    print("[mapscript] th_escape: everybody died\n");
    THEsc_TheEnd();
};

// ---------------------------------------------------------------------------
//  The 17 entry points.
// ---------------------------------------------------------------------------
void() THEsc_StartCharacters =
{
    THEsc_StartCharacterModels();

    float nplayers = THEsc_NumActivePlayers();

    // Nightmare is a minute meaner; a small squad gets a minute back.
    float minutes = (thesc_difficulty == THESC_DIFF_NIGHTMARE) ? 7 : 8;
    if (nplayers <= 4)
        minutes = minutes + 1;

    THEsc_SetTimerTarget(minutes * 60, "timesup_mm");
    THEsc_SetWarningTarget(60, "lastmin_mm_relay");
    THEsc_ToggleTimer(TRUE);
    THEsc_ToggleStatus(TRUE);

    thesc_state = THESC_STATE_RUNNING;

    print(sprintf("[mapscript] th_escape: run started — %g player(s), %g minutes, %s\n",
                  nplayers, minutes,
                  (thesc_difficulty == THESC_DIFF_NIGHTMARE) ? "nightmare" : "normal"));
};

void() THEsc_ReadGameCounter =
{
    // Sven reads pCaller.pev.frags, i.e. the count of the game_counter that
    // fired the trigger_script.  Trigger_UseTargets here passes an ACTIVATOR
    // but not a caller, so the counter is resolved by name instead — which is
    // no less specific, since the map has exactly one and this whole file is
    // written against that one map.
    entity c = find(world, targetname, "veh1_repaircount");
    while (c != world && c.classname != "game_counter")
        c = find(c, targetname, "veh1_repaircount");

    if (c == world)
        return;

    float v = c.frags;

    while (thesc_evt_next < thesc_evt_count && thesc_evt_pct[thesc_evt_next] <= v)
    {
        string tgt = THEsc_EventTarget(thesc_evt_id[thesc_evt_next]);
        thesc_evt_next = thesc_evt_next + 1;      // advance BEFORE firing: the
                                                  // chain can re-enter this.
        if (cvar("sv_debug_use"))
            dprint(sprintf("[mapscript] th_escape: repair %g%% -> event \"%s\"\n",
                           v, tgt));
        SV_FireTargetsByName(tgt, world, USE_TOGGLE);
    }
};

void() THEsc_SetSkill =
{
    float sk = (thesc_difficulty == THESC_DIFF_NIGHTMARE) ? 2 : 1;
    cvar_set("skill", ftos(sk));

    // g_Map.LoadMapSkillFile().  Nothing else in this tree loads
    // maps/<name>_skl.cfg, and th_escape ships one with 80-odd sk_* overrides,
    // so this is the only place those values ever arrive.  ismapcfg FALSE: it
    // is a pure cvar file and must not run the map-cfg token consumer a second
    // time.
    SV_ApplyConfigFile(sprintf("maps/%s_skl.cfg", mapname), FALSE);

    print(sprintf("[mapscript] th_escape: skill %g (%s)\n", sk,
                  (sk == 2) ? "nightmare" : "normal"));
};

void() THEsc_AbortGame =
{
    if (thesc_state != THESC_STATE_RUNNING)
        return;

    thesc_state = THESC_STATE_FAILED;
    THEsc_ToggleTimer(FALSE);
    THEsc_ToggleStatus(FALSE);
    print("[mapscript] th_escape: run aborted\n");
};

void() THEsc_EndGame =
{
    if (thesc_state != THESC_STATE_RUNNING)
        return;

    thesc_state = THESC_STATE_FINISHED;
    print("[mapscript] th_escape: escaped\n");
    THEsc_TheEnd();
};

void() THEsc_GameOutro =
{
    float n = 0;
    entity e = find(world, classname, "monster_human_grunt");
    while (e)
    {
        entity nxt = find(e, classname, "monster_human_grunt");
        remove(e);
        n = n + 1;
        e = nxt;
    }
    if (cvar("sv_debug_use"))
        dprint(sprintf("[mapscript] th_escape: outro removed %g grunt(s)\n", n));
};

void() THEsc_ShowSurvivors =
{
    if (thesc_n_winnars <= 0)
        return;

    string s = (thesc_n_winnars == 1) ? "SURVIVOR\n\n" : "SURVIVORS\n\n";

    entity p = player_chain_head;
    while (p)
    {
        if (p.targetname == "winnars")
            s = strcat(s, p.netname, "\n");
        p = p.player_chain_next;
    }
    THEsc_Message(world, s);
};

void() THEsc_ShowLosers =
{
    float n = thesc_n_lastliving + thesc_n_ghosts;
    if (n <= 0)
        return;

    string s = (n == 1) ? "LOSER\n\n" : "LOSERS\n\n";

    entity p = player_chain_head;
    while (p)
    {
        if (p.targetname == "lastliving")
            s = strcat(s, p.netname, "\n");
        p = p.player_chain_next;
    }
    p = player_chain_head;
    while (p)
    {
        if (p.targetname == "ghostboyes")
            s = strcat(s, p.netname, "\n");
        p = p.player_chain_next;
    }
    THEsc_Message(world, s);
};

// ---------------------------------------------------------------------------
//  Dispatch.  Returns TRUE when the name was recognised.
//
//  Compared case-insensitively for the same reason Sentences_IndexOf is: the
//  key comes out of a .bsp and nothing guarantees the mapper's capitalisation
//  matches the script's.  th_escape's 17 all match exactly, but that is luck.
// ---------------------------------------------------------------------------
float(string fn) THEsc_Call =
{
    string f = strtolower(fn);

    if (f == "setcharacters")      { THEsc_SetCharacters();   return TRUE; }
    if (f == "equipcharacters")    { THEsc_EquipCharacters(); return TRUE; }
    if (f == "startcharacters")    { THEsc_StartCharacters(); return TRUE; }

    if (f == "targetitembattery")  { THEsc_SetItemStatus(THESC_ITEM_BATTERY, TRUE); return TRUE; }
    if (f == "targetitemgascan")   { THEsc_SetItemStatus(THESC_ITEM_GASCAN,  TRUE); return TRUE; }
    if (f == "targetitemtoolbox")  { THEsc_SetItemStatus(THESC_ITEM_TOOLBOX, TRUE); return TRUE; }
    if (f == "allitemsdroppedoff") { THEsc_ToggleStatus(FALSE); return TRUE; }

    if (f == "readgamecounter")    { THEsc_ReadGameCounter(); return TRUE; }

    if (f == "vehicleignitionon")
    {
        if (thesc_state != THESC_STATE_RUNNING)
            return TRUE;                       // recognised, deliberately inert
        FuncTrackVehicle_IgnitionOn(FuncTrackVehicle_Find("veh1_drivable"));
        return TRUE;
    }
    if (f == "vehiclestarted")
    {
        if (thesc_state != THESC_STATE_RUNNING)
            return TRUE;
        FuncTrackVehicle_EnableControls(FuncTrackVehicle_Find("veh1_drivable"));
        return TRUE;
    }

    if (f == "normaldifficulty")
    {
        thesc_difficulty = THESC_DIFF_NORMAL;
        THEsc_SetSkill();
        return TRUE;
    }
    if (f == "nightmaredifficulty")
    {
        thesc_difficulty = THESC_DIFF_NIGHTMARE;
        THEsc_SetSkill();
        return TRUE;
    }

    if (f == "abortgame")      { THEsc_AbortGame();     return TRUE; }
    if (f == "endgame")        { THEsc_EndGame();       return TRUE; }
    if (f == "gameoutro")      { THEsc_GameOutro();     return TRUE; }
    if (f == "showsurvivors")  { THEsc_ShowSurvivors(); return TRUE; }
    if (f == "showlosers")     { THEsc_ShowLosers();    return TRUE; }

    return FALSE;
};

// ---------------------------------------------------------------------------
//  Lifecycle hooks, all called from sv_mapscript.qc.
// ---------------------------------------------------------------------------
void() THEsc_ResetForMap =
{
    thesc_state      = THESC_STATE_NEW;
    thesc_difficulty = THESC_DIFF_NORMAL;

    thesc_timer_active     = FALSE;
    thesc_timer_deadline   = 0;
    thesc_timer_last_shown = -1;
    thesc_warn_secs        = 0;
    thesc_warn_fired       = FALSE;
    THEsc_ClearTimerStrings();

    float i;
    for (i = 0; i < THESC_ITEM_COUNT; i = i + 1)
        thesc_item_status[i] = FALSE;
    thesc_status_shown = FALSE;

    for (i = 0; i < THESC_CHAR_COUNT; i = i + 1)
        thesc_char_taken[i] = FALSE;

    thesc_evt_count = 0;
    thesc_evt_next  = 0;

    thesc_n_winnars    = 0;
    thesc_n_lastliving = 0;
    thesc_n_ghosts     = 0;

    thesc_effect_wearoff_at = 0;

    // The scratch entity does not survive a map change; PR_Deinit clears QC
    // globals but the pointer is stale either way.  Dropped rather than
    // removed — the map change frees it.
    thesc_hud_ent = world;
};

// MapInit.  Called once, from MapScript_SetScript — i.e. from inside worldspawn,
// where SV_ApplyMapConfigFile runs, and therefore BEFORE any entity spawns.
// That is the only safe place to precache, which is why the character models
// are taken here rather than left to the lazy precache in
// THEsc_StartCharacterModels.
void() THEsc_MapInit =
{
    THEsc_InitRandomEvents();

    // All sixteen roster models plus the three civilian faces.  A runtime
    // precache does work in this engine — sh_modellist.qc's
    // Modellist_PrecacheTargets relies on it — but StartCharacters can fire
    // several minutes into the map, and a client that joined before it would
    // have to be handed the model mid-session.  Doing it at worldspawn removes
    // that entirely, and only the one map that names this script pays for it.
    float i;
    for (i = 0; i < THESC_CHAR_COUNT; i = i + 1)
    {
        string nm = THEsc_CharModelName(i);
        if (nm != "")
            precache_model(THEsc_ModelPath(nm));
    }
    for (i = 0; i < 3; i = i + 1)
        precache_model(THEsc_ModelPath(THEsc_DefaultModelName(i)));
};

// ClientPutInServer's CustomHUD replay: a player who joins mid-run has to be
// told what is already on screen.
void(entity plyr) THEsc_PlayerSpawn =
{
    if (thesc_status_shown)
        THEsc_SendObjectives(plyr);
    if (thesc_timer_active)
        THEsc_SendClock(plyr, floor(thesc_timer_deadline - time));
};

// 10 Hz, from the same place the rest of the server's periodic work runs.
void() THEsc_Frame =
{
    THEsc_TimerTick();
};
