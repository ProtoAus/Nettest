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
// sven-coop.fgd calls bit 32 "Un-looped|Cyclic".  It means TWO things in
// CAmbientGeneric and we only ever implemented one of them:
//   * ToggleUse: a non-looping sound retriggers from the top on every Use
//     instead of toggling off   -- we had this, as AG_NOT_TOGGLED
//   * Precache:  `if (!START_SILENT) { if (m_fLooping) m_fActive = TRUE; }`
//     i.e. a non-looping ambient NEVER auto-starts at spawn, even when
//     "Start Silent" is clear   -- we did NOT have this; see the spawn gate
//     at the bottom of this file.
const float AG_NOT_LOOPED      = 32;
const float AG_NOT_TOGGLED     = 32;   // same bit, retrigger-vs-toggle spelling

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

// Sven playmode (sven-coop.fgd:1330-1400).  Never declared before, so the key
// was dropped and every ambient took whatever the WAV's own loop cue points
// said — which for a sound authored as one-shot means looping forever.
// Measured across the three target maps: 40 ambients set playmode, of which 18
// are one-shot (1 or 5); the other 22 are 2 (Loop) and were already correct.
//   0 Default   1 Play Once   2 Loop   5 Linear Once   6 Linear Loop
.float playmode;
// Linear-mode falloff distances, in Sven's 256-unit steps (sven-coop.fgd:1393 —
// "0 - 0 units", "1 - 256 units", ... "10 - 2,560 units").  linearmax is the
// distance the sound becomes inaudible; linearmin the distance inside which it
// plays at full volume.
//
// APPROXIMATED, not implemented exactly, and the reason is the builtin: FTE's
// sound() takes a scalar `atten` exponent and has no radius parameter and no
// falloff-mode flag (sv_defs.qc:764, SOUNDFLAG_* at :602-607).  A true linear
// curve would mean ATTN_NONE plus SOUNDFLAG_UNICAST and a per-player distance
// computed in QC every push — which collides head-on with the fact that every
// sound() on a channel restarts the sample from the top, the exact problem the
// dedup latch in AmbientGeneric_Push exists to work around.  A per-listener
// volume recomputed at 20Hz would restart the ambience 20 times a second.
//
// So: convert linearmax into the attenuation that makes the sound fade out at
// about the right distance, and accept a curve of the wrong SHAPE at roughly the
// right REACH.  17 of pizza_ya_san1's 18 ambients set 2/5 and were all playing at
// ATTN_NORM, which is a much shorter reach than 1,280 units.
.float linearmin;
.float linearmax;

const float AG_LINEAR_STEP = 256;   // fgd units per linearmin/linearmax step

const float AG_PLAYMODE_ONCE        = 1;
const float AG_PLAYMODE_LOOP        = 2;
const float AG_PLAYMODE_LINEAR_ONCE = 5;
const float AG_PLAYMODE_LINEAR_LOOP = 6;

float() AmbientGeneric_IsPlayOnce =
{
    return (self.playmode == AG_PLAYMODE_ONCE
         || self.playmode == AG_PLAYMODE_LINEAR_ONCE);
};

// The other half of playmode, which was declared at the top of this file and
// then read by nothing.  2 and 6 are the mapper stating outright that the
// sample repeats -- which is the only way to say it for an .mp3, since mp3 has
// no equivalent of a WAV cue point.
float() AmbientGeneric_IsLoopMode =
{
    return (self.playmode == AG_PLAYMODE_LOOP
         || self.playmode == AG_PLAYMODE_LINEAR_LOOP);
};

// Runtime state.
.float ag_active;
// Set at spawn: this ambient must be handed SOUNDFLAG_FORCELOOP, and its stop
// must be a real sample rather than a volume-0 push.  See the spawn function.
.float ag_forceloop;
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
.float ag_playonce_stop;   // absolute time to cut a playmode-1/5 sample, 0 = none
// Last values actually handed to sound(), quantised — see AmbientGeneric_Push.
.float ag_pushed_once;
.float ag_last_pushed_vol;
.float ag_last_pushed_pitch;
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

    // linearmax first, because it is the mapper being SPECIFIC.  The three
    // radius spawnflags are three coarse presets; a linearmax is a distance in
    // units, and a map that bothered to write one meant it.  Sven's own editor
    // exposes both on the same entity, so this is a precedence decision rather
    // than an exclusion — and 17 of this map's 18 ambients set only linearmax.
    //
    // The scale: ATTN_NORM (1.0) goes quiet at roughly 1000 units in Quake's
    // model, so an attenuation of 1000/reach lands the fade-out at about the
    // distance asked for.  Bounded at both ends — 0 would mean ATTN_NONE (heard
    // across the whole map, which "0 units" emphatically does not mean) and
    // anything above 4 is inaudible almost immediately.
    if (self.linearmax > 0)
    {
        float reach = self.linearmax * AG_LINEAR_STEP;
        return AmbientGeneric_Clamp(1000 / reach, 0.1, 4.0);
    }

    if (self.spawnflags & AG_SMALL_RADIUS)    return 2.0;
    if (self.spawnflags & AG_MEDIUM_RADIUS)   return 1.25;
    if (self.spawnflags & AG_LARGE_RADIUS)    return 0.6;
    return ATTN_NORM;
};

string(string raw) AmbientGeneric_NormaliseSample =
{
    if (raw == "") return raw;
    if (substring(raw, 0, 1) == "!")
        raw = substring(raw, 1, -1);

    // Strip an extension this engine build cannot decode, so FTE's own
    // format-fallback loop can find a replacement.
    //
    // S_LoadSoundWorker tries the EXACT path first and only falls back to
    // .wav/.opus/.ogg when that file does not EXIST.  An .mp3 exists and loads
    // fine — it is the DECODE that fails — so the fallback never runs and
    // dropping an .ogg beside the .mp3 does nothing at all.  Asking for the
    // extensionless stem makes the exact lookup miss and lets the fallback
    // find whatever you shipped.
    //
    // 153 ambient_generics across the Sven corpus name an .mp3.  This is a
    // stopgap that lets you override individual tracks; the real fix is a
    // portable mp3 decoder registered in the engine (see sv_cdaudio_pathfmt
    // and the notes on S_RegisterSoundInputPlugin).
    if (cvar("sv_sound_strip_undecodable"))
    {
        float n = strlen(raw);
        if (n > 4)
        {
            string ext = strtolower(substring(raw, n - 4, 4));
            if (ext == ".mp3")
                return substring(raw, 0, n - 4);
        }
        if (n > 5)
        {
            string ext5 = strtolower(substring(raw, n - 5, 5));
            if (ext5 == ".flac")
                return substring(raw, 0, n - 5);
        }
    }

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

    // Only re-issue when the audible parameters ACTUALLY changed.
    //
    // Every sound() on the same channel restarts the sample from the top.  The
    // modulation think runs at 20 Hz, so an ambient with any LFO or fade was
    // re-triggering its sample 20 times a second — which for a long or
    // streaming sample means it never audibly gets going at all.  th_ep1_00's
    // `raindropssnd` uses preset 27 (lfotype 1), so this ran for the whole map.
    //
    // Quantise before comparing: volume to 1/64 and pitch to whole units, both
    // finer than the mixer resolves, so genuine fades still update smoothly.
    float qv = rint(self.ag_current_volume * 64);
    float qp = rint(self.ag_current_pitch);
    if (self.ag_pushed_once && qv == self.ag_last_pushed_vol
                            && qp == self.ag_last_pushed_pitch)
        return;
    self.ag_pushed_once       = 1;
    self.ag_last_pushed_vol   = qv;
    self.ag_last_pushed_pitch = qp;

    // FTE self-loops a sample ONLY when the file carries loop cue points:
    // snd_mem.c parses the WAV "cue "/"LIST" chunks and otherwise sets
    // loopstart -1, and snd_mix.c keys the EOF rewind off it.  An .mp3 has no
    // such chunk and snd_minimp3.c hands ResampleSfx a hardcoded -1, so every
    // mp3 ambient played exactly once no matter what playmode said.
    // CF_FORCELOOP is the engine's own answer and reaches SSQC as
    // SOUNDFLAG_FORCELOOP.  It is tested AFTER sfx->loopstart, so adding it to
    // a cue-carrying WAV changes nothing at all.
    float sndflags = SOUNDFLAG_FOLLOW;
    if (self.ag_forceloop)
        sndflags = sndflags | SOUNDFLAG_FORCELOOP;

    string sample = AmbientGeneric_NormaliseSample(self.message);
    sound(self, CHAN_VOICE, sample,
          self.ag_current_volume,
          self.ag_attenuation,
          self.ag_current_pitch,
          sndflags);
};

// End a force-looped ambient for real.
//
// A volume-0 sound() does NOT end a CF_FORCELOOP channel -- the mixer rewinds
// it at EOF regardless of volume, so the sample keeps mixing silently and holds
// the channel forever.  Neither obvious cancel reaches a client: an empty
// sample never leaves the server (sv_send.c `else if (!*sample) return;`) and
// stopsound()'s index-0 packet is dropped by cl_parse.c before it reaches the
// stop branch.  The only cancel that works is a real sample on the same
// ent+channel, which is what sv_physprop.qc:899 and sv_momentary.qc:162 already
// do.  SND_SILENCE is sv_doors.qc:309 ("common/null.wav") and sv_main.qc:3889
// precaches it unconditionally at server init.  RELIABLE so the stop is not
// PHS-filtered away from a listener who has walked out of range.
//
// This matters on pizza_ya_san1: every bgm_* is a toggle pair fired by two
// different multi_managers, and mm_denwa fires "sound_denwa" at t=3 and
// "sound_denwa#1" at t=10 to start and then stop the ringing phone.
void() AmbientGeneric_Silence =
{
    self.ag_active = 0;
    self.ag_current_volume = 0;

    if (self.ag_forceloop)
    {
        sound(self, CHAN_VOICE, SND_SILENCE, 1, self.ag_attenuation,
              100, SOUNDFLAG_RELIABLE);
        // The dedup latch now describes a channel that no longer carries our
        // sample, so a restart must be free to re-issue it.
        self.ag_pushed_once = 0;
        return;
    }

    AmbientGeneric_Push();
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

void() AmbientGeneric_Stop;      // defined below; the play-once cut calls it

void() AmbientGeneric_Think =
{
    float tv = AmbientGeneric_TransitionFrac(self.ag_vol_dur);
    float tp = AmbientGeneric_TransitionFrac(self.ag_pitch_dur);
    float volume = self.ag_vol_from + (self.ag_vol_to - self.ag_vol_from) * tv;
    float pitch = self.ag_pitch_from + (self.ag_pitch_to - self.ag_pitch_from) * tp;

    AmbientGeneric_ModulateAndPush(volume, pitch);

    // playmode "Play Once" deadline reached — fade the sample out so a looping
    // WAV doesn't keep repeating.  Checked before the completion branches
    // below, which would otherwise park the think and never come back.
    if (self.ag_playonce_stop > 0 && time >= self.ag_playonce_stop)
    {
        self.ag_playonce_stop = 0;
        AmbientGeneric_Stop();
        return;
    }

    if (tv >= 1 && tp >= 1)
    {
        if (self.ag_stop_at_end)
        {
            self.ag_stop_at_end = 0;
            AmbientGeneric_Silence();
            self.nextthink = 0;
            return;
        }

        // A pending play-once deadline has to keep the think alive even when
        // the fade has settled and there is no LFO to drive it.
        if (!AmbientGeneric_HasLFO() && self.ag_playonce_stop <= 0)
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
            AmbientGeneric_Silence();
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
    // Clear the push-dedup latch: a restart MUST re-issue sound() even when it
    // lands on the same volume/pitch it was last playing at, or a stopped
    // ambient could never be started again.
    self.ag_pushed_once = 0;

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

    // playmode "Play Once": arrange to silence the sample instead of letting
    // its loop cue points run forever.
    //
    // HONEST LIMITATION: this is a timed cut, not true end-of-sample
    // detection.  soundlength() is CSQC-only in this engine, so the server
    // cannot ask how long the sample actually is; sv_ambient_playonce_maxlen
    // is the cap.  A one-shot longer than the cap gets clipped, which is still
    // strictly better than repeating for the rest of the map.
    if (AmbientGeneric_IsPlayOnce())
    {
        float maxlen = cvar("sv_ambient_playonce_maxlen");
        if (maxlen <= 0) maxlen = 10;
        self.ag_playonce_stop = time + maxlen;
    }
    else
        self.ag_playonce_stop = 0;
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

/*QUAKED ambient_generic (.6 .8 .4) (-8 -8 -8) (8 8 8) PLAY_EVERYWHERE SMALL_RADIUS MEDIUM_RADIUS LARGE_RADIUS START_SILENT NOT_LOOPED
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

    // Sven's playmode 2 ("Loop") / 6 ("Linear / Loop") is the only way a mapper
    // can ask for a repeating .mp3, because mp3 has no cue-point equivalent and
    // FTE's loop decision is cue-driven (snd_mem.c, snd_mix.c).  pizza_ya_san1's
    // music sources (bgm_main / bgm_title / bgm_hungary / bgm_mi1 / bgm_battle /
    // sound_denwa) are all playmode 2 on an .mp3 with spawnflags 17.
    //
    // playmode 0 ("Default") is deliberately NOT force-looped: GoldSrc leaves a
    // cue-less sample playing once there, and so do we.
    //
    // Spawnflag 32 wins over playmode, matching the resolution already argued
    // for the autostart gate at the bottom of this file: sound.cpp:219-222 makes
    // bit 32 mean m_fLooping = FALSE outright.  (Corpus-wide that collision
    // happens exactly once -- bm_sts.bsp's `game_area`, playmode 6 with bit 32.)
    //
    // Sequential ifs rather than a && chain: logicops is off mod-wide.
    self.ag_forceloop = FALSE;
    if (AmbientGeneric_IsLoopMode())
        self.ag_forceloop = TRUE;
    if (self.spawnflags & AG_NOT_LOOPED)
        self.ag_forceloop = FALSE;
    if (self.message == "")
        self.ag_forceloop = FALSE;

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
            dprint(sprintf("ambient_generic: rewrote sample '%s' -> '%s'\n",
                           self.message, sample));
        precache_sound(sample);
    }
    else
    {
        dprint(sprintf("ambient_generic at %v: no 'message' key set; entity will be silent\n",
                       self.origin));
    }

    // Auto-start at spawn is for LOOPING, non-silent ambients ONLY.
    //
    // Reference: HL SDK dlls/sound.cpp.  Spawn() does
    //     if (spawnflags & AMBIENT_SOUND_NOT_LOOPING) m_fLooping = FALSE;
    // and Precache() does
    //     if (!(spawnflags & AMBIENT_SOUND_START_SILENT))
    //         { if (m_fLooping) m_fActive = TRUE; }
    //     if (m_fActive) UTIL_EmitAmbientSound(...);
    // util.h:383-384 gives START_SILENT 16 and NOT_LOOPING 32.  So bit 32
    // suppresses the spawn-time emit ON ITS OWN, independently of bit 16.
    //
    // Testing only bit 16 made every triggered one-shot in the map fire at
    // t=0.1.  On th_ep1_00 that is 14 of 27 ambients, NINE of them spawnflags
    // 33 (Play Everywhere -> ATTN_NONE, no falloff): steamtrainsnd, thsignsnd,
    // thundersnd1/2, thunder1snd, thunder2snd, thunder1snd2, thunder2snd2,
    // thunder3snd2.  thsignsnd is hunger/hungerzombiecop/zo_pain2.wav, the
    // zombie-cop groan that belongs on the THEY HUNGER title card ~60 s into
    // the intro; radio_static_snd's WAV carries a loop cue point and so ran
    // under the radio music for the whole intro instead of firing at the 23 s
    // mark when the broadcast cuts out.
    //
    // Corpus-wide: 576 ambient_generics across 40 of the 108 Sven maps set 32
    // without 16 (th_ep3_04 54, th_ep1_01 47, th_escape 46, hl_c12 24, ...).
    //
    // Two knock-on effects, both measured and both HL-faithful:
    //   * th_ep1_00's `owlsnd` and `birdy2` are named but nothing in the map
    //     ever fires them, so they go from "one blip at t=0.1" to silent.
    //     HL is silent for them too.  Corpus-wide only one bit-32 ambient has
    //     no targetname at all (infested.bsp, ambience/cricket.wav).
    //   * Sven's later `playmode` key can contradict bit 32.  Exactly one
    //     entity in 5653 does so (bm_sts.bsp `game_area`, playmode 6 =
    //     Linear/Loop with bit 32 set); we resolve in bit 32's favour because
    //     that is what the HL code above does.  Revisit if bm_sts matters.
    //
    // Sequential ifs rather than a && chain: logicops is off mod-wide.  The
    // old && was in fact evaluating correctly (neither operand has a side
    // effect) -- the bug was a missing term, not a short-circuit trap -- but
    // three-term gates in this codebase are written this way by convention.
    float ag_autostart = TRUE;
    if (self.message == "")
        ag_autostart = FALSE;
    if (self.spawnflags & AG_START_SILENT)
        ag_autostart = FALSE;
    if (self.spawnflags & AG_NOT_LOOPED)
        ag_autostart = FALSE;

    if (ag_autostart)
    {
        self.think = AmbientGeneric_Start;
        self.nextthink = time + 0.1;
    }
};
