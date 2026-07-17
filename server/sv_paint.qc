// ============================================================
//  server/sv_paint.qc — player body painting, server authority
//
//  CAMO: player holds +camo (impulse 21 press / 22 release — latched in
//  .camo_hold by the impulse switch in sv_player.qc) while aiming at a
//  surface within sv_camo_range.  Coverage accumulates over sv_camo_time
//  seconds and the (wall texture name, coverage) pair is broadcast on
//  CSQC_EVENT_PLAYER_PAINT sub 0; every client stamps the actual wall
//  texture onto that player's skin (client/cl_paint.qc).
//
//  SPLATS: paintball hits on players call SV_Paint_PlayerSplat
//  (sh_wpn_paintball.qc) -> sub 1 broadcast (color + seed).
//
//  Wash: damage cuts coverage by sv_camo_damage_loss per hit; respawn
//  clears everything (sub 2) — the corpse keeps its paint until then.
//  Late joiners get every live player's camo re-sent from
//  PutClientInServer (splats are live-only, v1 limitation).
//
//  All state broadcasts are MULTICAST_ALL: paint is persistent visual
//  state, so out-of-PVS clients must hear about it too (few bytes,
//  event-rate only).
// ============================================================

.float  camo_hold;        // +camo held (impulse 21/22 latch)
.float  camo_amt;         // 0..1 coverage
.string camo_tex;         // zoned wall texture name ("" = none)
.float  camo_next_send;   // rate limiter
.float  camo_sent_amt;    // last broadcast coverage

float paint_seed_counter; // unique-ish seeds for splat placement

// ---------- broadcasts ----------
void(entity p) SV_Paint_SendCamo =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_PAINT);
    WriteByte(MSG_MULTICAST, 0);
    WriteByte(MSG_MULTICAST, num_for_edict(p));
    WriteByte(MSG_MULTICAST, floor(bound(0, p.camo_amt, 1) * 255));
    WriteString(MSG_MULTICAST, p.camo_tex);
    multicast('0 0 0', MULTICAST_ALL);
    p.camo_sent_amt  = p.camo_amt;
    p.camo_next_send = time + 0.12;
};

void(entity victim, vector col, float seed) SV_Paint_PlayerSplat =
{
    if (!victim || clienttype(victim) == CLIENTTYPE_NOTACLIENT) return;
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_PAINT);
    WriteByte(MSG_MULTICAST, 1);
    WriteByte(MSG_MULTICAST, num_for_edict(victim));
    WriteByte(MSG_MULTICAST, bound(0, floor(col_x * 255 + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(col_y * 255 + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(col_z * 255 + 0.5), 255));
    WriteShort(MSG_MULTICAST, seed);
    multicast('0 0 0', MULTICAST_ALL);
};

// Fresh seed for a splat (uniqueness is all that matters — the CLIENT
// derives the deterministic splat position from it).
float() SV_Paint_NextSeed =
{
    paint_seed_counter = paint_seed_counter + 1;
    if (paint_seed_counter >= 32000) paint_seed_counter = 1;
    return paint_seed_counter;
};

void(entity p) SV_Paint_SendClear =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_PAINT);
    WriteByte(MSG_MULTICAST, 2);
    WriteByte(MSG_MULTICAST, num_for_edict(p));
    multicast('0 0 0', MULTICAST_ALL);
};

// ---------- lifecycle ----------
// Respawn wash: clears local state + tells every client.  Called from
// PutClientInServer (sv_player.qc) — the corpse keeps its paint until then.
void(entity p) SV_Paint_ClearPlayer =
{
    if (p.camo_tex != "" && p.camo_tex)
        strunzone(p.camo_tex);
    p.camo_tex  = "";
    p.camo_amt  = 0;
    p.camo_hold = 0;
    p.camo_sent_amt = 0;
    // Always broadcast: splats live client-side only, so the server can't
    // know whether there's anything to clear — a stray sub-2 is 5 bytes.
    SV_Paint_SendClear(p);
};

// Late-join resync: re-send every painted player's camo to the joiner.
// Splats are not resynced (live-only v1).  MSG_ONE unicast; bots have no
// netchan (clienttype guard — the bot-netchan trap).
void(entity joiner) SV_Paint_SyncTo =
{
    if (!joiner || bot_adding || clienttype(joiner) != CLIENTTYPE_REAL) return;
    entity p = find(world, classname, "player");
    while (p)
    {
        if (p != joiner && p.camo_amt > 0 && p.camo_tex != "")
        {
            msg_entity = joiner;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_PLAYER_PAINT);
            WriteByte(MSG_ONE, 0);
            WriteByte(MSG_ONE, num_for_edict(p));
            WriteByte(MSG_ONE, floor(bound(0, p.camo_amt, 1) * 255));
            WriteString(MSG_ONE, p.camo_tex);
        }
        p = find(p, classname, "player");
    }
};

// Damage wash: each hit scrubs off a slice of the camo.  Called from the
// player-damage path in sv_weapons.qc.  Splats stay (they're the ATTACKER's
// paint — damage shouldn't clean the victim for free).
void(entity victim) SV_Paint_OnDamage =
{
    if (victim.camo_amt <= 0) return;
    victim.camo_amt = victim.camo_amt - cvar("sv_camo_damage_loss");
    if (victim.camo_amt < 0) victim.camo_amt = 0;
    SV_Paint_SendCamo(victim);
};

// ---------- per-frame camo accumulation (PlayerPreThink, sv_player.qc) ----------
void() SV_Paint_CamoThink =
{
    if (!self.camo_hold)                 return;
    if (!cvar("sv_camo_enable"))         return;
    if (self.health <= 0)                return;
    if (self.pm_incar)                   return;   // no painting from the driver's seat

    // What surface is the player rubbing against?
    makevectors(self.v_angle);
    vector start = self.origin + self.view_ofs;
    traceline(start, start + v_forward * cvar("sv_camo_range"), MOVE_NORMAL, self);
    if (trace_fraction >= 1)             return;   // nothing in reach
    if (trace_ent != world && trace_ent.solid != SOLID_BSP)
        return;                                    // walls/brush ents only — not props/players

    // Resolve the texture name: engine trace_surfacename where the BSP
    // format provides it, getsurfacenearpoint fallback otherwise (Q1/HL
    // hull traces carry no surface — same dance as sh_surfaceprops.qc).
    string tex = trace_surfacename;
    if (tex == "")
        tex = Surf_TexAtPoint(trace_ent, trace_endpos);
    if (tex == "")                       return;

    if (tex != self.camo_tex)
    {
        // new wall = repaint from scratch in the new pattern
        if (self.camo_tex != "" && self.camo_tex)
            strunzone(self.camo_tex);
        self.camo_tex = strzone(tex);
        self.camo_amt = 0;
        self.camo_sent_amt = 0;
    }

    float t = cvar("sv_camo_time");
    if (t < 0.2) t = 0.2;
    self.camo_amt = self.camo_amt + frametime / t;
    if (self.camo_amt > 1) self.camo_amt = 1;

    // Rate-limited stream: every 0.12 s while it visibly grows, plus the
    // moment it tops out.
    if (time >= self.camo_next_send)
    {
        if (self.camo_amt - self.camo_sent_amt >= 0.04
         || (self.camo_amt >= 1 && self.camo_sent_amt < 1))
            SV_Paint_SendCamo(self);
    }
};
