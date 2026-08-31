// ============================================================
//  server/sv_screenshake.qc  -  UTIL_ScreenShake + env_shake
//
//  Ported from dlls/util.cpp:674 (UTIL_ScreenShake) and
//  dlls/effects.cpp:1835-1911 (CShake).
//
//  This tree had no shake channel at all.  env_shake existed only as
//      void() env_shake = { self.use = GoldSrc_UnknownRelay_Use; };
//  in sv_goldsrc_compat.qc — i.e. it forwarded its trigger and did nothing
//  else, which is worse than being unimplemented: a stub reports as
//  "implemented" to every audit, so 184 placements across 28 of the 36 Sven
//  hl_ maps never showed up on a gap list.  (See TESTING.md PATCH 156.)
//
//  Half-Life's amplitude/frequency/duration reach the client through gmsgShake
//  and are applied by the ENGINE (V_CalcShake / V_ApplyShake in the GoldSrc
//  client), which FTE has no equivalent of — so the receiving half lives in
//  client/cl_screenshake.qc and the wire event is ours.
// ============================================================

// Mapper keys.  The names are forced: the engine binds a keyvalue to a field of
// the SAME name (ED_FindField is a strcmp), so these cannot be renamed to
// something less collision-prone the way .animrate was in PATCH 155.
//
// .duration and .radius are ALREADY declared — sv_env_hud.qc:20 and
// sv_ai_defs.qc:956 — and are deliberately reused rather than redeclared.
// That is safe in a way the .framerate case was not: QC fields are per-entity
// storage, and no entity is ever both an env_shake and an env_hud, so sharing
// the slot cannot cross-talk.  This file is positioned after both in
// sv_progs.src so the declarations are already in scope.
.float amplitude;
.float frequency;

const float SF_SHAKE_EVERYONE = 1;      // "Don't check radius" (effects.cpp:1868)
// SF_SHAKE_DISRUPT (2) and SF_SHAKE_INAIR (4) are marked "UNDONE: These don't
// work yet" in the SDK itself and do nothing in Half-Life either.  Not
// implemented here for the same reason — matching the reference includes
// matching what it declines to do.

// ---------------------------------------------------------------------------
//  HL's fixed-point quantisation, reproduced for its BEHAVIOUR
// ---------------------------------------------------------------------------
//
//  UTIL_ScreenShake ships amplitude and duration as 4.12 fixed point and
//  frequency as 8.8, through FixedUnsigned16 (util.cpp:645-668), which CLAMPS
//  at 0xFFFF.  So Half-Life cannot express an amplitude above 65535/4096 =
//  15.99976 — and the SDK asks for more than that in real code: mortar.cpp:280
//  and bullsquid.cpp:650 both pass 25, which every GoldSrc client receives as
//  ~16.  That ceiling is what a Half-Life player actually experiences, so it is
//  reproduced here rather than quietly "fixed" into a harder shake.
//
//  The quantisation is applied server-side and the RESULT is sent as a float.
//  Sending the raw fixed-point integers instead would need an unsigned short,
//  and QC's WriteShort is signed — a perfectly ordinary amplitude of 12 encodes
//  to 49152, which overflows it.  Quantising here keeps HL's numbers exactly
//  while leaving the wire in a type QC can actually write.
// 4.12 — amplitude AND duration both use this grid (util.cpp:680-681).  Named
// for the grid rather than for one of its two callers, because reading
// `ShakeQuantiseAmplitude(duration)` at the send site is actively misleading.
float(float v) ShakeQuantise412 =
{
    float fx = floor(v * 4096);
    if (fx > 65535) fx = 65535;
    if (fx < 0)     fx = 0;
    return fx / 4096;
};

// 8.8 — frequency only (util.cpp:681).
float(float v) ShakeQuantise88 =
{
    float fx = floor(v * 256);
    if (fx > 65535) fx = 65535;
    if (fx < 0)     fx = 0;
    return fx / 256;
};

// ---------------------------------------------------------------------------
//  UTIL_ScreenShake — util.cpp:674
// ---------------------------------------------------------------------------
//
//  radius <= 0 shakes everyone.  Note the SDK's own comment: the distance
//  falloff was removed ("Had to get rid of this falloff - it didn't work
//  well"), so inside the radius every player gets the FULL amplitude and
//  outside it nobody does.  That hard edge is the reference behaviour, not an
//  approximation of it — util.cpp:700 still carries the dead
//  `localAmplitude = amplitude;//radius - distance;` showing what was cut.
//
//  Only players ON THE GROUND are shaken (util.cpp:686).  This is why a shake
//  can look like it "did nothing" when you test it mid-jump.
// The wire, split out so the self-test can exercise it without also having to
// satisfy UTIL_ScreenShake's ONGROUND gate — see SV_ShakeSelfTest for why that
// matters headlessly.
void(entity p, float amplitude, float duration, float frequency) SV_ShakeSendTo =
{
    if (!SV_PlayerHasNetchan(p))
        return;                 // bots have no netchan; nothing to send to

    msg_entity = p;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_SCREENSHAKE);
    WriteFloat(MSG_ONE, ShakeQuantise412(amplitude));
    WriteFloat(MSG_ONE, ShakeQuantise412(duration));
    WriteFloat(MSG_ONE, ShakeQuantise88(frequency));
};

void(vector center, float amplitude, float frequency, float duration, float radius) SV_ScreenShake =
{
    entity p = player_chain_head;
    float  n_total = 0, n_shaken = 0, n_airborne = 0, n_outofrange = 0;

    while (p)
    {
        n_total = n_total + 1;
        if (!(p.flags & FL_ONGROUND))
            n_airborne = n_airborne + 1;
        else if (radius > 0 && vlen(center - p.origin) >= radius)
            n_outofrange = n_outofrange + 1;

        if (cvar("sv_debug_shake"))
            print(sprintf("[shake]   player %s at %v ground=%g dist=%g\n",
                          p.netname != "" ? p.netname : "?", p.origin,
                          (p.flags & FL_ONGROUND) > 0, vlen(center - p.origin)));

        if (p.flags & FL_ONGROUND)
        {
            float local_amp = 0;

            if (radius <= 0)
                local_amp = amplitude;
            else if (vlen(center - p.origin) < radius)
                local_amp = amplitude;

            if (local_amp > 0 && SV_PlayerHasNetchan(p))
            {
                n_shaken = n_shaken + 1;
                SV_ShakeSendTo(p, local_amp, duration, frequency);
            }
        }
        p = p.player_chain_next;
    }

    // Report the SELECTION, not just the request.  A bare "fired" line proves
    // nothing: UTIL_ScreenShake drops airborne players and anyone outside the
    // radius, so a shake that reaches nobody logs identically to one that
    // reaches everybody unless the counts are on the line.
    // Two prints, not one: fteqcc caps a varargs call at EIGHT parameters
    // INCLUDING the format string, and the full line needs ten.
    if (cvar("sv_debug_shake"))
    {
        print(sprintf("[shake] amp %g freq %g dur %g radius %g at %v\n",
                      amplitude, frequency, duration, radius, center));
        print(sprintf("[shake]   -> %g/%g shaken (%g airborne, %g out of range)\n",
                      n_shaken, n_total, n_airborne, n_outofrange));
    }
};

// ---------------------------------------------------------------------------
//  env_shake — effects.cpp:1835
// ---------------------------------------------------------------------------
//
//  pev->scale is amplitude, pev->dmg_save frequency, pev->dmg_take duration,
//  pev->dmg radius (effects.cpp:1857-1860).  Those are just storage slots in
//  the SDK; here the keys bind to fields of their own names, so the mapping is
//  direct and the SDK's accessor indirection is unnecessary.
void() env_shake_use =
{
    SV_ScreenShake(self.origin, self.amplitude, self.frequency,
                   self.duration, self.radius);
};

// ---------------------------------------------------------------------------
//  Self-test — sv_shake_selftest 1
// ---------------------------------------------------------------------------
//
//  Sends a known shake straight to a connected client, DELIBERATELY BYPASSING
//  UTIL_ScreenShake's ONGROUND gate, because in the headless harness the client
//  never satisfies it: fteqw64 under the null renderer connects and spawns but
//  sends no movement input, so the server never runs player physics for it and
//  .flags keeps its initial 0.  Measured — a bot on the same server reports
//  ground=1 while the real client reports ground=0 indefinitely.
//
//  The gate itself is still covered, by the counters SV_ScreenShake prints
//  (n_airborne / n_outofrange); this test covers the half those cannot reach,
//  which is whether the event survives the wire and reaches CSQC.
//
//  Same latching shape as AI_AnimRateSelfTest (sv_ai_anim.qc) — a per-frame
//  hook that waits for a client and switches itself off, because without the
//  latch it would fire once per frame forever.
float shake_test_done;

void() SV_ShakeSelfTest =
{
    if (!cvar("sv_shake_selftest") || shake_test_done)
        return;

    // A client with a netchan, i.e. something we can actually send to.
    entity p = find(world, classname, "player");
    while (p && !SV_PlayerHasNetchan(p))
        p = find(p, classname, "player");
    if (!p)
        return;                      // returning early IS the wait

    shake_test_done = 1;

    // Amplitude 12 / frequency 225 / duration 2 are hl_c12's boothshake1.
    print(sprintf("[shaketest] player %s at %v ground=%g health=%g\n",
                  p.netname != "" ? p.netname : "?", p.origin,
                  (p.flags & FL_ONGROUND) > 0, p.health));

    SV_ShakeSendTo(p, 12, 2, 225);

    // State the expected clamp explicitly so a future change to the quantiser
    // is caught here rather than by eye: 12 is well under HL's 15.99976
    // ceiling, so it must survive the round trip unchanged.
    print(sprintf("[shaketest] quantised amp %g (expect 12), freq %g (expect 225) BAD=%g\n",
                  ShakeQuantise412(12), ShakeQuantise88(225),
                  (ShakeQuantise412(12) != 12) + (ShakeQuantise88(225) != 225)));

    // And the ceiling itself, which mortar.cpp:280 actually hits.
    print(sprintf("[shaketest] amp 25 clamps to %g (expect 15.9998) BAD=%g\n",
                  ShakeQuantise412(25),
                  (ShakeQuantise412(25) > 16) + (ShakeQuantise412(25) < 15.999)));
};

/*QUAKED env_shake (.5 .5 0) (-8 -8 -8) (8 8 8) EVERYONE
GoldSrc screen shake.  Fires on trigger.

"amplitude"  How hard, 0..16 (values above 16 are clamped — see below).
"frequency"  How fast it rattles.
"duration"   Seconds.
"radius"     Only players within this are shaken; 0 or the EVERYONE flag = all.

EVERYONE  Ignore radius, shake every player on the ground.
*/
void() env_shake =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = env_shake_use;

    // effects.cpp:1873-1874 — the spawnflag is implemented by zeroing the
    // radius, not by a separate test in UTIL_ScreenShake.
    if (self.spawnflags & SF_SHAKE_EVERYONE)
        self.radius = 0;
};
