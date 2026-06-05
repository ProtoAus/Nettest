//
//  sv_env_spark.qc  –  env_spark  (HL/GoldSrc point entity)
//
//  Periodic spark emitter — produces a sparkle visual + sound at
//  random intervals.  Reuses the same CSQC_EVENT_BUTTON_SPARK
//  particle path the SPARKS-flagged func_button already drives, so
//  the visual + audio match across both entities.
//
//  Keys (HL parity):
//    "MaxDelay"    upper bound on the random interval between
//                  sparks, seconds.  Lower bound is fixed at
//                  ~0.1 s so the rate stays watchable even at
//                  small MaxDelay values.  Default 1.5 s.
//    "targetname"  trigger identifier (required for TOGGLE flag).
//    "angles"      "Seemingly unused" per HL docs — we ignore.
//
//  Spawnflags (HL bit layout):
//    32  SF_SPARK_TOGGLE     .use toggles sparking on/off
//                            (otherwise always-on).
//    64  SF_SPARK_START_ON   sparks start on (only meaningful when
//                            TOGGLE is also set).
//
//  Visual / audio:
//    - Wire: SVC_CGAMEPACKET + CSQC_EVENT_BUTTON_SPARK with origin
//      + outward-normal bytes.  CSQC fires the metal-impact
//      pointparticles burst — same effect as the sparker button.
//    - Sound: per emit, a randomly-chosen
//      sounds/debris/break_eletronichlN.wav sample at low volume
//      (matches sv_buttons.qc sparker logic — already precached
//      in sh_customdefs.qc).
//

const float SF_SPARK_TOGGLE   = 32;
const float SF_SPARK_START_ON = 64;

.float MaxDelay;            // map key — upper bound on interval
.float spark_active;        // 1 = currently spitting sparks

// Convenience — outward normal from this emitter.  HL uses world
// +Z (up) as the default spark direction since the emitter has no
// inherent facing.  Mappers can prepend a `+forward` orientation
// hint later if needed.
const vector ENV_SPARK_OUTWARD = '0 0 1';

void() env_spark_think;

void() env_spark_emit_once =
{
    // Spark particle event — same wire format the sparker button
    // sends.  Origin + outward as 3 normal-coded bytes (1..255
    // biased so 128 = 0).  CSQC reverses + dispatches particles.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_BUTTON_SPARK);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z);
    WriteByte(MSG_MULTICAST, bound(0, rint(ENV_SPARK_OUTWARD_x * 127 + 128), 255));
    WriteByte(MSG_MULTICAST, bound(0, rint(ENV_SPARK_OUTWARD_y * 127 + 128), 255));
    WriteByte(MSG_MULTICAST, bound(0, rint(ENV_SPARK_OUTWARD_z * 127 + 128), 255));
    multicast(self.origin, MULTICAST_PVS);

    // Companion sound — same pool the sparker button uses.  Low
    // volume so a long-running sparker doesn't dominate ambience.
    string pick;
    if (random() < 0.5)
        pick = "sounds/debris/break_eletronichl1.wav";
    else
        pick = "sounds/debris/break_eletronichl3.wav";
    sound(self, CHAN_AUTO, pick, 0.2, ATTN_NORM);
};

void() env_spark_think =
{
    if (!self.spark_active)
    {
        // Toggled off — sleep until use re-enables us.
        self.think     = __NULL__;
        self.nextthink = 0;
        return;
    }

    env_spark_emit_once();

    // Random interval up to MaxDelay, floored at 0.1 s so the
    // particle pulse stays watchable when the mapper sets a small
    // MaxDelay.  HL uses a similar floor.
    float max_d = self.MaxDelay;
    if (max_d <= 0) max_d = 1.5;
    self.nextthink = time + 0.1 + random() * max_d;
};

void() env_spark_use =
{
    // Only the TOGGLE spawnflag listens to .use.  Without it the
    // sparker is always-on regardless of triggers.
    if (!(self.spawnflags & SF_SPARK_TOGGLE))
        return;

    self.spark_active = self.spark_active ? 0 : 1;
    if (self.spark_active)
    {
        self.think     = env_spark_think;
        self.nextthink = time + 0.1;
    }
    else
    {
        self.think     = __NULL__;
        self.nextthink = 0;
    }
};

/*QUAKED env_spark (.5 .5 .5) (-8 -8 -8) (8 8 8) x x x x x TOGGLE START_ON
HL/GoldSrc-style periodic spark emitter.  Spawns a small particle
burst + spark sound at random intervals up to MaxDelay seconds.

"MaxDelay"    upper bound on interval (s).  Default 1.5.
"targetname"  trigger identifier.
*/
void() env_spark =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    setsize(self, '0 0 0', '0 0 0');

    self.use = env_spark_use;

    // Without TOGGLE, the entity is always-on regardless of START_ON.
    // With TOGGLE, START_ON determines initial state.
    float on_now;
    if (self.spawnflags & SF_SPARK_TOGGLE)
        on_now = (self.spawnflags & SF_SPARK_START_ON) ? 1 : 0;
    else
        on_now = 1;

    self.spark_active = on_now;
    if (on_now)
    {
        // Stagger the first emit so multiple env_sparks in the
        // same area don't all fire on the same frame.  Random
        // 0..MaxDelay seed.
        float max_d = self.MaxDelay;
        if (max_d <= 0) max_d = 1.5;
        self.think     = env_spark_think;
        self.nextthink = time + 0.1 + random() * max_d;
    }
};
