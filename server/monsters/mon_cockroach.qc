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

    sound(self, CHAN_BODY, SND_ROACH_SMASH, 1, ATTN_NORM);
    self.health = 0;
    Monster_Killed();		// self is already the roach
};

// Bolt on sight, always.  Returning a schedule here overrides the generic
// ladder entirely, so a roach can never enter the combat branch.
float() Cockroach_SelectSched =
{
    if (self.ai_state == MS_DEAD)
        return SCHED_NONE;		// let the generic ladder run the death path

    if (self.ai_enemy)
        if (self.ai_cond & (COND_SEE_ENEMY | COND_DAMAGE | COND_PROVOKED))
            return SCHED_FLEE_ENEMY;

    return SCHED_NONE;
};

void(entity m) Cockroach_ClassInit =
{
    m.ai_class = CLASS_INSECT;

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
    m.ai_yaw_speed  = 360;			// roaches turn on the spot instantly

    m.ai_selectsched = Cockroach_SelectSched;
    m.touch          = Cockroach_Touch;

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

    if (m.bloodcolor <= 0)
        m.bloodcolor = 195;			// HL BLOOD_COLOR_YELLOW for insects
};

float() Cockroach_DefaultHealth =
{
    float h = cvar("sv_ai_cockroach_health");
    if (h <= 0)
        h = ROACH_HEALTH_DEFAULT;
    return h;
};
