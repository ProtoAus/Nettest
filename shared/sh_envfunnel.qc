// ============================================================================
//  shared/sh_envfunnel.qc  —  GoldSrc TE_LARGEFUNNEL
//
//  env_funnel (effects.cpp:2094-2141, CEnvFunnel) is one of the handful of HL
//  entities whose ENTIRE output is a temp entity: its Use() writes
//  TE_LARGEFUNNEL and then removes itself, and that is the whole class.  This
//  engine has no TE_LARGEFUNNEL — grep LARGEFUNNEL across engine/ returns
//  nothing — so the four corpus placements had nothing to draw even once a
//  spawn function existed.  Same structural situation, and the same fix, as
//  sh_shockwave.qc's TE_BEAMCYLINDER.
//
//  All four are teleport/portal set pieces, and the corpus uses BOTH shapes —
//  which is worth stating because it would be easy to implement only one:
//
//    hl_c01_a2  "funnel"           inward    1664 623 -368
//    hl_c01_a2  "funnel2"          OUTWARD   1664 623 -368   (same spot, later)
//    hl_c13_a4  "c3a2d_particles"  inward    0 0 -192
//    hl_c17     "end_funnel"       OUTWARD   0 0 2592
//
//  The pair on hl_c01_a2 share an origin and fire in sequence off
//  v_black_room_sounds_mm1, so that set piece sucks in and then blows out.
//
//  GEOMETRY IS THE ENGINE'S, NOT THE SDK'S.  effects.cpp only writes the temp
//  entity; the grid, the heights and the speeds live in the client's
//  R_FunnelSprite.  A 16x16 grid on a 32-unit pitch (so +-256 units), each
//  particle starting somewhere 100-800 units ABOVE the entity and ending on the
//  entity's own Z plane.  Forward funnels start out at the rim and converge on
//  the centre; reverse funnels start over the centre and fly out to the rim.
//  Note the Z leg is the same either way — a funnel always falls.
// ============================================================================

const float FUNNEL_SF_REVERSE = 1;      // SF_FUNNEL_REVERSE, effects.h

#ifdef SSQC

void(vector pos, float reverse) EnvFunnel_Multicast =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_FUNNEL);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteByte(MSG_MULTICAST, reverse ? 1 : 0);
    // ALL, matching HL's MSG_BROADCAST (effects.cpp:2113), and RELIABLE.
    //
    // PVS WAS TRIED AND IS WRONG HERE, which the test caught rather than the
    // reasoning: hl_c01_a2's two funnels sit at 0 0 -192 and 0 0 2592, sealed
    // rooms the player is not in when the multi_manager fires them, so a PVS
    // send reached nobody and the effect never drew.  Reliable for the same
    // reason the breadth is: an env_funnel deletes itself after one use, so a
    // dropped packet is not a dropped frame — it is the effect never happening
    // on that client, with no second chance for the rest of the map.  The cost
    // argument for narrowing either one does not hold, because this is at most
    // four messages in the entire corpus.
    multicast(pos, MULTICAST_ALL_R);
};

#endif // SSQC

#ifdef CSQC

// R_FunnelSprite's loop bounds: i and j each run -8..7 and are scaled by 32,
// giving a grid from -256 to +224 on both axes.  256 particles.
const float FUNNEL_GRID    = 8;
const float FUNNEL_PITCH   = 32;

// The particle recipe's `die` (particles/env.cfg).  Velocity is solved against
// this so that every particle reaches its destination exactly as it expires.
//
// DIVERGENCE, AND IT IS THE ONLY ONE.  The engine gives each particle
// vel = dist/4 + random(64,128) and then dies it at dist/vel, so travel times
// vary with distance — roughly 1.4 s for the near ones and 2.3 s for the far.
// An FTE particle's lifetime is fixed by its cfg block and cannot be set per
// emission, so the time is pinned here and the SPEED is solved per particle
// instead.  The +-15% jitter below is what keeps the arrival from being
// perfectly synchronised, which is the part the eye would actually notice.
const float FUNNEL_LIFE = 2.0;

float envfunnel_pe;         // cached effect num; 0 = unresolved, re-tries
float envfunnel_warned;     // one-shot: the first funnel of the session reports

// particleeffectnum RETURNS A SLOT EVEN FOR A NAME THAT WAS NEVER REGISTERED,
// and that slot is NEGATIVE even when the effect is perfectly valid — the
// `if (precache != P_INVALID)` guard in pr_csqc.c:3735 is commented out.
// cl_bulletimpact.qc:90-103 documents this at length and every impact effect in
// the tree resolves to a negative number.  So the sign means nothing and
// particleeffectquery is the only real validator.  Getting this wrong the other
// way costs an hour: "effect -1" in the report below reads exactly like a
// failure and is not one.
float() CSQC_EnvFunnel_Effect =
{
    if (envfunnel_pe != 0)
        return envfunnel_pe;
    envfunnel_pe = particleeffectnum("weapons.env_funnel");
    if (envfunnel_pe != 0 && particleeffectquery(envfunnel_pe, 0) == "")
        envfunnel_pe = 0;
    return envfunnel_pe;
};

void() CSQC_EnvFunnel_Parse =
{
    vector org;
    vector start;
    vector dest;
    vector dir;
    float  reverse;
    float  pe;
    float  i;
    float  j;
    float  dist;
    float  speed;

    org_x   = readcoord();
    org_y   = readcoord();
    org_z   = readcoord();
    reverse = readbyte();

    pe = CSQC_EnvFunnel_Effect();
    if (!pe)
    {
        // Reported once and only once.  A funnel that draws nothing is
        // indistinguishable from a funnel that was never fired, and the way
        // this fails is a missing `exec particles/env.cfg` line in
        // particles/weapons.cfg — which is silent everywhere else.
        if (!envfunnel_warned)
        {
            envfunnel_warned = 1;
            print("[env_funnel] particle \"weapons.env_funnel\" is not registered - is particles/env.cfg exec'd from particles/weapons.cfg?\n");
        }
        return;
    }
    if (!envfunnel_warned)
    {
        envfunnel_warned = 1;
        // The QUERY STRING, not just the slot: a bare slot number cannot be
        // read as pass or fail (see CSQC_EnvFunnel_Effect), whereas the recipe
        // name coming back is proof the cfg block registered.
        print(sprintf("[env_funnel] at %v, %s — %g particles, effect %g \"%s\"\n",
                       org, reverse ? "outward" : "inward",
                       FUNNEL_GRID * FUNNEL_GRID * 4, pe,
                       particleeffectquery(pe, 0)));
    }

    for (i = 0 - FUNNEL_GRID; i < FUNNEL_GRID; i = i + 1)
    {
        for (j = 0 - FUNNEL_GRID; j < FUNNEL_GRID; j = j + 1)
        {
            // Both modes start high and land on the entity's Z plane; only the
            // horizontal leg is mirrored.
            start_z = org_z + 100 + random() * 700;
            dest_z  = org_z;

            if (reverse)
            {
                start_x = org_x;
                start_y = org_y;
                dest_x  = org_x + i * FUNNEL_PITCH;
                dest_y  = org_y + j * FUNNEL_PITCH;
            }
            else
            {
                start_x = org_x + i * FUNNEL_PITCH;
                start_y = org_y + j * FUNNEL_PITCH;
                dest_x  = org_x;
                dest_y  = org_y;
            }

            dir  = dest - start;
            dist = vlen(dir);
            if (dist < 1)
                continue;

            speed = (dist / FUNNEL_LIFE) * (0.85 + random() * 0.3);
            pointparticles(pe, start, (dir * (1 / dist)) * speed, 1);
        }
    }
};

#endif // CSQC
