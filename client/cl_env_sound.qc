//
// cl_env_sound.qc - GoldSrc env_sound listener/reverb support
//
// env_sound is not a sound emitter.  It is a room-state trigger: when
// the listener enters a point's radius, that room type remains active
// until another env_sound changes it.  FTE exposes the needed audio
// listener hook only in CSQC, so SSQC replicates the points and CSQC
// applies the selected reverb slot each frame.
//

const float ENV_SOUND_MAX_ROOMTYPE = 28;
const float ENV_SOUND_REVERB_BASE  = 32;

entity csqc_env_sound_list;
float  csqc_env_sound_current_roomtype;
float  csqc_env_sound_last_slot;
float  csqc_env_sound_had_listener;
float  csqc_env_sound_reverbs_ready;

.entity env_sound_next;
.float  env_sound_linked;
.float  env_sound_roomtype;
.float  env_sound_radius;

float(float roomtype) CSQC_EnvSound_Slot =
{
    if (roomtype <= 0)
        return 0;
    if (roomtype > ENV_SOUND_MAX_ROOMTYPE)
        roomtype = ENV_SOUND_MAX_ROOMTYPE;
    return ENV_SOUND_REVERB_BASE + roomtype;
};

// HOW WET THE ROOM IS, 0..1.  Everything below was authored at flGain 1.0, which
// is EFX's "the reverb is as loud as the dry signal" - and that is a great deal
// wetter than GoldSrc's DSP ever was.  On a map that leans on env_sound (the They
// Hunger episodes put one in nearly every room) the result was an echo strong
// enough to make gunfire and speech hard to place, which is the reported "world
// echo sound effect for specific locations is WAY too intense".
//
// A scale rather than 28 retuned tables, because the RELATIVE character of the
// rooms was right - a tunnel does trail longer than a booth - and only the
// overall wet level was wrong.  Scaling the three gain terms together keeps each
// room's shape and moves all of them down by the same amount.
//
// 0.4 by default.  1 restores the old behaviour exactly; 0 turns reverb off
// without having to unhook the listener.
const float ENV_SOUND_REVERB_STRENGTH_DEFAULT = 0.4;

float() CSQC_EnvSound_Strength =
{
    if (cvar_string("snd_env_reverb_strength") == "")
        return ENV_SOUND_REVERB_STRENGTH_DEFAULT;
    return bound(0, cvar("snd_env_reverb_strength"), 1);
};

void(float roomtype, float density, float diffusion, float gainhf,
     float decay, float decayhf, float reflections, float reflectdelay,
     float late, float latedelay, float echotime, float echodepth,
     float modtime, float moddepth) CSQC_EnvSound_DefineReverb =
{
    reverbinfo_t ri;
    float wet = CSQC_EnvSound_Strength();

    ri.flDensity = density;
    ri.flDiffusion = diffusion;
    ri.flGain = wet;
    ri.flGainHF = gainhf;
    ri.flGainLF = 1.0;
    ri.flDecayTime = decay;
    ri.flDecayHFRatio = decayhf;
    ri.flDecayLFRatio = 1.0;
    ri.flReflectionsGain = reflections * wet;
    ri.flReflectionsDelay = reflectdelay;
    ri.flReflectionsPan = '0 0 0';
    ri.flLateReverbGain = late * wet;
    ri.flLateReverbDelay = latedelay;
    ri.flLateReverbPan = '0 0 0';
    ri.flEchoTime = echotime;
    ri.flEchoDepth = echodepth;
    ri.flModulationTime = modtime;
    ri.flModulationDepth = moddepth;
    ri.flAirAbsorptionGainHF = 0.994;
    ri.flHFReference = 5000;
    ri.flLFReference = 250;
    ri.flRoomRolloffFactor = 0;
    ri.iDecayHFLimit = 1i;

    setup_reverb(CSQC_EnvSound_Slot(roomtype), &ri, sizeof(ri));
};

// The strength the 28 slots were last built at.  setup_reverb bakes the numbers
// into the slot, so changing the cvar has to rebuild them - otherwise the knob
// appears to do nothing until the next map.
float csqc_env_sound_built_strength;

void() CSQC_EnvSound_InitReverbs =
{
    float wet = CSQC_EnvSound_Strength();
    if (csqc_env_sound_reverbs_ready && wet == csqc_env_sound_built_strength)
        return;
    csqc_env_sound_reverbs_ready = 1;
    csqc_env_sound_built_strength = wet;

    // These are intentionally GoldSrc-flavoured approximations, not a
    // claim of byte-identical EAX.  They preserve the useful mapper
    // categories: metal rings, tunnels trail, water muffles, and the
    // "weirdo" rooms get obvious modulation.
    CSQC_EnvSound_DefineReverb( 1, 1.00, 0.90, 0.83, 1.20, 0.83, 0.05, 0.010, 0.70, 0.020, 0.10, 0.04, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 2, 0.85, 0.70, 0.90, 1.10, 1.15, 0.18, 0.012, 0.85, 0.018, 0.09, 0.08, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 3, 0.90, 0.72, 0.88, 1.80, 1.25, 0.26, 0.018, 1.10, 0.026, 0.10, 0.10, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 4, 0.95, 0.75, 0.86, 2.80, 1.35, 0.36, 0.026, 1.45, 0.038, 0.11, 0.13, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 5, 0.70, 0.55, 0.70, 2.00, 0.65, 0.35, 0.040, 0.90, 0.045, 0.15, 0.25, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 6, 0.72, 0.55, 0.66, 3.40, 0.62, 0.42, 0.055, 1.10, 0.060, 0.18, 0.32, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 7, 0.75, 0.58, 0.62, 5.40, 0.58, 0.50, 0.070, 1.35, 0.078, 0.22, 0.40, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 8, 0.95, 0.80, 0.78, 1.50, 0.78, 0.16, 0.016, 0.95, 0.026, 0.10, 0.08, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb( 9, 0.98, 0.82, 0.76, 2.40, 0.76, 0.22, 0.022, 1.20, 0.034, 0.12, 0.10, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(10, 1.00, 0.84, 0.74, 3.60, 0.74, 0.28, 0.030, 1.55, 0.046, 0.14, 0.12, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(11, 1.00, 0.92, 0.98, 1.20, 1.05, 0.08, 0.010, 0.70, 0.020, 0.09, 0.04, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(12, 1.00, 0.94, 1.00, 2.00, 1.10, 0.12, 0.016, 0.92, 0.028, 0.10, 0.06, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(13, 1.00, 0.96, 1.00, 3.00, 1.15, 0.16, 0.022, 1.15, 0.038, 0.11, 0.08, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(14, 0.65, 0.55, 0.20, 0.70, 0.35, 0.05, 0.006, 0.45, 0.014, 0.09, 0.05, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(15, 0.70, 0.58, 0.17, 1.20, 0.35, 0.14, 0.020, 0.70, 0.036, 0.13, 0.18, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(16, 0.75, 0.60, 0.15, 2.00, 0.34, 0.22, 0.034, 0.95, 0.052, 0.16, 0.24, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(17, 0.92, 0.70, 0.62, 1.10, 0.70, 0.18, 0.012, 0.80, 0.022, 0.09, 0.07, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(18, 0.96, 0.72, 0.58, 1.80, 0.68, 0.25, 0.020, 1.05, 0.032, 0.11, 0.10, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(19, 1.00, 0.74, 0.55, 2.70, 0.66, 0.32, 0.028, 1.30, 0.044, 0.13, 0.12, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(20, 1.00, 0.90, 0.80, 3.00, 0.85, 0.20, 0.030, 1.25, 0.050, 0.14, 0.14, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(21, 1.00, 0.92, 0.78, 4.50, 0.82, 0.28, 0.040, 1.60, 0.065, 0.16, 0.18, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(22, 1.00, 0.94, 0.76, 6.00, 0.80, 0.36, 0.052, 2.00, 0.085, 0.18, 0.22, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(23, 0.88, 0.78, 0.70, 2.50, 0.75, 0.32, 0.024, 1.25, 0.040, 0.12, 0.18, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(24, 0.92, 0.80, 0.66, 4.00, 0.70, 0.40, 0.034, 1.65, 0.060, 0.15, 0.25, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(25, 0.96, 0.82, 0.62, 7.00, 0.66, 0.50, 0.050, 2.20, 0.085, 0.20, 0.35, 0.25, 0.00);
    CSQC_EnvSound_DefineReverb(26, 0.90, 0.70, 0.90, 1.30, 1.35, 0.18, 0.014, 0.90, 0.024, 0.10, 0.10, 0.35, 0.20);
    CSQC_EnvSound_DefineReverb(27, 0.92, 0.72, 0.95, 2.30, 1.55, 0.30, 0.022, 1.25, 0.038, 0.12, 0.20, 0.45, 0.45);
    CSQC_EnvSound_DefineReverb(28, 0.95, 0.74, 1.00, 3.60, 1.75, 0.45, 0.034, 1.65, 0.060, 0.16, 0.32, 0.60, 0.80);
};

void() CSQC_EnvSound_Link =
{
    if (self.env_sound_linked)
        return;

    self.env_sound_next = csqc_env_sound_list;
    csqc_env_sound_list = self;
    self.env_sound_linked = 1;
};

void() CSQC_EnvSound_Remove =
{
    entity prev;
    entity cur;

    if (!self.env_sound_linked)
        return;

    if (csqc_env_sound_list == self)
        csqc_env_sound_list = self.env_sound_next;
    else
    {
        prev = csqc_env_sound_list;
        while (prev)
        {
            cur = prev.env_sound_next;
            if (cur == self)
            {
                prev.env_sound_next = self.env_sound_next;
                break;
            }
            prev = cur;
        }
    }

    self.env_sound_next = world;
    self.env_sound_linked = 0;
};

void() CSQC_EnvSound_Reset =
{
    csqc_env_sound_list = world;
    csqc_env_sound_current_roomtype = 0;
    csqc_env_sound_last_slot = 0;
    csqc_env_sound_had_listener = 0;
};

void(float isnew) CSQC_EnvSound_Update =
{
    vector org;

    org_x = readcoord();
    org_y = readcoord();
    org_z = readcoord();

    setorigin(self, org);
    self.env_sound_radius = readcoord();
    self.env_sound_roomtype = readbyte();

    if (self.env_sound_roomtype < 0) self.env_sound_roomtype = 0;
    if (self.env_sound_roomtype > ENV_SOUND_MAX_ROOMTYPE)
        self.env_sound_roomtype = ENV_SOUND_MAX_ROOMTYPE;

    self.classname = "csqc_env_sound";
    self.solid = SOLID_NOT;
    self.drawmask = 0;

    CSQC_EnvSound_Link();
};

void() CSQC_EnvSound_UpdateListener =
{
    entity e;
    entity best = world;
    vector org;
    vector ang;
    float best_dist = 999999999;
    float dist;
    float slot;

    if (!csqc_env_sound_list && !csqc_env_sound_current_roomtype && !csqc_env_sound_had_listener)
        return;

    CSQC_EnvSound_InitReverbs();

    org = (vector)getproperty(VF_ORIGIN);

    for (e = csqc_env_sound_list; e; e = e.env_sound_next)
    {
        if (e.env_sound_radius <= 0)
            continue;

        dist = vlen(e.origin - org);
        if (dist <= e.env_sound_radius && dist < best_dist)
        {
            best = e;
            best_dist = dist;
        }
    }

    if (best)
        csqc_env_sound_current_roomtype = best.env_sound_roomtype;

    slot = CSQC_EnvSound_Slot(csqc_env_sound_current_roomtype);
    if (slot <= 0 && !csqc_env_sound_had_listener)
        return;

    ang = (vector)getproperty(VF_ANGLES);
    makevectors(ang);
    SetListener(org, v_forward, v_right, v_up, slot);

    csqc_env_sound_last_slot = slot;
    csqc_env_sound_had_listener = 1;
};
