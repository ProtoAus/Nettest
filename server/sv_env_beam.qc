//
// sv_env_beam.qc — HL/GoldSrc env_beam point entity
//
// Sprite-textured beam (or ring) between two named entities, with
// optional noise jitter, animation, life/strike timing, and contact
// damage.  All visual state is broadcast to clients via a custom
// SendEntity (CSQC_ENT_ENV_BEAM); the actual rendering happens in
// client/cl_env_beam.qc using R_BeginPolygon + R_EndPolygonRibbon.
//
// Keys (driven by nettest.fgd):
//   LightningStart  — targetname of the start entity (info_target,
//                     func_train, etc.).  If unset, the beam picks
//                     a wall surface within Radius via a random
//                     traceline at activation.
//   LightningEnd    — targetname of the end entity.  Same rules.
//   renderamt       — beam brightness 0..255 (alpha).
//   rendercolor     — beam RGB.
//   Radius          — random-target search distance when start/end
//                     are unset.
//   life            — seconds the beam stays active before turning
//                     off and rescheduling.  0 (or <= 0.1) = stays on
//                     forever once activated.
//   BoltWidth       — beam width in tenths of a unit (HL convention).
//   NoiseAmplitude  — 0..255 random path jitter per CSQC tick.
//   texture         — sprite path (e.g. "sprites/laserbeam.spr").
//   TextureScroll   — 0..100 scroll speed along the U axis.
//   framerate       — accepted but currently unused (HL is the same).
//   framestart      — initial animation frame (most beam sprites have
//                     one frame so this picks the variant).
//   StrikeTime      — seconds between deactivation and reactivation.
//   damage          — damage / second while contacting an entity along
//                     the straight (un-jittered) start->end line.
//
// Spawnflags:
//     1  START_ON       — active at map load.
//     2  TOGGLE         — re-triggerable on/off.  Without this, the
//                         beam ignores stop triggers and only loops
//                         via the internal life/strike cycle.
//     4  RANDOM_STRIKE  — life and StrikeTime are jittered ±50%
//                         around their configured values.
//     8  RING           — render as a horizontal ring between the two
//                         points rather than a straight line.
//    16  START_SPARKS   — emit sparks at the start point when active.
//    32  END_SPARKS     — emit sparks at the end point when active.
//    64  DECAL_END      — accepted; ignored (HL unused).
//   128  SHADE_START    — beam alpha fades toward the start point.
//   256  SHADE_END      — beam alpha fades toward the end point.
//                         Mutually exclusive with SHADE_START; if
//                         both set, SHADE_START wins (HL behaviour).
//

const float EBEAM_START_ON      = 1;
const float EBEAM_TOGGLE        = 2;
const float EBEAM_RANDOM_STRIKE = 4;
const float EBEAM_RING          = 8;
const float EBEAM_START_SPARKS  = 16;
const float EBEAM_END_SPARKS    = 32;
const float EBEAM_DECAL_END     = 64;
const float EBEAM_SHADE_START   = 128;
const float EBEAM_SHADE_END     = 256;

// Bits packed into the SendEntity 'flags' byte sent to CSQC.  Kept
// distinct from the spawnflag bits so the wire format isn't tied to
// the mapper-facing flag layout.
const float EBEAM_NET_ACTIVE       = 1;
const float EBEAM_NET_RING         = 2;
const float EBEAM_NET_SHADE_START  = 4;
const float EBEAM_NET_SHADE_END    = 8;
const float EBEAM_NET_START_SPARKS = 16;
const float EBEAM_NET_END_SPARKS   = 32;
const float EBEAM_NET_DECAL_END    = 64;

// Mapper keys parsed by the BSP entity-block reader.  Case matches
// the HL .fgd convention (.fgd is the authoritative source).
// Mapper key casing varies between editors (J.A.C.K. preserves the
// HL FGD's "LightningStart"; some tools lowercase keys on save).
// FTE's ED_FindField does a CASE-SENSITIVE strcmp against the QC
// field name (qclib/pr_edict.c:299), so a single-case declaration
// will silently miss any map that uses a different casing.  Declare
// both common forms; copy whichever is non-empty into the canonical
// LightningStart/LightningEnd at spawn time.
.string LightningStart;
.string LightningEnd;
.string lightningstart;
.string lightningend;
.float  renderamt;
.vector rendercolor;
.float  Radius;
.float  life;
.float  BoltWidth;
.float  NoiseAmplitude;
.string texture;
.float  TextureScroll;
.float  framerate;
.float  framestart;
.float  StrikeTime;
.float  damage;     // HL key — DPS along the straight beam line

// Runtime state.
.entity ebeam_start_ent;        // resolved start entity (world if random)
.entity ebeam_end_ent;          // resolved end entity (world if random)
.vector ebeam_start_pos;        // last-sent start position (cached for delta gate)
.vector ebeam_end_pos;          // last-sent end position
.float  ebeam_active;           // 1 = visually emitting, 0 = idle
.float  ebeam_damage_until;     // next damage tick time (rate-limit to 0.2s)
.float  ebeam_sprite_index;     // precached short modelindex for the sprite
.float  ebeam_end_sprite_index; // env_laser EndSprite modelindex (0 if none)

void() EnvBeam_Tick;
void() EnvBeam_StrikeReactivate;
void() EnvBeam_DamageTick;

// Random target picker: trace from `origin` in a random direction,
// stop at the first solid surface within `radius` qu.  Returns the
// hit point; falls back to origin + dir * radius if the trace
// reaches the limit without hitting anything.
vector(vector origin_in, float radius) EnvBeam_PickRandomEnd =
{
    vector dir;
    dir_x = (random() * 2 - 1);
    dir_y = (random() * 2 - 1);
    dir_z = (random() * 2 - 1) * 0.4;   // bias toward horizontal — HL "random storm" feel
    dir = normalize(dir);
    vector end = origin_in + dir * radius;
    traceline(origin_in, end, MOVE_NORMAL, self);
    return trace_endpos;
};

// Resolve a targetname into an entity reference.  If multiple
// entities share the name (HL spec note), pick one at random for the
// "branching beam" effect.  Returns world if no match.
entity(string name) EnvBeam_FindByName =
{
    if (name == "") return world;
    float count = 0;
    entity e = world;
    entity pick = world;
    // Two-pass: first count matches, then pick the Nth.  Cheaper than
    // building a list in QC and avoids leaking entity refs.
    e = findchain(targetname, name);
    while (e)
    {
        count++;
        e = e.chain;
    }
    if (count == 0) return world;
    float idx = floor(random() * count);
    if (idx >= count) idx = count - 1;
    e = findchain(targetname, name);
    while (e && idx > 0)
    {
        idx--;
        e = e.chain;
    }
    return e ? e : world;
};

// Compute current start/end world positions.  Re-evaluated every
// damage tick + on activation so func_train movement tracks live.
void() EnvBeam_ResolveEndpoints =
{
    vector s, ed;

    if (self.LightningStart != "" && self.ebeam_start_ent != world)
        s = self.ebeam_start_ent.origin;
    else if (self.LightningStart == "")
        s = self.origin;                       // anchor on the env_beam itself
    else
        s = self.ebeam_start_pos;              // stale fallback

    if (self.LightningEnd != "" && self.ebeam_end_ent != world)
        ed = self.ebeam_end_ent.origin;
    else if (self.LightningEnd == "")
    {
        // No end entity — random surface within Radius from start.
        // Recompute each tick only if start is also random (otherwise
        // pin the random pick at activation time to avoid stuttering).
        if (self.LightningStart != "")
            ed = self.ebeam_end_pos;           // pin random end
        else
            ed = EnvBeam_PickRandomEnd(s, self.Radius);
    }
    else
        ed = self.ebeam_end_pos;

    // HL bug "If both endpoint entities happen to be at the same
    // coordinate, the beam will be drawn between that point and world
    // origin (0 0 0)".  We don't reproduce that bug — instead, draw
    // nothing by leaving the cached positions untouched.  This is the
    // "better than HL" path the user asked for.
    if (vlen(ed - s) < 1)
        return;

    self.ebeam_start_pos = s;
    self.ebeam_end_pos   = ed;
};

float(entity ent, float changedflags) EnvBeam_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_ENV_BEAM);

    float netflags = 0;
    if (self.ebeam_active)                 netflags |= EBEAM_NET_ACTIVE;
    if (self.spawnflags & EBEAM_RING)      netflags |= EBEAM_NET_RING;
    if (self.spawnflags & EBEAM_SHADE_START) netflags |= EBEAM_NET_SHADE_START;
    else if (self.spawnflags & EBEAM_SHADE_END) netflags |= EBEAM_NET_SHADE_END;
    if (self.spawnflags & EBEAM_START_SPARKS) netflags |= EBEAM_NET_START_SPARKS;
    if (self.spawnflags & EBEAM_END_SPARKS)   netflags |= EBEAM_NET_END_SPARKS;
    if (self.spawnflags & EBEAM_DECAL_END)    netflags |= EBEAM_NET_DECAL_END;
    WriteByte(MSG_ENTITY, netflags);

    WriteCoord(MSG_ENTITY, self.ebeam_start_pos_x);
    WriteCoord(MSG_ENTITY, self.ebeam_start_pos_y);
    WriteCoord(MSG_ENTITY, self.ebeam_start_pos_z);
    WriteCoord(MSG_ENTITY, self.ebeam_end_pos_x);
    WriteCoord(MSG_ENTITY, self.ebeam_end_pos_y);
    WriteCoord(MSG_ENTITY, self.ebeam_end_pos_z);

    WriteShort(MSG_ENTITY, self.ebeam_sprite_index);
    WriteByte(MSG_ENTITY, bound(0, self.rendercolor_x, 255));
    WriteByte(MSG_ENTITY, bound(0, self.rendercolor_y, 255));
    WriteByte(MSG_ENTITY, bound(0, self.rendercolor_z, 255));
    WriteByte(MSG_ENTITY, bound(0, self.renderamt,    255));
    WriteByte(MSG_ENTITY, bound(0, self.BoltWidth,    255));
    WriteByte(MSG_ENTITY, bound(0, self.NoiseAmplitude, 255));
    // TextureScroll is SIGNED — negative scrolls the other way, which is how
    // every rain beam in th_ep1_00 is authored (TextureScroll -20, i.e. falling
    // rather than rising).  The old bound(0, ..., 100) clamped all 124 of them
    // to exactly 0, so nothing scrolled at all.  Bias by 128 to fit a byte.
    WriteByte(MSG_ENTITY, bound(0, rint(self.TextureScroll) + 128, 255));
    WriteByte(MSG_ENTITY, bound(0, self.framestart,   255));
    // framerate — frames/sec for multi-frame beam sprites.  Sent because CSQC
    // now resolves the beam's shader per FRAME via spriteframe(), so a 3-frame
    // sprite like sprites/lgtning.spr can actually cycle.  172 env_beams across
    // the Sven corpus author this key; it used to be parsed and dropped.
    WriteByte(MSG_ENTITY, bound(0, rint(self.framerate), 255));

    // End-sprite modelindex: 0 for env_beam (no end sprite),
    // non-zero for env_laser which sets self.ebeam_end_sprite_index.
    // Kept in the env_beam wire format so a single CSQC entity type
    // (CSQC_ENT_ENV_BEAM) covers both server entities.
    WriteShort(MSG_ENTITY, self.ebeam_end_sprite_index);

    return TRUE;
};

void() EnvBeam_MarkDirty =
{
    self.SendFlags = 1;          // any non-zero — wire format is "all or nothing"
};

void() EnvBeam_Activate =
{
    self.ebeam_active = 1;

    // Resolve start/end entities once at activation.  Movers (func_train)
    // get re-resolved each tick via EnvBeam_Tick.
    self.ebeam_start_ent = EnvBeam_FindByName(self.LightningStart);
    self.ebeam_end_ent   = EnvBeam_FindByName(self.LightningEnd);

    if (cvar("sv_debug_env_beam"))
    {
        dprint(sprintf("[env_beam] activate \"%s\": LightningStart=\"%s\" -> ent #%g, LightningEnd=\"%s\" -> ent #%g\n",
                       self.targetname,
                       self.LightningStart, num_for_edict(self.ebeam_start_ent),
                       self.LightningEnd,   num_for_edict(self.ebeam_end_ent)));

        // Find-failure walk: if find() returned world for either end,
        // scan the WHOLE entity list and print every match, so we can
        // tell the difference between "no such entity in the map"
        // (find correctly returns nothing) and "find() filter mis-
        // matched something that does exist" (rare but possible).
        if (self.LightningEnd != "" && self.ebeam_end_ent == world)
        {
            float matches = 0;
            entity e = world;
            while ((e = nextent(e)))
            {
                if (e.targetname == self.LightningEnd)
                {
                    dprint(sprintf("  ... scan match: ent #%g classname=\"%s\" origin=%v\n",
                                   num_for_edict(e), e.classname, e.origin));
                    matches++;
                }
            }
            if (matches == 0)
                dprint(sprintf("  ... no entity in the map has targetname=\"%s\"\n",
                               self.LightningEnd));
        }
    }

    // If LightningStart empty, anchor on self.origin.  If LightningEnd
    // empty, pick a random wall now and cache (so the beam doesn't
    // strobe between random points every frame).
    if (self.LightningStart == "")
        self.ebeam_start_pos = self.origin;
    if (self.LightningEnd == "")
    {
        vector seed = (self.LightningStart == "") ? self.origin
                                                  : self.ebeam_start_ent.origin;
        self.ebeam_end_pos = EnvBeam_PickRandomEnd(seed, self.Radius);
    }

    EnvBeam_ResolveEndpoints();
    EnvBeam_MarkDirty();

    // Schedule deactivation by life (RANDOM_STRIKE jitters ±50%).
    // life <= 0.1 means "stay on forever" per HL spec.
    float life_dur = self.life;
    if (self.spawnflags & EBEAM_RANDOM_STRIKE)
        life_dur *= 0.5 + random();
    if (life_dur > 0.1)
    {
        self.think     = EnvBeam_Tick;
        self.nextthink = time + life_dur;
    }
    else
    {
        // Stay on, just tick periodically to track moving endpoints
        // and apply damage.
        self.think     = EnvBeam_DamageTick;
        self.nextthink = time + 0.1;
    }
};

void() EnvBeam_Deactivate =
{
    self.ebeam_active = 0;
    EnvBeam_MarkDirty();

    // Schedule reactivation by StrikeTime unless TOGGLE was used to
    // manually stop the beam (handled in EnvBeam_Use).
    float strike_dur = self.StrikeTime;
    if (self.spawnflags & EBEAM_RANDOM_STRIKE)
        strike_dur *= 0.5 + random();
    if (strike_dur > 0)
    {
        self.think     = EnvBeam_StrikeReactivate;
        self.nextthink = time + strike_dur;
    }
};

// Per-life-period tick: deactivates the beam.  Reactivation is then
// scheduled by Deactivate via StrikeTime.
void() EnvBeam_Tick =
{
    EnvBeam_Deactivate();
};

void() EnvBeam_StrikeReactivate =
{
    EnvBeam_Activate();
};

// Periodic damage + endpoint refresh tick.  Used for life<=0.1
// (forever-on) beams so they still track moving func_train targets
// and apply contact damage.
void() EnvBeam_DamageTick =
{
    if (!self.ebeam_active)
        return;

    // Refresh endpoint positions (movers).  Re-sends only if changed.
    vector old_s = self.ebeam_start_pos;
    vector old_e = self.ebeam_end_pos;
    EnvBeam_ResolveEndpoints();
    if (old_s != self.ebeam_start_pos || old_e != self.ebeam_end_pos)
        EnvBeam_MarkDirty();

    // Apply contact damage if "damage" key set.  Single traceline
    // along the straight start->end line (HL spec: damage ignores
    // noise jitter).  First entity hit gets damage_per_second * 0.1
    // for this tick — we tick at 10Hz so the per-second scaling
    // works out.
    if (self.damage > 0)
    {
        traceline(self.ebeam_start_pos, self.ebeam_end_pos, MOVE_NORMAL, self);
        // NO takedamage GATE, and no direct .health subtraction either.  Both
        // were wrong and they were wrong together:
        //
        //   * players in this mod sit at DAMAGE_NO permanently and are accepted
        //     unconditionally inside W_CanDamageTarget (sv_weapons.qc:1157) - so
        //     a takedamage test here meant an env_beam could damage a crate and
        //     never a person, which is the one thing it exists to do.
        //   * subtracting .health directly skips the entire damage pipeline:
        //     no death handling, no kill feed, no damage flash, no armour.  The
        //     old comment said there was "no attacker context", but the movers
        //     that crush already pass the brush itself as the attacker
        //     (sv_rotating.qc, sv_pendulum.qc), and that works.
        if (self.damage > 0 && trace_ent && trace_ent != world)
            W_ApplyDamage(self, trace_ent, self.damage * 0.1);   // per-tick at 10Hz
    }

    self.nextthink = time + 0.1;
};

void() EnvBeam_Use =
{
    if (self.spawnflags & EBEAM_TOGGLE)
    {
        if (self.ebeam_active)
        {
            // Stop and cancel reactivation entirely (TOGGLE off).
            self.ebeam_active = 0;
            self.nextthink    = 0;
            EnvBeam_MarkDirty();
        }
        else
            EnvBeam_Activate();
        return;
    }

    // No TOGGLE: trigger only kicks an inactive beam back on; an
    // active beam ignores the trigger (matches HL — "the beam seems
    // to loop indefinitely regardless of further triggerings").
    if (!self.ebeam_active)
        EnvBeam_Activate();
};

/*QUAKED env_beam (.4 .8 .8) (-4 -4 -4) (4 4 4) START_ON TOGGLE RANDOM_STRIKE RING START_SPARKS END_SPARKS DECAL_END SHADE_START SHADE_END
HL/GoldSrc-style sprite beam between two named entities.

"LightningStart"  Start entity targetname.  Empty = anchor on self;
                  if both empty, beam picks a random wall pair.
"LightningEnd"    End entity targetname.  Empty = random wall within
                  Radius from the start.
"renderamt"       Brightness 0..255 (alpha).
"rendercolor"     Beam RGB.
"Radius"          Random-target search distance.
"life"            Active seconds (<=0.1 = forever).
"BoltWidth"       Width in 0.1 units (HL convention).
"NoiseAmplitude"  Path jitter amplitude 0..255.
"texture"         Sprite path (e.g. sprites/laserbeam.spr).
"TextureScroll"   Scroll speed 0..100.
"framestart"      Initial animation frame.
"StrikeTime"      Seconds between deactivation and reactivation.
"damage"          DPS along the straight start->end line.

START_ON       Active at map load.
TOGGLE         Re-trigger to stop the beam entirely.
RANDOM_STRIKE  Jitter life and StrikeTime ±50%.
RING           Render as a horizontal ring rather than a line.
START_SPARKS   Emit sparks at the start point.
END_SPARKS     Emit sparks at the end point.
DECAL_END      Accepted, currently unused (matches HL).
SHADE_START    Beam alpha fades toward the start.
SHADE_END      Beam alpha fades toward the end.  Ignored if SHADE_START
               is also set.
*/
void() env_beam =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = EnvBeam_Use;

    // Casing fallback: if the canonical (HL-spec) field is empty
    // but the lowercase variant has content, copy it over.
    if (self.LightningStart == "" && self.lightningstart != "")
        self.LightningStart = self.lightningstart;
    if (self.LightningEnd == "" && self.lightningend != "")
        self.LightningEnd = self.lightningend;

    if (cvar("sv_debug_env_beam"))
        dprint(sprintf("[env_beam] spawn targetname=\"%s\" LightningStart=\"%s\" LightningEnd=\"%s\" spawnflags=%g\n",
                       self.targetname, self.LightningStart, self.LightningEnd, self.spawnflags));

    // Defaults — HL .fgd doesn't supply some of these so the parser
    // leaves them at 0; we pick sensible values that match HL behaviour.
    if (self.renderamt == 0)      self.renderamt = 200;
    if (self.rendercolor == '0 0 0') self.rendercolor = '255 255 255';
    if (self.BoltWidth == 0)      self.BoltWidth = 16;       // 1.6 world units
    if (self.Radius == 0)         self.Radius = 256;

    // Precache the sprite for the CSQC handler.  precache_model in
    // FTE SSQC returns the path string (not a modelindex); use
    // getmodelindex to resolve the short index we ship to the
    // client, which maps the same way on both sides.
    if (self.texture != "")
    {
        precache_model(self.texture);
        self.ebeam_sprite_index = getmodelindex(self.texture);
    }
    else
        self.ebeam_sprite_index = 0;

    // Always-broadcast SendEntity (PVS-bypass).  Beams are typically
    // long-range visuals — gating on PVS would pop them in/out as the
    // player moves.  PVSF_NOREMOVE retains the cached state on the
    // client even if the server briefly stops sending updates.
    self.pvsflags  = PVSF_USEPHS | PVSF_NOREMOVE;
    self.SendEntity = EnvBeam_SendEntity;
    self.SendFlags  = 1;

    // Seed positions for the FIRST snapshot the engine sends before
    // EnvBeam_Activate ever runs (covers the case where the entity is
    // visible to a connecting client BEFORE the START_ON deferred
    // activation fires).
    self.ebeam_start_pos = self.origin;
    self.ebeam_end_pos   = self.origin;

    // START_ON: activate after a short delay so every entity in the
    // map has been spawned + linked (LightningStart/End targets need
    // to be findable by then).
    if (self.spawnflags & EBEAM_START_ON)
    {
        self.think     = EnvBeam_Activate;
        self.nextthink = time + 0.2;
    }
};
