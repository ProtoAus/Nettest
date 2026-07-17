// ============================================================================
//  client/cl_vehicle_sound.qc  -  prop_car engine audio (CSQC-synthesized)
//
//  The classic multi-sample RPM ladder (HL2-jeep style): four looped anchors
//  (idle / low / mid / high) equal-power CROSSFADED on two channels by a
//  "virtual RPM", each anchor pitch-bent only a little (<=12%) toward the
//  exact target so the timbre never chipmunks.  Gears are FAKED for audio:
//  virtual RPM is a sawtooth of speed (frac(speed/max * gears)) that resets
//  per gear with a shift clunk - the physics has no gearbox and doesn't need
//  one.
//
//  WHY CSQC: only CSQC has soundupdate() (in-place per-frame volume+pitch of
//  a playing channel, cursor preserved = no restart pops; SSQC's soundupdate
//  is PF_Fixme).  Every client synthesizes locally from data it already has:
//    - the car's phys_files mirror (.pp_is_car byte, cl_physprop.qc) carries
//      interpolated origin + velocity for EVERY nearby car, driven or not;
//    - predicted_player.pm_incar + cl_car_cam_org say "I'm driving THIS one";
//    - cl_car_throttle_in (captured in CSQC_Input_Frame, cl_player.qc) is the
//      driver's live pedal - lets the engine REV while stationary through a
//      fast-attack / slow-decay envelope.
//  Remote cars have no networked throttle -> they sound speed-only, and are
//  audible only while moving (a parked driverless car is silent; a networked
//  "engine on" bit is possible later if that reads wrong).
//
//  DOPPLER: s_doppler must stay 0 (engine default) - it OVERWRITES the QC
//  pitch on spatialized channels every mix frame.
//  Loops attach with SOUNDFLAG_FOLLOW so the engine re-spatializes to the
//  mirror's interpolated origin between our updates; channels are dedicated
//  non-zero numbers (CHAN_AUTO can never be updated or stopped).
//  Placeholder WAVs are procedurally generated - tools/gen_car_sounds.py;
//  drop in real CC0 recordings under the same names any time.
// ============================================================================

const float CHAN_CAR_ENGINE_A = 5;   // low crossfade anchor (6 = physprop scrape, 8 = rain)
const float CHAN_CAR_ENGINE_B = 7;   // high crossfade anchor
const float CHAN_CAR_SKID     = 9;
const float CHAN_CAR_ONESHOT  = 11;  // start/stop/shift clunks

const float CAR_SND_HALFPI = 1.570796;

// RPM anchor samples, index 0..3 (anchor i sits at virtualRPM = i/3).
string(float i) CarSound_Anchor =
{
    if (i <= 0) return "sounds/vehicles/car_idle.wav";
    if (i == 1) return "sounds/vehicles/car_rev_low.wav";
    if (i == 2) return "sounds/vehicles/car_rev_mid.wav";
    return "sounds/vehicles/car_rev_high.wav";
};

// Per-car state, stored on the phys_files mirror entity itself.
.float car_snd_on;        // engine loop channels live
.float car_snd_lo;        // anchor index currently on channel A (-1 = force set)
.float car_gear_prev;     // last whole virtual gear (shift-clunk edge)
.float car_skid_on;       // skid loop channel live
.float car_shift_snd_t;   // audio shift-dip window end (revs sag ~ the server throttle cut)

float carsnd_precached;
float carsnd_env;         // local driver's throttle envelope 0..1
float carsnd_incar_prev;  // pm_incar edge latch (mount/dismount one-shots)
float carsnd_start_pend;  // play the start one-shot on the local car this frame
float carsnd_shift_time;  // shift-clunk rate limiter
float carsnd_ign_until;   // engine loops held SILENT until the crank one-shot ends
entity carsnd_localcar;   // THE mirror the local player is driving (nearest-car pre-pass)
float carsnd_dbg_time;    // cl_car_sound_debug print throttle

void() CarSound_Precache =
{
    float i;
    for (i = 0; i < 4; i = i + 1)
        precache_sound(CarSound_Anchor(i));
    precache_sound("sounds/vehicles/car_skid.wav");
    precache_sound("sounds/vehicles/car_start.wav");
    precache_sound("sounds/vehicles/car_stop.wav");
    precache_sound("sounds/vehicles/car_shift.wav");
    carsnd_precached = TRUE;
};

// Kill every loop this car owns.  Also the CSQC_Ent_Remove hook (cl_main.qc)
// for pp_is_car mirrors - without it a removed car leaves FORCELOOP channels
// orphaned at its last origin forever.
void(entity car) CarSound_Stop =
{
    if (!car.car_snd_on && !car.car_skid_on)
        return;
    stopsound(car, CHAN_CAR_ENGINE_A);
    stopsound(car, CHAN_CAR_ENGINE_B);
    stopsound(car, CHAN_CAR_SKID);
    car.car_snd_on  = 0;
    car.car_skid_on = 0;
    car.car_snd_lo  = -1;
};

// Per-frame driver - call from CSQC_UpdateView (before renderscene is fine;
// sound is frame-rate independent).
void() CSQC_CarSound_Frame =
{
    entity car;

    if (!cvar("cl_car_sound"))
    {   // switched off mid-drive: sweep any live loops, then stay silent
        // (car chain, not find(classname "phys_files") — that walked EVERY physics prop
        //  on the map every frame just to reach the handful of cars.)
        for (car = g_car_chain_head; car; car = car.pp_car_next)
            CarSound_Stop(car);
        carsnd_env = 0;
        carsnd_incar_prev = 0;
        return;
    }
    if (!carsnd_precached)
        CarSound_Precache();

    float master = cvar("cl_car_sound_volume");
    if (master <= 0) master = 0.8;
    float maxspd = cvar("cl_car_sound_maxspeed");
    if (maxspd <= 0) maxspd = 700;
    float gears = cvar("cl_car_sound_gears");
    if (gears < 1) gears = 4;
    float gearstep = cvar("cl_car_sound_gearstep");   // percent of native pitch each gear steps UP
    if (gearstep <= 0) gearstep = 5;
    // Standing-rev ceiling: how far the THROTTLE alone may lift the revs at ZERO speed (see the
    // THROTTLE FLOOR below).  Was hardcoded 0.8 = the pedal slammed the revs to 80% the instant you
    // touched it from a standstill — a=0.8*3=2.4 lands on the rev_mid/rev_high anchor pair, so a
    // standing start sounded like it was already at mid speed instead of building from idle.
    float revfloor = cvar("cl_car_sound_revfloor");
    if (revfloor <= 0) revfloor = 0.28;
    if (revfloor > 1)  revfloor = 1;
    // Engine volume at ZERO throttle (coasting / idle) as a fraction of the powered volume — the
    // LOAD half of "loudness = revs x load".  1 = no coast ducking (the old revs-only curve, where a
    // no-throttle downshift blared at ~full volume).
    float coastvol = cvar("cl_car_sound_coastvol");
    if (coastvol <= 0) coastvol = 0.5;
    if (coastvol > 1)  coastvol = 1;

    float incar = 0;
    if (predicted_player)
        if (predicted_player.pm_incar)
            incar = 1;

    // Driver throttle envelope: fast attack (engine picks up), slow decay
    // (revs sag when you lift) - this is what makes stationary revving and
    // throttle-lift feel alive with zero extra networking.
    float want = 0;
    if (incar && cl_car_throttle_in > 10)   // movevalues are ~+-400 at full stick
        want = 1;
    if (want > carsnd_env)
        carsnd_env = min(1, carsnd_env + frametime / 0.18);
    else
        carsnd_env = max(0, carsnd_env - frametime / 0.55);

    // Mount/dismount edges -> start/stop one-shots.
    if (incar && !carsnd_incar_prev)
    {
        carsnd_start_pend = TRUE;             // played on the local car below
        // IGNITION: loops stay silent until the crank one-shot finishes (the
        // server holds the throttle dead for sv_car_ignition_time to match).
        float ign = soundlength("sounds/vehicles/car_start.wav");
        if (ign <= 0) ign = 1.15;
        carsnd_ign_until = time + ign;
    }
    else if (!incar && carsnd_incar_prev)
    {   // shutdown clunk where the driver stands (the car mirror may already
        // be coasting away - the engine loops fade with its speed regardless)
        sound(predicted_player, CHAN_CAR_ONESHOT, "sounds/vehicles/car_stop.wav", master, ATTN_NORM);
        carsnd_env = 0;
        carsnd_ign_until = 0;
    }
    carsnd_incar_prev = incar;

    // PRE-PASS: pick THE local car = the car mirror NEAREST the seat.  Anchor on
    // predicted_player.origin FIRST (the seat — fresh every frame, exactly what
    // the car camera anchors on) and fall back to the proxy-streamed
    // cl_car_cam_org; nearest match, sanity-capped.  v1's fixed 160u radius vs
    // the interpolation-lagged mirror was a single point of failure — below 30
    // u/s the driver's engine is audible ONLY through this match, so it gets
    // the same robustness the camera has.
    carsnd_localcar = world;
    if (incar)
    {
        vector seat = cl_car_cam_org;
        if (predicted_player)
            seat = predicted_player.origin;
        float bestd = 1024;   // sanity cap only — your own car is by far the nearest
        for (car = g_car_chain_head; car; car = car.pp_car_next)
        {
            float d = vlen(car.origin - seat);
            float d2 = vlen(car.origin - cl_car_cam_org);
            if (d2 < d) d = d2;                 // best of both anchors
            if (d < bestd)
            {
                bestd = d;
                carsnd_localcar = car;
            }
        }
    }

    // diagnosis overlay: cl_car_sound_debug 1 -> what the driver thinks, 2 Hz
    if (cvar("cl_car_sound_debug") && time > carsnd_dbg_time)
    {
        carsnd_dbg_time = time + 0.5;
        float dbgd = -1;
        if (carsnd_localcar != world)
            dbgd = vlen(carsnd_localcar.origin - cl_car_cam_org);
        print(sprintf("carsnd: incar %g localcar %s dist %.0f env %.2f ign %.2f thr %.0f\n",
              incar, (carsnd_localcar != world) ? "YES" : "no", dbgd, carsnd_env,
              max(0, carsnd_ign_until - time), cl_car_throttle_in));
    }

    for (car = g_car_chain_head; car; car = car.pp_car_next)
    {
        float speed = vlen(car.velocity);
        float hspeed = vlen([car.velocity_x, car.velocity_y, 0]);   // horizontal — matches the physics gearbox
        float islocal = (car == carsnd_localcar) ? 1 : 0;
        // Per-car engine scale from the NETWORKED physics values (so the audio gears + shift-dip land on the
        // SAME speeds the car actually shifts at) — falls back to the cl_car_sound_* cvars if unset.
        float cmaxspd = (car.pp_car_maxspd > 0)  ? car.pp_car_maxspd : maxspd;
        float cgears  = (car.pp_car_gears  >= 1) ? car.pp_car_gears  : gears;
        float cshift  = (car.pp_car_shift  > 0)  ? car.pp_car_shift  : 0.25;

        // Engine audible: always for the driver's car (idle included); remote
        // cars only while actually moving (no driver flag on the wire - v1).
        float engine_on = islocal;
        if (speed > 30) engine_on = 1;

        if (!engine_on)
        {
            if (car.car_snd_on || car.car_skid_on)
                CarSound_Stop(car);
            car.car_gear_prev = 0;
            continue;
        }

        if (islocal && carsnd_start_pend)
        {
            sound(car, CHAN_CAR_ONESHOT, "sounds/vehicles/car_start.wav", master, ATTN_NORM);
            carsnd_start_pend = FALSE;
        }

        // IGNITION: while the crank one-shot plays the engine loops stay OFF
        // (they'd talk over the starter); they come up the moment it ends.
        if (islocal && time < carsnd_ign_until)
        {
            if (car.car_snd_on || car.car_skid_on)
                CarSound_Stop(car);
            continue;
        }

        // ---- virtual GEAR INDEX (SPEED-only, horizontal) --------------------
        // The gear index MUST come from speed, NOT the throttle envelope — flooring rpm with the pedal (the
        // old `revcap` on rpm01) pinned rpm ≥ 0.8 so `floor(rpm·gears)` never moved and the shift dip never
        // fired.  The throttle now floors the WITHIN-gear rev (audio01) instead, below, so a standing rev
        // still sounds revvy without freezing the gearbox.
        float gear01 = hspeed / cmaxspd;
        if (gear01 > 1) gear01 = 1;

        float audio01;
        if (islocal && cl_car_throttle_in < -10 && speed > 30)
        {   // REVERSE: one long gear, no sawtooth/shifts — a capped whine
            // (reverse tops out at 0.6x max speed server-side)
            audio01 = min(speed / (cmaxspd * 0.35), 1) * 0.6;
            car.car_gear_prev = 0;
        }
        else
        {
            // fake gearbox: sawtooth within each virtual gear + clunk on the reset.
            // PER-GEAR FLOOR (review fix): only FIRST gear pulls from idle — every
            // later gear LANDS at ~45% revs after the shift and climbs to redline,
            // like a real upshift (v1 reset to ~idle each gear = saggy and un-car-like).
            float gearpos = gear01 * cgears;
            float gearnum = floor(gearpos);
            if (gear01 >= 0.995)
                audio01 = 1;                   // pinned at redline in top gear
            else
            {
                float gfrac = gearpos - gearnum;
                if (gearnum < 1)
                    audio01 = gfrac;
                else
                    audio01 = 0.45 + 0.55 * gfrac;
            }
            // THROTTLE FLOOR: the pedal revs the engine WITHIN the current gear (a standing rev, a launch)
            // without advancing the SPEED-derived gear index — so it no longer freezes the gearbox.
            // The ceiling is cl_car_sound_revfloor (0.28), NOT the old hardcoded 0.8: this is a FLOOR on
            // audio01, so at zero speed it IS the note you hear, and 0.8 put a standing start straight onto
            // the rev_mid/rev_high anchors (a=2.4) — the car sounded mid-speed before it had moved.  At 0.28
            // (a=0.84 => idle/rev_low pair) a launch starts low, and the SPEED-derived gfrac overtakes the
            // floor almost immediately (~77 u/s at 4 gears / 1100 max) and climbs to redline across 1st gear,
            // so the pedal only colours a genuinely stationary rev instead of masking the whole build-up.
            if (islocal)
            {
                float revcap = carsnd_env * revfloor;
                if (revcap > audio01) audio01 = revcap;
            }
            // gear tracking with HYSTERESIS (mirror of the server's): clunk only on
            // the way UP; only settle DOWN once clearly (0.15 gear) below the
            // boundary, so speed jitter around it can't re-trigger shifts.
            if (gearnum > car.car_gear_prev)
            {
                if (islocal && time > carsnd_shift_time && speed > 60)
                {
                    sound(car, CHAN_CAR_ONESHOT, "sounds/vehicles/car_shift.wav", master * 0.8, ATTN_NORM);
                    carsnd_shift_time = time + 0.3;
                    car.car_shift_snd_t = time + cshift;   // sag for the REAL throttle-cut window (sv_car_shift_time)
                }
                car.car_gear_prev = gearnum;
            }
            else if (gearnum < car.car_gear_prev && gearpos < car.car_gear_prev - 0.15)
                car.car_gear_prev = gearnum;

            // anti-idle-wrap floor: a moving car can never resolve to idle no
            // matter where the sawtooth lands (this + the scale sync fixes
            // "max reverse sounds like idle")
            float rpmfloor = gear01 * 0.5;
            if (rpmfloor > 0.5) rpmfloor = 0.5;
            if (audio01 < rpmfloor) audio01 = rpmfloor;
        }

        // shift dip: brief rev sag + duck matching the server's throttle cut — deeper so it reads as a CUT.
        float shiftduck = 1;
        if (time < car.car_shift_snd_t)
        {
            audio01 = audio01 * 0.25;
            shiftduck = 0.82;
        }

        // idle should breathe a little even at rest
        if (islocal && audio01 < 0.02)
            audio01 = 0.02 + 0.015 * sin(time * 2.1);

        // ---- anchor pair + equal-power crossfade ----------------------------
        float a  = audio01 * 3;                // 4 anchors -> 3 spans
        float lo = floor(a);
        if (lo > 2) lo = 2;
        float t  = a - lo;

        // each anchor bends at most 14% toward the target (never chipmunks):
        // A (the lower anchor) is pitched UP as t rises; B arrives pitched
        // DOWN and relaxes to native as t reaches it.  At the pinned redline
        // channel B strains a few extra % for the flat-out top note.
        //
        // LOUDNESS = revs x LOAD.  The old curve was `0.55 + 0.45*audio01` — revs ALONE — which
        // conflated "spinning fast" with "making power".  A no-throttle DOWNSHIFT jumps the sawtooth
        // to the TOP of the lower gear (~redline — physically CORRECT: engine braking really does
        // spin the engine up at the same road speed), and the volume followed it to ~100%.  So
        // gliding with your hands off the keys BLARED on every downshift.  A real engine on the
        // OVERRUN is spinning fast but making no power and is much quieter than the same revs
        // pulling — so scale by the throttle envelope: cl_car_sound_coastvol at zero throttle up to
        // 1.0 at full.  This deliberately quietens idle + coasting too (both are genuinely quiet in
        // a real car).  Remote cars carry no throttle on the wire (speed-only), so they keep the
        // old load-free curve rather than being wrongly ducked to coast volume while flat out.
        float load = 1;
        if (islocal)
            load = coastvol + (1 - coastvol) * carsnd_env;
        float loud = master * (0.55 + 0.45 * audio01) * load * shiftduck;
        float volA = loud * cos(t * CAR_SND_HALFPI);
        float volB = loud * sin(t * CAR_SND_HALFPI);
        // PER-GEAR PITCH PEDESTAL: the within-gear sawtooth (audio01) resets to the
        // same 0.45->1.0 band every gear, so without this every gear sweeps the SAME
        // pitch and an up-shift sounds like "the same gear."  Add a per-gear offset so
        // each higher gear sits on a higher note.  Sourced from the DEBOUNCED gear
        // (car_gear_prev, hysteresis above) not the raw per-frame gearnum, so speed
        // jitter at a boundary can't warble it; it's 0 in reverse / engine-off, so the
        // pedestal auto-zeroes there.  (car_gear_prev-1) => gears 0/1 sit at pedestal 0.
        float gearpitch = gearstep * (car.car_gear_prev - 1);
        if (gearpitch < 0)  gearpitch = 0;
        if (gearpitch > 30) gearpitch = 30;          // chipmunk safety rail (~5 semitones)
        float pitA = 100 + 14 * t + gearpitch;
        float pitB = 86 + 14 * t + gearpitch;
        if (audio01 >= 0.999)
            pitB = pitB + 6;                          // stacks on the pedestal -> top gear = highest note
        float fl   = SOUNDFLAG_FORCELOOP | SOUNDFLAG_FOLLOW;

        if (!car.car_snd_on || car.car_snd_lo != lo)
        {   // (re)start both channels - anchor swaps land while the swapped
            // channel is at ~zero volume, so the restart is inaudible
            sound(car, CHAN_CAR_ENGINE_A, CarSound_Anchor(lo),     volA, ATTN_NORM, pitA, fl);
            sound(car, CHAN_CAR_ENGINE_B, CarSound_Anchor(lo + 1), volB, ATTN_NORM, pitB, fl);
            car.car_snd_on = 1;
            car.car_snd_lo = lo;
        }
        else
        {   // the per-frame rev: seamless in-place volume+pitch (no restart)
            soundupdate(car, CHAN_CAR_ENGINE_A, "", volA, ATTN_NORM, pitA, fl, 0);
            soundupdate(car, CHAN_CAR_ENGINE_B, "", volB, ATTN_NORM, pitB, fl, 0);
        }

        // ---- skid loop: lateral slip vs the car's facing --------------------
        makevectors(car.angles);
        float lat = fabs(car.velocity * v_right);
        if (lat > 140 && speed > 180)
        {
            float skidvol = (lat - 140) / 300;
            if (skidvol > 1) skidvol = 1;
            skidvol = skidvol * master * 0.9;
            if (!car.car_skid_on)
            {
                sound(car, CHAN_CAR_SKID, "sounds/vehicles/car_skid.wav", skidvol, ATTN_NORM, 100, fl);
                car.car_skid_on = 1;
            }
            else
                soundupdate(car, CHAN_CAR_SKID, "", skidvol, ATTN_NORM, 100, fl, 0);
        }
        else if (car.car_skid_on)
        {
            stopsound(car, CHAN_CAR_SKID);
            car.car_skid_on = 0;
        }
    }
    // Start one-shot NEVER lost: if no local car mirror matched this frame
    // (mirror not streamed yet / out of range), play the crank on the player
    // instead - the driver is sitting in the car, so positionally identical.
    if (carsnd_start_pend && incar && predicted_player)
        sound(predicted_player, CHAN_CAR_ONESHOT, "sounds/vehicles/car_start.wav", master, ATTN_NORM);
    carsnd_start_pend = FALSE;
};
