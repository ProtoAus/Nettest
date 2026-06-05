// =============================================
//  Radio quick-chat — server side
// =============================================
//
// Receives CSEv_radio_f from CSQC (client/cl_radio.qc), resolves which
// character voice pack to use from the sender's player_model_index, and
// broadcasts a random variant of the chosen voice line.  Variant
// detection runs once at worldspawn — each (character, command) probes
// 9 possible filenames (bare + 1..8 suffix) and remembers which ones
// exist.  At play time we pick uniformly over the existing variants.
//
// Currently broadcasts to everyone with ATTN_NONE — Radio_Broadcast()
// is the single hook to swap in a team-only filter later without
// touching the input path.

const float RADIO_COMMAND_COUNT      = 8;
const float RADIO_MAX_VARIANT_SLOTS  = 9;  // slot 0 = bare name (no suffix), 1..8 = suffix "1".."8"

// File-name stems for each radio choice (1..8).  Joined with an
// optional numeric suffix at play time to produce e.g.
// "sounds/characters/<folder>/Affirmative2.ogg".  Order matches
// radio_labels[] in client/cl_radio.qc.
string radio_command_files[RADIO_COMMAND_COUNT] = {
    "Affirmative",
    "Negative",
    "OverThere",
    "ISawSomeone",
    "PlantTheBomb",
    "DefuseTheBomb",
    "ThankYou",
    "Fuck"
};

// Folder slugs per player_model_index for the team-driven slots 0..3.
// Matches the model paths in shared/sh_customdefs.qc:659-672 and
// PlayerApplyModel in server/sv_player.qc:483-504.
string radio_folder_blue[TEAM_MODEL_COUNT] = { "urban", "gign", "gsg9", "sas" };
string radio_folder_red[TEAM_MODEL_COUNT]  = { "guerilla", "leet", "terror", "arctic" };

// Fallback voice pack — guaranteed to be populated by the user, so a
// missing per-character voice line still plays *something* (as long as
// numberk has at least one variant for that command).
#define RADIO_FALLBACK_FOLDER "numberk"

// All known voice-pack folders — used for the startup probe + precache
// loop.  Keep in sync with the indices Radio_ResolveFolder returns.
const float RADIO_FOLDER_COUNT = 12;
string radio_all_folders[RADIO_FOLDER_COUNT] = {
    "urban", "gign", "gsg9", "sas",
    "guerilla", "leet", "terror", "arctic",
    "sini", "chickenman", "numberk", "kilmer"
};

// Variant existence flags.  Indexed by
//   (folder_idx * RADIO_COMMAND_COUNT + cmd_idx) * RADIO_MAX_VARIANT_SLOTS + slot
// where slot 0 is the bare filename (no numeric suffix) and slots 1..8
// correspond to "1".."8" suffixes.  Populated by Radio_PrecacheAll.
float radio_variant_exists[RADIO_FOLDER_COUNT * RADIO_COMMAND_COUNT * RADIO_MAX_VARIANT_SLOTS];

// Per-player cooldown (sec).  One-line guard against spam in
// CSEv_radio_f.  Field declared here because it's only used by the
// radio path.
.float radio_next_time;

// --- folder resolution ---

// Map a player entity to its voice-pack folder name.
string(entity p) Radio_ResolveFolder =
{
    float idx = p.player_model_index;

    if (idx == 5) return "sini";
    if (idx == 6) return "chickenman";
    if (idx == 7) return "numberk";
    if (idx == 8) return "kilmer";

    idx = bound(0, idx, TEAM_MODEL_COUNT - 1);
    if (p.player_team == TEAM_BLUE)
        return radio_folder_blue[idx];
    if (p.player_team == TEAM_RED)
        return radio_folder_red[idx];

    return RADIO_FALLBACK_FOLDER;
};

// Linear lookup — folder slug → index in radio_all_folders[].
// Returns -1 if not found (shouldn't happen given Radio_ResolveFolder).
float(string folder) Radio_FolderIndex =
{
    float i;
    for (i = 0; i < RADIO_FOLDER_COUNT; i = i + 1)
        if (radio_all_folders[i] == folder)
            return i;
    return -1;
};

// --- path construction ---

// Build a candidate filename for (folder, cmd, slot).  slot 0 = bare
// "<stem>.ogg"; slots 1..8 = "<stem><N>.ogg".  Used both at probe time
// (Radio_PrecacheAll) and at play time (Radio_Broadcast).
string(string folder, float cmd_idx, float slot) Radio_BuildVariantPath =
{
    string suffix;
    if (slot == 0)
        suffix = "";
    else
        suffix = sprintf("%d", slot);
    return strcat("sounds/characters/", folder, "/",
                  radio_command_files[cmd_idx], suffix, ".ogg");
};

// --- existence probe ---

// Returns TRUE if `path` resolves to an actual file (loose or paked).
// fopen searches the engine's full FS hierarchy, so it's a reliable
// existence check from QC.  Closes the handle immediately — we don't
// actually read the file.
float(string path) Radio_FileExists =
{
    float h = fopen(path, FILE_READ);
    if (h < 0) return FALSE;
    fclose(h);
    return TRUE;
};

// --- precache ---

// At worldspawn, walk every (character, command, slot) and probe for
// the file.  Only precache_sound the ones that exist — keeps the
// engine console quiet for un-recorded variants.  Records existence
// in radio_variant_exists[] for the random-pick path.  Also precaches
// the shared radio beeps that frame every transmission.
void() Radio_PrecacheAll =
{
    precache_sound("sounds/radio/beep1.ogg");
    precache_sound("sounds/radio/beep2.ogg");

    float f, c, s;
    for (f = 0; f < RADIO_FOLDER_COUNT; f = f + 1)
    {
        for (c = 0; c < RADIO_COMMAND_COUNT; c = c + 1)
        {
            float base = (f * RADIO_COMMAND_COUNT + c) * RADIO_MAX_VARIANT_SLOTS;
            for (s = 0; s < RADIO_MAX_VARIANT_SLOTS; s = s + 1)
            {
                string path = Radio_BuildVariantPath(radio_all_folders[f], c, s);
                if (Radio_FileExists(path))
                {
                    radio_variant_exists[base + s] = TRUE;
                    precache_sound(path);
                }
            }
        }
    }
};

// --- variant pick ---

// Count existing variants for (folder, cmd) and pick one uniformly at
// random.  Returns the chosen slot (0..8) or -1 if no variants exist.
float(string folder, float cmd_idx) Radio_PickVariantSlot =
{
    float f = Radio_FolderIndex(folder);
    if (f < 0) return -1;
    float base = (f * RADIO_COMMAND_COUNT + cmd_idx) * RADIO_MAX_VARIANT_SLOTS;

    float count = 0;
    float s;
    for (s = 0; s < RADIO_MAX_VARIANT_SLOTS; s = s + 1)
        if (radio_variant_exists[base + s])
            count = count + 1;

    if (count <= 0) return -1;

    float pick = floor(random() * count);
    if (pick >= count) pick = count - 1;
    if (pick < 0) pick = 0;

    // Walk to the Nth existing slot.
    float seen = 0;
    for (s = 0; s < RADIO_MAX_VARIANT_SLOTS; s = s + 1)
    {
        if (!radio_variant_exists[base + s]) continue;
        if (seen == pick) return s;
        seen = seen + 1;
    }
    return -1;
};

// --- broadcast ---

// Broadcast a chosen voice line.  Picks a random variant; if the
// character has no variants for the requested command, falls back to
// numberk.  If numberk also has none, silently drops the radio.
//
// Sends the resolved voice path as a CSQC_EVENT_RADIO_CALL multicast
// event — each client orchestrates the beep1 → voice → beep2 sequence
// locally using soundlength() (CSQC builtin, no SSQC equivalent).
//
// Single hook for future behaviour swaps: making the broadcast team-
// only is a one-function change here — switch multicast(...) to a
// per-recipient MSG_ONE loop filtered on player_team.
void(entity sender, float choice) Radio_Broadcast =
{
    float cmd_idx = choice - 1;
    if (cmd_idx < 0 || cmd_idx >= RADIO_COMMAND_COUNT)
        return;

    string folder = Radio_ResolveFolder(sender);
    float slot = Radio_PickVariantSlot(folder, cmd_idx);

    if (slot < 0 && folder != RADIO_FALLBACK_FOLDER)
    {
        // Sender's character has no recording for this command — try
        // the fallback voice pack so the radio still says *something*.
        folder = RADIO_FALLBACK_FOLDER;
        slot = Radio_PickVariantSlot(folder, cmd_idx);
    }

    if (slot < 0)
        return;  // nothing to play

    string path = Radio_BuildVariantPath(folder, cmd_idx, slot);

    // CSQC orchestrates the beep1/voice/beep2 sequence — server just
    // tells everyone "play this voice path" and the client times it.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_RADIO_CALL);
    WriteString(MSG_MULTICAST, path);
    multicast(sender.origin, MULTICAST_ALL);
};

// CSQC -> SSQC entry. `self` is the calling player. choice is 1..8.
void(float choice) CSEv_radio_f =
{
    if (choice < 1 || choice > RADIO_COMMAND_COUNT)
        return;
    if (self.is_dead)
        return;
    if (self.player_team != TEAM_BLUE && self.player_team != TEAM_RED)
        return;
    if (time < self.radio_next_time)
        return;

    self.radio_next_time = time + 1.0;
    Radio_Broadcast(self, choice);
};
