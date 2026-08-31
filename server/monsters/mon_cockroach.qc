// server/monsters/mon_cockroach.qc
// ----------------------------------------------------------------------------
// monster_cockroach.  283 placements across 32 maps - the 9th most placed class
// in the corpus, and the cheapest real AI in the whole programme.
//
// roach.mdl is TWO sequences: run_1 (tagged ACT_WALK) and run_2 (tagged
// ACT_IDLE).  No attack activity, no death animation, no events, no bone
// controllers.  Half-Life's CRoach matches that - it has no attack of any kind,
// one hit point, and its entire behaviour is "scurry, and bolt when disturbed".
//
// The interesting part is what it must NOT do.  With no attack ranges set, the
// generic ladder in AI_SelectSchedule falls through to SCHED_CHASE_ENEMY, and a
// cockroach sprinting at the player is unmistakably a bug.  So the class returns
// SCHED_FLEE_ENEMY from its selector - which is why that schedule exists.  The
// scared-scientist behaviour in W4 wants exactly the same thing.
// ----------------------------------------------------------------------------

const float ROACH_HEALTH_DEFAULT = 1;	// HL: one hit, always

// The roach DOES have sounds, and the note that used to sit here saying it did
// not was simply wrong - CRoach precaches three, and all three are present in
// both the Half-Life and the Sven Co-op mounts: roach/rch_walk.wav,
// roach/rch_smash.wav and roach/rch_die.wav.  The smash is the one that matters,
// because it is the feedback for the interaction below.
const string SND_ROACH_SMASH = "roach/rch_smash.wav";
const string SND_ROACH_DIE   = "roach/rch_die.wav";

void() Cockroach_Precache =
{
    precache_model("models/roach.mdl");
    precache_sound(SND_ROACH_SMASH);
    precache_sound(SND_ROACH_DIE);
};

// A DEAD ROACH STAYS PUT AND STOPS MOVING, and getting BOTH of those at once is
// the whole difficulty.
//
// Half-Life's CRoach::Killed (roach.cpp:161-183) calls UTIL_Remove, so a squashed
// roach in GoldSrc leaves nothing behind.  That was implemented literally in the
// last patch and the report back was "now they vanish when stepped on, I don't
// want them to vanish" - so the SDK's answer is not the wanted one here, and the
// wanted one has to solve the problem removal was solving.
//
// That problem is real: roach.mdl carries NO death sequence, only run_1 and run_2,
// so a corpse left on the generic path falls back to its idle cycle and lies there
// scurrying on the spot forever - the reported "their little antennae keep moving".
//
// .animrate is the way out.  It is Half-Life's own pev->framerate, networked under
// PEXT2_FRAMERATE (sv_defs.qc:428), and it multiplies playback speed on the CLIENT,
// which is where the runaway cycle actually lives - the server's own sequence clock
// stopped the moment the schedule did.
//
// THE VALUE IS NOT ARBITRARY.  The wire encoding is (rate - 1) * 64 truncated to a
// short (sv_ents.c:3695) and QC 0 is reserved to mean "normal speed" (:3694), so
// zero cannot be asked for directly.  -0.001 encodes to (int)(-64.064) = -64, which
// the client decodes as exactly -64/64 + 1 = 0.0 (cl_ents.c:4418).  Frozen, not
// merely slow, and it costs the two payload bytes only on the roaches that die.
const float ROACH_FREEZE_RATE = -0.001;

// A think that exists only to stay safely callable.  Cockroach_Death runs from
// INSIDE AI_Think (TASK_DIE, sv_ai_core.qc:2548), and the tail of that function
// re-arms .nextthink on the way out - so clearing .think to __NULL__ there would
// leave the engine with a scheduled think and no function to call, which is a
// runtime fault rather than a quiet no-op.  This disarms it again on the one
// frame that can happen and then never runs.
void() Cockroach_DeadThink =
{
    self.nextthink = 0;
};

void() Cockroach_Death =
{
    // roach.cpp:165-173 - one death in five is the voice, the rest is the shell
    // cracking.  Cockroach_Touch below owns the crack for a SQUASH because that
    // has to be heard on contact, and clears .ai_snd_die to say so; this is the
    // path for a roach that was shot or blown up.
    if (self.ai_snd_die != "")
    {
        if (random() < 0.2)
            AI_SoundEx(self, CHAN_VOICE, SND_ROACH_DIE, 0.8, ATTN_NORM,
                       80 + floor(random() * 40), 0);
        else
            AI_SoundEx(self, CHAN_BODY, SND_ROACH_SMASH, 0.7, ATTN_NORM,
                       80 + floor(random() * 40), 0);
    }

    // Off the monster chain and out of its spawner's child budget immediately -
    // the body is scenery from here on, and a corpse that keeps holding a
    // squadmaker slot starves the maker exactly as Monster_Killed's own comment
    // (sv_monsters.qc:474-478) describes.
    Monster_Teardown(self);

    self.takedamage = DAMAGE_NO;
    self.flags      = self.flags - (self.flags & FL_MONSTER);
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    self.velocity   = '0 0 0';
    self.avelocity  = '0 0 0';
    self.think      = Cockroach_DeadThink;
    self.nextthink  = 0;
    self.touch      = __NULL__;
    self.animrate   = ROACH_FREEZE_RATE;
    // deadflag stays DEAD_DEAD rather than being cleared back to DEAD_NO: this
    // body is not going to be freed this frame any more, so anything that finds
    // it later has to be able to tell it is a corpse.
    self.deadflag   = DEAD_DEAD;
    setorigin(self, self.origin);   // relink at the final resting place
};

// Half-Life's CRoach::Touch: a MOVING player who touches a roach squashes it,
// full stop.  Not "steps on it" - any contact at any speed, which is why you can
// never quite walk through a group of them without killing some.
//
// This also fixes something that looks unrelated and is not.  A roach is a solid
// 2x2x1 box, so a player who walks onto one stands ON it, one unit up - and CSQC
// prediction does not have it, so the client predicts standing on the floor while
// the server has the player a unit higher.  That disagreement is the camera
// sinking into the ground.  In Half-Life it cannot happen, because the roach is
// dead before the player is ever supported by it, and now it cannot happen here
// either: the fix for "I should squash it" and the fix for "my view sinks" are
// the same three lines.
void() Cockroach_Touch =
{
    if (self.health <= 0 || self.ai_state == MS_DEAD)
        return;
    if (other.classname != "player")
        return;
    // HL tests velocity exactly this way: a player standing perfectly still on a
    // roach does not crush it.  Keeping the test means a roach that scurries into
    // a motionless player survives, which is the behaviour people remember.
    if (other.velocity == '0 0 0')
        return;

    // The squash is louder and more immediate than the generic death voice, so it
    // plays here AND the death path is told to keep quiet - otherwise a crushed
    // roach makes two noises a tenth of a second apart.
    AI_SoundEx(self, CHAN_BODY, SND_ROACH_SMASH, 0.7, ATTN_NORM, 80 + floor(random() * 40), 0);
    self.ai_snd_die = "";

    // roach.cpp:94-98 - the mark on the floor.  Half-Life traces 24 units DOWN
    // from 8 above the roach and stamps DECAL_YBLOOD1 + 0..5 there, and its own
    // comment says why the violence filter does not apply: "This isn't really
    // blood."  The trace matters as much as the decal - a roach squashed on a
    // stair tread must mark the tread, not the floor two steps below - so it is
    // kept even though the effect this engine has to offer is a flesh burst
    // rather than a numbered GoldSrc decal.
    vector spot = self.origin + '0 0 8';
    traceline(spot, spot - '0 0 24', MOVE_NOMONSTERS, self);
    if (trace_fraction < 1)
        // TWO THINGS WERE WRONG HERE, and between them the one person who could
        // possibly have seen this effect was the only one excluded from it.
        //
        // The fifth argument is `shooter`, and W_ImpactEffectSend deliberately
        // skips it (sv_weapons.qc:1197) on the grounds that a shooter predicted
        // their own impact client-side.  Passing `other` - the player who just
        // trod on the roach - meant the squasher got nothing, everyone ELSE in
        // the PVS got the splat, and nothing client-side predicts a squash to
        // make up for it.  The function's own comment says `world` is what to
        // pass when no client predicted the event; that is this case exactly.
        //
        // The point is lifted a little off the surface as well.  The decal
        // sprayer traces along -normal from the point it is given
        // (cl_bloodsplat.qc:329), and this point sits exactly ON the floor, so
        // every one of those traces started inside the surface it was trying to
        // mark and stamped nothing.  Two units of clearance is enough for them
        // to land, which is what finally puts a mark under a squashed roach.
        W_ImpactEffectSend(trace_endpos + trace_plane_normal * 2,
                           trace_plane_normal, IMPACT_MAT_FLESH,
                           world, world, 1);
    self.health = 0;
    Monster_Killed();		// self is already the roach
};

// ---------------------------------------------------------------------------
// light
// ---------------------------------------------------------------------------
// "cockroach doesn't run from flash lights."
//
// Half-Life's roach is the ONE class in the SDK whose primary sense is light
// rather than sight or sound.  CRoach::MonsterThink samples GETENTITYILLUM every
// think and compares it with m_flLastLightLevel; a rise of more than 10 sends it
// straight into its "scared by light" state (roach.cpp:206-224), and CRoach::Look
// is a bare 150-unit proximity sphere with the visibility trace commented out.
// That is why a roach in GoldSrc scatters the instant you light it and only
// wanders off if you get close.
//
// GETENTITYILLUM HAS NO EQUIVALENT HERE and cannot get one cheaply: FTE's
// lightmap sampling is a client-side renderer concern, the map's own lights are
// baked, and the light this actually needs to notice is a CSQC dlight that the
// server has never been told about.  So the fact is imported instead of measured
// — .player_flashlight, pushed by the owning client on the toggle edge — and the
// "is it ON me" half is done geometrically: inside the beam cone, inside range,
// and with a clear line.  That is the same three-part test the renderer's own
// spotlight does, which is what makes the reaction line up with what the player
// can actually see lit.
//
// Range is deliberately WIDER than .ai_sight (160): a torch reaches much further
// than a roach's notice-you radius, and being pinned in a beam from across the
// cellar is the behaviour being asked for.  Cone is a little wider than the
// default cl_flashlight_fov (50) so the edge of the beam counts too.
const float ROACH_LIGHT_RANGE = 600;
const float ROACH_LIGHT_COS   = 0.83;	// ~34 degrees off-axis, i.e. a ~68 deg cone
// How long one flash keeps it running.  HL latches a state rather than a timer,
// but a timer is what stops a roach at the very edge of the cone flickering
// between fleeing and idling as the player's aim wobbles.
const float ROACH_LIGHT_PANIC = 3.0;

.float roach_lit_until;

void() Cockroach_Tick =
{
    if (self.health <= 0 || self.ai_state == MS_DEAD)
        return;
    if (time < self.roach_lit_until)
        return;			// already running; no need to re-test every tick

    vector rc = self.origin + (self.mins + self.maxs) * 0.5;

    entity p = player_chain_head;
    while (p)
    {
        if (p.player_flashlight && !p.is_dead && p.health > 0)
        {
            vector eye = p.origin + p.view_ofs;
            vector d   = rc - eye;
            float  len = vlen(d);
            if (len > 1 && len <= ROACH_LIGHT_RANGE)
            {
                makevectors(p.v_angle);
                if ((d * (1 / len)) * v_forward >= ROACH_LIGHT_COS)
                {
                    traceline(eye, rc, MOVE_NOMONSTERS, p);
                    if (trace_fraction == 1 || trace_ent == self)
                    {
                        self.roach_lit_until = time + ROACH_LIGHT_PANIC;
                        self.ai_enemy        = p;
                        if (self.ai_state == MS_IDLE || self.ai_state == MS_NONE)
                            self.ai_state = MS_ALERT;
                        break;
                    }
                }
            }
        }
        p = p.player_chain_next;
    }
};

// Bolt on sight, always.  Returning a schedule here overrides the generic
// ladder entirely, so a roach can never enter the combat branch.
float() Cockroach_SelectSched =
{
    if (self.ai_state == MS_DEAD)
        return SCHED_NONE;		// let the generic ladder run the death path

    // Lit by a torch — run, whether or not the ordinary sight test would have
    // noticed the player at this range.  Ahead of the sight branch because it is
    // the stronger stimulus and because at 600 units the sight test cannot fire.
    if (time < self.roach_lit_until && self.ai_enemy)
        return SCHED_FLEE_ENEMY;

    if (self.ai_enemy)
        if (self.ai_cond & (COND_SEE_ENEMY | COND_DAMAGE | COND_PROVOKED))
            return SCHED_FLEE_ENEMY;

    return SCHED_NONE;
};

void(entity m) Cockroach_ClassInit =
{
    m.ai_class = CLASS_INSECT;

    // roach/rch_die.wav was precached by this file and played by nothing.  HL
    // splits the two: one death in five is the voice, the rest is the shell
    // cracking (roach.cpp:165-173), and Cockroach_Touch owns the crack because a
    // squashed roach must make its noise on contact rather than a tick later.
    // Pitch 80-119 is HL's own and is most of what stops 283 identical roaches
    // sounding like one sample.
    m.ai_snd_die   = SND_ROACH_DIE;
    m.ai_snd_pitch = 20;

    // No attacks at all.  Both ranges stay 0, so COND_CAN_MELEE1/RANGE1 can
    // never be set and every attack schedule is unreachable for this class.
    m.ai_melee_range = 0;
    m.ai_range_range = 0;

    // Fast and twitchy.  The model has one gait shared between both activities,
    // so walk and run must match or the cycle skates - the same rule as the
    // zombie, for the same reason.
    //
    // Jittered per roach, which is not cosmetic.  A monstermaker emits every child
    // on its own origin, and th_ep1_01 has six of them asking for up to seven
    // roaches each - so seven identical monsters start at one point with identical
    // speed and identical schedules, and they move as a single seven-legged blob
    // forever.  Two units either side of 90 is enough for them to come apart
    // within a second or two.
    // roach.mdl [0] "run" (tagged ACT_WALK) 7f @30fps -> 116.1, kept as the
    // centre of the jitter rather than replacing it: the per-roach variation is
    // what stops a nest moving in lockstep, and that was the reported bug.
    m.ai_speed_walk = 108 + random() * 16;
    m.ai_speed_run  = m.ai_speed_walk;

    // 360 was "roaches turn on the spot instantly", and instantly is precisely the
    // problem.  After the x2 in AI_ChangeYaw that is 72 degrees in a single 10 Hz
    // tick, and FTE stops interpolating an entity entirely on any packet where its
    // facing moved more than 45 (cl_ents.c:4809-4817) - it hard-assigns origin AND
    // angles instead.  A grunt survives that because it barely moves a fraction of
    // its own width per tick; a 2-unit roach covering ~11 units per tick reads as
    // flashing between two places, which is the reported bug.
    //
    // 120 is Half-Life's own number (CRoach::SetYawSpeed, roach.cpp:107-114) and
    // gives 24 degrees per tick, comfortably under the cliff.  AI_YAW_MAXSTEP now
    // backstops every class, but a value the SDK never used is worth correcting at
    // the source as well as clamping downstream.
    m.ai_yaw_speed  = 120;

    // roach.cpp:425-430: CRoach::Look is a 150-unit SPHERE with the visibility
    // trace commented out, sampled one tick in four.  Ours inherited the global
    // sv_ai_sight (2048) and a 120-degree cone, so a roach fled from a player it
    // could see across the entire church and never did anything else.  A cockroach
    // is supposed to bolt when you get near it, not to spend the map running.
    //
    // -1 is 360 degrees (AI_InViewCone treats it as VIEW_FIELD_FULL), which is HL's
    // for this class - it has no front.
    m.ai_sight      = 160;
    m.ai_fov        = -1;

    m.ai_selectsched = Cockroach_SelectSched;
    m.ai_tick        = Cockroach_Tick;
    m.touch          = Cockroach_Touch;
    // roach.cpp:161-183 - a dead roach is REMOVED, it does not become a corpse.
    m.ai_death       = Cockroach_Death;

    // Break up the pile at birth as well as over time.  ClassInit runs BEFORE
    // AI_PlaceOnFloor (see AI_Spawn), so an offset applied here is dropped onto
    // the floor for free and cannot leave a roach hovering.
    //
    // Traced, not assumed: an untraced offset would push roaches through the wall
    // of whatever vent or crate the mapper aimed the spawner into, which is a
    // worse bug than the pile.  If the trace does not clear, this one stays put
    // and the speed jitter separates it instead.
    makevectors('0 1 0' * (random() * 360));
    vector spot = m.origin + v_forward * (12 + random() * 28);
    traceline(m.origin + '0 0 4', spot + '0 0 4', MOVE_NOMONSTERS, m);
    if (trace_fraction == 1)
        setorigin(m, spot);

    if (m.bloodcolor == 0)
        m.bloodcolor = 195;			// HL BLOOD_COLOR_YELLOW for insects
};

float() Cockroach_DefaultHealth =
{
    float h = cvar("sv_ai_cockroach_health");
    if (h <= 0)
        h = ROACH_HEALTH_DEFAULT;
    return h;
};
