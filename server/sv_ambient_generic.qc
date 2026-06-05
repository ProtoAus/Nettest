//
// sv_ambient_generic.qc - HL/GoldSrc ambient_generic point entity
//
// Plays a sound at the entity's origin, attenuated by spawnflag-selected
// radius bands.  This supports the GoldSrc dynamic keys: presets, volume
// fades, pitch spin, LFO pitch/volume modulation, and incremental spinup.
//

const float AG_PLAY_EVERYWHERE = 1;
const float AG_SMALL_RADIUS    = 2;
const float AG_MEDIUM_RADIUS   = 4;
const float AG_LARGE_RADIUS    = 8;
const float AG_START_SILENT    = 16;
const float AG_NOT_TOGGLED     = 32;

const float AG_LFO_OFF = 0;
const float AG_LFO_SQR = 1;
const float AG_LFO_TRI = 2;
const float AG_LFO_RND = 3;

// Mapper-facing keys parsed by the BSP entity-block reader.
.float preset;
.float volstart;
.float fadein;
.float fadeout;
.float pitch;
.float pitchstart;
.float spinup;
.float spindown;
.float lfotype;
.float lforate;
.float lfomodpitch;
.float lfomodvol;
.float cspinup;

// Runtime state.
.float ag_active;
.float ag_attenuation;
.float ag_target_volume;
.float ag_target_pitch;
.float ag_cspin_count;

// Time-anchored transition state.
.float ag_t_start;
.float ag_vol_dur;
.float ag_pitch_dur;
.float ag_vol_from;
.float ag_vol_to;
.float ag_pitch_from;
.float ag_pitch_to;
.float ag_stop_at_end;

.float ag_current_volume;
.float ag_current_pitch;
.float ag_lfo_start;
.float ag_lfo_next_random;
.float ag_lfo_random;

// HL dynamics are 0..100 editor values.  100 maps to about 5 seconds.
const float AG_TIME_SCALE = 0.05;

float(float v, float lo, float hi) AmbientGeneric_Clamp =
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
};

float() AmbientGeneric_Attenuation =
{
    if (self.spawnflags & AG_PLAY_EVERYWHERE) return ATTN_NONE;
    if (self.spawnflags & AG_SMALL_RADIUS)    return 2.0;
    if (self.spawnflags & AG_MEDIUM_RADIUS)   return 1.25;
    if (self.spawnflags & AG_LARGE_RADIUS)    return 0.6;
    return ATTN_NORM;
};

string(string raw) AmbientGeneric_NormaliseSample =
{
    if (raw == "") return raw;
    if (substring(raw, 0, 1) == "!")
        return substring(raw, 1, -1);
    return raw;
};

void(float p_pitch, float p_pitchstart, float p_spinup, float p_spindown,
     float p_volume, float p_volstart, float p_fadein, float p_fadeout,
     float p_lfotype, float p_lforate, float p_lfomodpitch,
     float p_lfomodvol, float p_cspinup) AmbientGeneric_SetPreset =
{
    self.pitch = p_pitch;
    self.pitchstart = p_pitchstart;
    self.spinup = p_spinup;
    self.spindown = p_spindown;
    self.health = p_volume;
    self.volstart = p_volstart;
    self.fadein = p_fadein;
    self.fadeout = p_fadeout;
    self.lfotype = p_lfotype;
    self.lforate = p_lforate;
    self.lfomodpitch = p_lfomodpitch;
    self.lfomodvol = p_lfomodvol;
    self.cspinup = p_cspinup;
};

void() AmbientGeneric_ApplyPreset =
{
    switch (floor(self.preset + 0.5))
    {
    case 1:  AmbientGeneric_SetPreset(255, 75, 95, 95, 10, 1, 50, 95, 0, 0, 0, 0, 0); break;
    case 2:  AmbientGeneric_SetPreset(255, 85, 70, 88, 10, 1, 20, 88, 0, 0, 0, 0, 0); break;
    case 3:  AmbientGeneric_SetPreset(255, 100, 50, 75, 10, 1, 10, 75, 0, 0, 0, 0, 0); break;
    case 4:  AmbientGeneric_SetPreset(100, 100, 0, 0, 10, 1, 90, 90, 0, 0, 0, 0, 0); break;
    case 5:  AmbientGeneric_SetPreset(100, 100, 0, 0, 10, 1, 80, 80, 0, 0, 0, 0, 0); break;
    case 6:  AmbientGeneric_SetPreset(100, 100, 0, 0, 10, 1, 50, 70, 0, 0, 0, 0, 0); break;
    case 7:  AmbientGeneric_SetPreset(100, 100, 0, 0, 5, 1, 40, 50, 1, 50, 0, 10, 0); break;
    case 8:  AmbientGeneric_SetPreset(100, 100, 0, 0, 5, 1, 40, 50, 1, 150, 0, 10, 0); break;
    case 9:  AmbientGeneric_SetPreset(100, 100, 0, 0, 5, 1, 40, 50, 1, 750, 0, 10, 0); break;
    case 10: AmbientGeneric_SetPreset(128, 100, 50, 75, 10, 1, 30, 40, 2, 8, 20, 0, 0); break;
    case 11: AmbientGeneric_SetPreset(128, 100, 50, 75, 10, 1, 30, 40, 2, 25, 20, 0, 0); break;
    case 12: AmbientGeneric_SetPreset(128, 100, 50, 75, 10, 1, 30, 40, 2, 70, 20, 0, 0); break;
    case 13: AmbientGeneric_SetPreset(50, 50, 0, 0, 10, 1, 20, 50, 0, 0, 0, 0, 0); break;
    case 14: AmbientGeneric_SetPreset(70, 70, 0, 0, 10, 1, 20, 50, 0, 0, 0, 0, 0); break;
    case 15: AmbientGeneric_SetPreset(90, 90, 0, 0, 10, 1, 20, 50, 0, 0, 0, 0, 0); break;
    case 16: AmbientGeneric_SetPreset(120, 120, 0, 0, 10, 1, 20, 50, 0, 0, 0, 0, 0); break;
    case 17: AmbientGeneric_SetPreset(180, 180, 0, 0, 10, 1, 20, 50, 0, 0, 0, 0, 0); break;
    case 18: AmbientGeneric_SetPreset(255, 255, 0, 0, 10, 1, 20, 50, 0, 0, 0, 0, 0); break;
    case 19: AmbientGeneric_SetPreset(200, 75, 90, 90, 10, 1, 50, 90, 2, 100, 20, 0, 0); break;
    case 20: AmbientGeneric_SetPreset(255, 75, 97, 90, 10, 1, 50, 90, 1, 40, 50, 0, 0); break;
    case 21: AmbientGeneric_SetPreset(100, 100, 0, 0, 10, 1, 30, 50, 3, 15, 20, 0, 0); break;
    case 22: AmbientGeneric_SetPreset(160, 160, 0, 0, 10, 1, 50, 50, 3, 500, 25, 0, 0); break;
    case 23: AmbientGeneric_SetPreset(255, 75, 88, 0, 10, 1, 40, 0, 0, 0, 0, 0, 5); break;
    case 24: AmbientGeneric_SetPreset(200, 20, 95, 70, 10, 1, 70, 70, 3, 20, 50, 0, 0); break;
    case 25: AmbientGeneric_SetPreset(180, 100, 50, 60, 10, 1, 40, 60, 2, 90, 100, 100, 0); break;
    case 26: AmbientGeneric_SetPreset(60, 60, 0, 0, 10, 1, 40, 70, 3, 80, 20, 50, 0); break;
    case 27: AmbientGeneric_SetPreset(128, 90, 10, 10, 10, 1, 20, 40, 1, 5, 10, 20, 0); break;
    }
};

float() AmbientGeneric_HasLFO =
{
    if (self.lfotype <= AG_LFO_OFF)
        return FALSE;
    if (self.lforate <= 0)
        return FALSE;
    if (self.lfomodpitch <= 0 && self.lfomodvol <= 0)
        return FALSE;
    return TRUE;
};

float() AmbientGeneric_LFOWave =
{
    float rate = self.lforate * 0.01;
    if (rate <= 0)
        return 0;
    if (rate > 50)
        rate = 50;

    if (self.lfotype == AG_LFO_RND)
    {
        if (time >= self.ag_lfo_next_random)
        {
            self.ag_lfo_random = random() * 2 - 1;
            self.ag_lfo_next_random = time + (1.0 / rate);
        }
        return self.ag_lfo_random;
    }

    float phase = (time - self.ag_lfo_start) * rate;
    phase = phase - floor(phase);

    if (self.lfotype == AG_LFO_SQR)
        return (phase < 0.5) ? -1 : 1;
    if (self.lfotype == AG_LFO_TRI)
    {
        if (phase < 0.5)
            return phase * 4 - 1;
        return 3 - phase * 4;
    }

    return 0;
};

float(float dur) AmbientGeneric_TransitionFrac =
{
    if (dur <= 0)
        return 1;
    return AmbientGeneric_Clamp((time - self.ag_t_start) / dur, 0, 1);
};

void() AmbientGeneric_Push =
{
    if (self.message == "")
        return;

    string sample = AmbientGeneric_NormaliseSample(self.message);
    sound(self, CHAN_VOICE, sample,
          self.ag_current_volume,
          self.ag_attenuation,
          self.ag_current_pitch,
          SOUNDFLAG_FOLLOW);
};

void(float base_volume, float base_pitch) AmbientGeneric_ModulateAndPush =
{
    float volume = base_volume;
    float pitch = base_pitch;

    if (self.ag_active && AmbientGeneric_HasLFO())
    {
        float wave = AmbientGeneric_LFOWave();

        if (self.lfomodpitch > 0)
            pitch = pitch + self.ag_target_pitch * (self.lfomodpitch * 0.01) * wave;

        if (self.lfomodvol > 0)
        {
            float drop = ((1 - wave) * 0.5) * (self.lfomodvol * 0.01);
            volume = volume * (1 - drop);
        }
    }

    self.ag_current_volume = AmbientGeneric_Clamp(volume, 0, 1);
    self.ag_current_pitch = AmbientGeneric_Clamp(pitch, 1, 255);
    AmbientGeneric_Push();
};

void() AmbientGeneric_Think =
{
    float tv = AmbientGeneric_TransitionFrac(self.ag_vol_dur);
    float tp = AmbientGeneric_TransitionFrac(self.ag_pitch_dur);
    float volume = self.ag_vol_from + (self.ag_vol_to - self.ag_vol_from) * tv;
    float pitch = self.ag_pitch_from + (self.ag_pitch_to - self.ag_pitch_from) * tp;

    AmbientGeneric_ModulateAndPush(volume, pitch);

    if (tv >= 1 && tp >= 1)
    {
        if (self.ag_stop_at_end)
        {
            self.ag_stop_at_end = 0;
            self.ag_active = 0;
            self.ag_current_volume = 0;
            AmbientGeneric_Push();
            self.nextthink = 0;
            return;
        }

        if (!AmbientGeneric_HasLFO())
        {
            self.nextthink = 0;
            return;
        }
    }

    self.nextthink = time + 0.05;
};

void(float to_volume, float to_pitch, float dur_volume, float dur_pitch, float stop_after) AmbientGeneric_Transition =
{
    self.ag_vol_from = self.ag_current_volume;
    self.ag_vol_to = to_volume;
    self.ag_pitch_from = self.ag_current_pitch;
    self.ag_pitch_to = to_pitch;
    self.ag_t_start = time;
    self.ag_vol_dur = dur_volume;
    self.ag_pitch_dur = dur_pitch;
    self.ag_stop_at_end = stop_after;

    if (dur_volume <= 0 && dur_pitch <= 0)
    {
        AmbientGeneric_ModulateAndPush(to_volume, to_pitch);
        if (stop_after)
        {
            self.ag_active = 0;
            self.ag_current_volume = 0;
            AmbientGeneric_Push();
            self.nextthink = 0;
        }
        else if (AmbientGeneric_HasLFO())
        {
            self.think = AmbientGeneric_Think;
            self.nextthink = time + 0.05;
        }
        else
            self.nextthink = 0;
        return;
    }

    self.think = AmbientGeneric_Think;
    self.nextthink = time + 0.05;
};

float() AmbientGeneric_StartVolume =
{
    if (self.volstart > 0)
        return AmbientGeneric_Clamp(self.volstart / 10.0, 0, 1);
    return self.ag_target_volume;
};

float() AmbientGeneric_StartPitch =
{
    if (self.pitchstart > 0)
        return AmbientGeneric_Clamp(self.pitchstart, 1, 255);
    return self.ag_target_pitch;
};

float() AmbientGeneric_CSpinTargetPitch =
{
    if (self.cspinup <= 0)
        return self.ag_target_pitch;

    float count = AmbientGeneric_Clamp(self.ag_cspin_count, 1, self.cspinup);
    float start_pitch = AmbientGeneric_StartPitch();
    return start_pitch + (self.ag_target_pitch - start_pitch) * (count / self.cspinup);
};

void() AmbientGeneric_Start =
{
    self.ag_active = 1;
    self.ag_lfo_start = time;
    self.ag_lfo_next_random = time;

    if (self.cspinup > 0 && self.ag_cspin_count < 1)
        self.ag_cspin_count = 1;
    else if (self.cspinup <= 0)
        self.ag_cspin_count = 0;

    self.ag_current_volume = AmbientGeneric_StartVolume();
    self.ag_current_pitch = AmbientGeneric_StartPitch();

    AmbientGeneric_Transition(self.ag_target_volume,
                              AmbientGeneric_CSpinTargetPitch(),
                              self.fadein * AG_TIME_SCALE,
                              self.spinup * AG_TIME_SCALE,
                              0);
};

void() AmbientGeneric_Stop =
{
    if (!self.ag_active)
        return;

    float end_vol = (self.volstart > 0) ? AmbientGeneric_Clamp(self.volstart / 10.0, 0, 1) : 0;
    float end_pit = AmbientGeneric_StartPitch();

    AmbientGeneric_Transition(end_vol, end_pit,
                              self.fadeout * AG_TIME_SCALE,
                              self.spindown * AG_TIME_SCALE,
                              1);
};

void() AmbientGeneric_IncrementalSpin =
{
    if (!self.ag_active)
    {
        self.ag_cspin_count = 1;
        AmbientGeneric_Start();
        return;
    }

    if (self.ag_cspin_count < self.cspinup)
        self.ag_cspin_count = self.ag_cspin_count + 1;

    AmbientGeneric_Transition(self.ag_target_volume,
                              AmbientGeneric_CSpinTargetPitch(),
                              self.fadein * AG_TIME_SCALE,
                              self.spinup * AG_TIME_SCALE,
                              0);
};

void() AmbientGeneric_Use =
{
    if (self.cspinup > 0)
    {
        AmbientGeneric_IncrementalSpin();
        return;
    }

    if (self.spawnflags & AG_NOT_TOGGLED)
    {
        AmbientGeneric_Start();
        return;
    }

    if (self.ag_active)
        AmbientGeneric_Stop();
    else
        AmbientGeneric_Start();
};

/*QUAKED ambient_generic (.6 .8 .4) (-8 -8 -8) (8 8 8) PLAY_EVERYWHERE SMALL_RADIUS MEDIUM_RADIUS LARGE_RADIUS START_SILENT NOT_TOGGLED
HL/GoldSrc point-entity ambient sound source.

"message"       WAV path relative to sound/.  "!NAME" has the leading
                "!" stripped; this mod does not expand sentences.txt.
"health"        Max volume 0..10 (default 10).
"preset"        GoldSrc dynamic preset 0..27.  Nonzero overrides dynamics.
"volstart"      Start volume 0..10 for fade-in / fade-out endpoint.
"fadein"        Fade-in time 0..100.
"fadeout"       Fade-out time 0..100.
"pitch"         Pitch percent, 100 native, 255 high.
"pitchstart"    Start pitch for spin-up / spin-down endpoint.
"spinup"        Spin-up time 0..100.
"spindown"      Spin-down time 0..100.
"lfotype"       0 off, 1 square, 2 triangle, 3 random.
"lforate"       LFO rate 0..1000.
"lfomodpitch"   LFO pitch modulation 0..100.
"lfomodvol"     LFO volume modulation 0..100.
"cspinup"       Incremental spinup count; disables toggle-off.
*/
void() ambient_generic =
{
    self.movetype = MOVETYPE_NONE;
    self.solid = SOLID_NOT;
    self.use = AmbientGeneric_Use;

    if (self.preset > 0)
        AmbientGeneric_ApplyPreset();

    self.ag_attenuation = AmbientGeneric_Attenuation();

    float v = self.health;
    if (v <= 0) v = 10;
    self.ag_target_volume = AmbientGeneric_Clamp(v / 10.0, 0, 1);

    float p = self.pitch;
    if (p <= 0) p = 100;
    self.ag_target_pitch = AmbientGeneric_Clamp(p, 1, 255);

    self.lfotype = floor(self.lfotype + 0.5);
    if (self.lfotype < 0) self.lfotype = 0;
    if (self.lfotype > 3) self.lfotype = 3;
    self.lforate = AmbientGeneric_Clamp(self.lforate, 0, 1000);
    self.lfomodpitch = AmbientGeneric_Clamp(self.lfomodpitch, 0, 100);
    self.lfomodvol = AmbientGeneric_Clamp(self.lfomodvol, 0, 100);
    self.cspinup = floor(AmbientGeneric_Clamp(self.cspinup, 0, 64));

    if (self.message != "")
    {
        string sample = AmbientGeneric_NormaliseSample(self.message);
        if (sample != self.message)
            dprint(sprintf("ambient_generic: sentence syntax '%s' not expanded; playing raw '%s'\n",
                           self.message, sample));
        precache_sound(sample);
    }
    else
    {
        dprint(sprintf("ambient_generic at %v: no 'message' key set; entity will be silent\n",
                       self.origin));
    }

    if (!(self.spawnflags & AG_START_SILENT) && self.message != "")
    {
        self.think = AmbientGeneric_Start;
        self.nextthink = time + 0.1;
    }
};
