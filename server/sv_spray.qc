// =============================================================
//  Player spray decals — server side
// =============================================================
//
//  Spray system overview
//  ---------------------
//  Player triggers impulse 19 ("Spray").  PlayerPreThink in
//  sv_player.qc routes that to SV_PlayerSpray() (this file).  We
//  enforce a per-player cooldown (sv_sprayfrequency, seconds), and
//  a per-player FIFO cap (sv_spraymax) on the number of active
//  sprays this player owns at once.  When the cap is hit, the
//  oldest spray gets a REMOVE event broadcast so all clients drop
//  their local trisoup slot for it; then the new spray spawns.
//
//  We don't store geometry server-side — that's the client's
//  problem.  Server only tracks the (owner, spray_id, birthtime)
//  tuple per active spray, which is enough for FIFO eviction.
//  A single global table avoids per-entity array headaches.
//
//  Spray catalog distribution: server hosts gfx/sprays/*.png;
//  clients without a particular PNG auto-download via FTE's
//  standard download protocol (server must set allow_download 1
//  and allow_download_other 1).  Player picks their spray name
//  via the main-menu panel, which writes the basename into the
//  `_spray` userinfo key via `setinfo`.  We read it here with
//  infokey() and sanitize before validating the file exists.
//
//  Wire: CSQC_EVENT_SPRAY (35) + CSQC_EVENT_SPRAY_REMOVE (36),
//  see shared/sh_weapons.qc for the payload layout.

// ---------- Per-player state ----------
.float  spray_last_time;     // server time of this player's last successful spray
.string player_spray_name;   // current spray basename — set via `cmd setspray <name>`
                              // from the client.  Read by SV_PlayerSpray each fire.
                              // Empty / unset → fall back to "nospray".

// ---------- Global active-spray table ----------
//
// SV_SPRAY_GLOBAL_MAX = SV_SPRAYMAX_HARDCAP × server-side player cap.
// 16 sprays × 32 players = 512 slots, ample headroom.  Slot 0 is
// reserved as "free" so spray_id 0 is never assigned (matches the
// client convention where spray_slot_id == 0 means "free slot").
const float SV_SPRAYMAX_HARDCAP  = 16;
const float SV_SPRAY_GLOBAL_MAX  = 512;
const float SPRAY_TRACE_DIST     = 64;
const float SPRAY_NAME_MAX       = 32;

float  spray_id_counter;                          // monotonic, never reused
entity spray_table_owner    [SV_SPRAY_GLOBAL_MAX];// player ent owning each slot (world = free)
float  spray_table_id       [SV_SPRAY_GLOBAL_MAX];// spray_id stored in this slot (0 = free)
float  spray_table_birthtime[SV_SPRAY_GLOBAL_MAX];// time the slot was claimed (FIFO key)

// Find a free table slot.  Returns -1 if the global table is full
// (unlikely in practice, but the cap is enforced).
float() SV_Spray_AllocSlot =
{
    float i;
    for (i = 1; i < SV_SPRAY_GLOBAL_MAX; i = i + 1)
    {
        if (spray_table_owner[i] == world)
            return i;
    }
    return -1;
};

// Find self's oldest active spray slot (lowest birthtime).  Returns
// -1 if the player has none.  Called when the per-player cap is hit.
float(entity owner) SV_Spray_OldestSlotFor =
{
    float i;
    float best = -1;
    float best_t = 0;
    for (i = 1; i < SV_SPRAY_GLOBAL_MAX; i = i + 1)
    {
        if (spray_table_owner[i] != owner) continue;
        if (best < 0 || spray_table_birthtime[i] < best_t)
        {
            best = i;
            best_t = spray_table_birthtime[i];
        }
    }
    return best;
};

// Count this player's currently-active sprays.
float(entity owner) SV_Spray_CountFor =
{
    float i;
    float n = 0;
    for (i = 1; i < SV_SPRAY_GLOBAL_MAX; i = i + 1)
    {
        if (spray_table_owner[i] == owner)
            n = n + 1;
    }
    return n;
};

// Free a slot and tell all clients to drop the visual.  MULTICAST_ALL
// so out-of-PVS clients that may have allocated a slot earlier still
// release it — otherwise sprays leak as players move around the map.
void(float slot) SV_Spray_EvictSlot =
{
    if (slot < 1 || slot >= SV_SPRAY_GLOBAL_MAX) return;
    if (spray_table_owner[slot] == world) return;

    float sid = spray_table_id[slot];

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_SPRAY_REMOVE);
    WriteShort(MSG_MULTICAST, sid);
    multicast('0 0 0', MULTICAST_ALL);

    spray_table_owner[slot]     = world;
    spray_table_id[slot]        = 0;
    spray_table_birthtime[slot] = 0;
};

// Wipe the whole spray table.  Called by SV_Spray_ClearWorld on map
// change / restart so a new map doesn't inherit stale slot ownership.
// We don't send REMOVE events — clients clear their own decal buffers
// on map change via CSQC_ClearSprays.
void() SV_Spray_ClearWorld =
{
    float i;
    for (i = 0; i < SV_SPRAY_GLOBAL_MAX; i = i + 1)
    {
        spray_table_owner[i]     = world;
        spray_table_id[i]        = 0;
        spray_table_birthtime[i] = 0;
    }
    spray_id_counter = 0;
};

// Validate the spray name read from the player's `_spray` userinfo.
// Returns the sanitized name (or "nospray" on rejection).  We refuse:
//   - empty / "0"
//   - anything with /, \, or .. (path traversal)
//   - anything longer than SPRAY_NAME_MAX
// Caller still has to fopen-probe the resulting path to confirm the
// PNG actually exists on disk.
string(string raw) SV_Spray_SanitizeName =
{
    if (raw == "" || raw == "0")
        return "nospray";
    if (strlen(raw) > SPRAY_NAME_MAX)
        return "nospray";
    if (strstrofs(raw, "/",  0) >= 0) return "nospray";
    if (strstrofs(raw, "\\", 0) >= 0) return "nospray";
    if (strstrofs(raw, "..", 0) >= 0) return "nospray";
    return raw;
};

// Resolve the player's spray name.  Trusts the sanitized name
// without a server-side file-existence check.
//
// History: an earlier version of this function used `fopen` (and a
// later attempt used `search_begin`) to verify gfx/sprays/<name>.png
// existed on disk before accepting it, falling back to "nospray" if
// missing.  Both builtins have FTE path-resolution quirks for
// gamedir/data/pak split that don't match the asset resolver the
// CSQC + renderer use — net result was "menu finds the file fine,
// server rejects it, multicast ships "nospray", every client renders
// nospray.png for every spray".
//
// SV_Spray_SanitizeName above already rejects path-traversal
// characters ("/", "\\", "..") and over-long names, so accepting
// the name without disk validation is safe.  If the named file
// doesn't actually exist, every client will independently fall
// back via their own CSQC missing-texture handling (CSQC's
// CSQC_RegenerateSpraysShader builds the shader on demand; absent
// PNG produces a transparent / placeholder decal).  That's the
// same UX the fopen fallback aimed for, without the path quirk.
string(string name) SV_Spray_ResolveName =
{
    if (name == "")
        return "nospray";
    return name;
};

// `cmd setspray <name>` handler.  Called from SV_ParseClientCommand
// in sv_player.qc when the client sends a setspray.  Sanitizes the
// supplied name and stores it on the player; SV_PlayerSpray reads it
// next time the player fires the spray impulse.  Unlike the userinfo
// path this updates immediately and survives mid-match changes.
void(string args) SV_HandleSetSpray =
{
    // argv(0) = "setspray", argv(1) = name
    if (argv(0) != "setspray") return;
    string name = SV_Spray_SanitizeName(argv(1));
    // strzone the value so the string persists across the function
    // return.  The previously-held string (if any) is strunzone'd
    // first to avoid leaking.
    if (self.player_spray_name)
        strunzone(self.player_spray_name);
    self.player_spray_name = strzone(name);
};

// Impulse 19 handler.  Called from sv_player.qc's impulse switch.
void() SV_PlayerSpray =
{
    // Cooldown — gates rapid spam.  sv_sprayfrequency in seconds.
    // Gate only fires when there HAS been a previous spray
    // (spray_last_time > 0).  On a fresh connection / spawn the
    // field starts at 0, which would otherwise lock the first spray
    // out for the first `sv_sprayfrequency` seconds of server time —
    // not what users expect.
    if (self.spray_last_time > 0
     && time < self.spray_last_time + cvar("sv_sprayfrequency"))
        return;

    // Pull the player's chosen spray name from the field set via
    // `cmd setspray <name>`.  The earlier userinfo-based path
    // (`infokey(self, "_spray")`) didn't propagate mid-session in
    // this engine config — the client had to reconnect for changes
    // to land — so a direct cmd channel is used instead.  Empty name
    // (player hasn't picked yet, or value cleared) falls back to
    // "nospray".  Sanitize regardless in case the client supplied
    // path-traversal garbage.
    string raw  = self.player_spray_name;
    string name = SV_Spray_SanitizeName(raw);
    name = SV_Spray_ResolveName(name);

    if (cvar("sv_debug_spray"))
        bprint(PRINT_HIGH, sprintf("[spray-sv] player#%g raw='%s' resolved='%s'\n",
                                    num_for_edict(self), raw, name));

    if (name == "")
        return;   // no usable PNG on disk (not even nospray)

    // Trace forward to find the wall we're spraying on.  64u is the
    // standard "use" range — close-enough-to-touch.  No hit, no spray.
    makevectors(self.v_angle);
    vector start = self.origin + self.view_ofs;
    vector end   = start + v_forward * SPRAY_TRACE_DIST;
    traceline(start, end, MOVE_NORMAL, self);
    if (trace_fraction >= 1.0)
        return;
    if (trace_plane_normal == '0 0 0')
        return;   // shouldn't happen with a real trace hit, but be safe

    // Per-player FIFO cap.  Clamp cvar to [1, hardcap] so a malformed
    // value can't blow up the global table.
    float cap = cvar("sv_spraymax");
    if (cap < 1) cap = 1;
    if (cap > SV_SPRAYMAX_HARDCAP) cap = SV_SPRAYMAX_HARDCAP;

    if (SV_Spray_CountFor(self) >= cap)
    {
        float oldest = SV_Spray_OldestSlotFor(self);
        if (oldest >= 0)
            SV_Spray_EvictSlot(oldest);
    }

    // Allocate a new slot in the global table.  If full (very
    // unlikely with 512 entries) bail rather than corrupt state.
    float slot = SV_Spray_AllocSlot();
    if (slot < 0)
        return;

    spray_id_counter = spray_id_counter + 1;
    if (spray_id_counter >= 65535)
        spray_id_counter = 1;   // wrap before overflowing WriteShort range

    spray_table_owner[slot]     = self;
    spray_table_id[slot]        = spray_id_counter;
    spray_table_birthtime[slot] = time;

    // Multicast the spawn to all clients in PVS of the impact point.
    // Out-of-PVS clients don't allocate the slot; if they come into
    // PVS later they won't see this spray (late-join-style limitation
    // documented in the plan).
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_SPRAY);
    WriteShort(MSG_MULTICAST, spray_id_counter);
    WriteByte(MSG_MULTICAST, num_for_edict(self));
    WriteCoord(MSG_MULTICAST, trace_endpos_x);
    WriteCoord(MSG_MULTICAST, trace_endpos_y);
    WriteCoord(MSG_MULTICAST, trace_endpos_z);
    WriteCoord(MSG_MULTICAST, trace_plane_normal_x);
    WriteCoord(MSG_MULTICAST, trace_plane_normal_y);
    WriteCoord(MSG_MULTICAST, trace_plane_normal_z);
    // Eye origin — anchor for the CSQC "spray-can" smoke puffs that
    // emit from the spraying player, drifting toward the wall.  We
    // ship it on the wire so remote viewers can render the smoke
    // without having to find the owner entity by entnum.
    WriteCoord(MSG_MULTICAST, start_x);
    WriteCoord(MSG_MULTICAST, start_y);
    WriteCoord(MSG_MULTICAST, start_z);
    WriteString(MSG_MULTICAST, name);
    multicast(trace_endpos, MULTICAST_PVS);

    // Spray-can sound — only fires after we've fully committed to the
    // spray (cooldown passed, file valid, surface hit).  Attached to
    // the player so it positions correctly for remote listeners and
    // moves with them if they keep walking.  CHAN_VOICE so it doesn't
    // collide with weapon-fire sounds on the same channel.
    sound(self, CHAN_VOICE, "sounds/player/spray.wav", 1, ATTN_NORM);

    self.spray_last_time = time;
};
