// ============================================================
//  shared/sh_hlbeamfx.qc  -  HL Gauss/Egon beam visuals
//
//  Valve's FTEmod renders these with named particle beam effects
//  driven from a custom server->CSQC event. This module mirrors that
//  pattern for this mod's event system, with local prediction drawing
//  the shooter's own beam immediately.
// ============================================================

const float HL_BEAM_GAUSS = 0;
const float HL_BEAM_EGON  = 1;
// Opposing Force's shock rifle, which monster_shocktrooper carries (208
// placements).  A third KIND rather than a recoloured egon, because the kind is
// what rides the wire and what picks both the recipe and the dlight colour:
// borrowing HL_BEAM_EGON would have given a green energy bolt a blue Xen glow
// on every client, and there would then be no way to tell the two apart.
const float HL_BEAM_SHOCK = 2;
// The alien slave's ARM BEAMS - CISlave::ArmBeam (islave.cpp:723-762), the arcs
// that crawl from its hands onto nearby geometry while it winds a zap up.  A
// fourth kind because it is the only beam here that is not a weapon discharge:
// it is dim (HL brightness 64 against the egon's 255), noisy (noise 80), short,
// and it wants no dynamic light at all - a slave charging in a corridor should
// crackle, not floodlight the room.
const float HL_BEAM_ARC   = 3;
// The gargantua's FLAME, gargantua.cpp:492-546.  Half-Life builds it from four
// CBeams of sprites/xbeam3.spr: two at width 240 tinted 255/130/90 and two at
// width 140 tinted 0/120/255, all at brightness 190 with BEAM_FSHADEIN and a
// scroll rate of 20.  xbeam3.spr itself is a plain white ramp, so both colours
// are runtime tints and the SDK is the only authority for them.
//
// One kind rather than two, with the blue inner carried by the +garg_flame
// sub-recipe: the pair are one visual, always drawn together, and splitting them
// across the wire would double the traffic on the only attack here that fires
// continuously for four and a half seconds.
const float HL_BEAM_FLAME = 4;

#ifdef SSQC

// ============================================================
//  REAL GOLDSRC BEAMS FOR WEAPONS
//
//  HLBeam_Multicast above draws a PARTICLE STREAK.  That recipe has no sprite,
//  no width, no noise amplitude and no scroll rate — those concepts do not exist
//  in the r_part beam type — which is why the gauss and egon never read as
//  Half-Life beams no matter how the recipe was tuned.
//
//  cl_env_beam.qc already implements every parameter R_BeamEntPoint takes, and
//  sh_wpn_hltripmine.qc already drives it from weapon code.  These helpers
//  generalise the tripmine's W_TripmineBeamSend so the gauss and egon can use
//  the same renderer.  Same prototype-and-redeclare pattern and the same reason:
//  server/sv_env_beam.qc compiles long after this file.
//
//  UNITS: BoltWidth and NoiseAmplitude are TENTHS of a unit, matching
//  CBeam::BeamCreate(sprite, width) / SetNoise() in the SDK — so egon.cpp's
//  BeamCreate(EGON_BEAM_SPRITE, 40) is 4.0 units and goes in here as 40.
//  TextureScroll is signed and in the SDK's own SetScrollRate units.
// ============================================================
float(entity ent, float changedflags) EnvBeam_SendEntity;
.float  renderamt;
.vector rendercolor;
.float  BoltWidth;
.float  NoiseAmplitude;
.float  TextureScroll;
.float  framerate;
.float  framestart;
.vector ebeam_start_pos;
.vector ebeam_end_pos;
.float  ebeam_active;
.float  ebeam_sprite_index;
.float  ebeam_end_sprite_index;

void() HLBeam_EntExpire = { remove(self); };

// FL_SKIPLOCALHOST, as a SendEntity filter.
//
// HL never draws a server beam for the player who fired it (egon.cpp sets
// FL_SKIPLOCALHOST on both CBeams); that client draws its own predicted pair in
// ev_hldm.cpp instead, so a swept beam tracks the crosshair with no round trip.
// This reproduces the same split: observers get the networked entity below, the
// shooter gets CSQC_EnvBeam_Local (client/cl_env_beam.qc) from its own predict
// path.  Without this filter the shooter would see BOTH, one lagging the other.
//
// Same shape as projectile_SendEntity's owner exclusion, which is the
// established way this tree hides an entity from its own creator.
float(entity to, float changedflags) HLBeam_SendEntity =
{
    if (to == self.owner)
        return FALSE;
    return EnvBeam_SendEntity(to, changedflags);
};

// Create-or-refresh a beam entity.  Pass `b` as world to create one; the caller
// keeps the returned entity and hands it back next tick, so a sustained beam is
// ONE networked entity for its whole life rather than an event per frame.  That
// is what HL does too (its beams are life 99999, killed on stop) and it is why
// the egon read as a flicker here: the old path re-emitted a 0.18 s recipe on
// every server AND client frame.
// NOTE: the owner parameter is `beam_owner`, not `owner` — a parameter named
// `owner` shadows the .owner entity FIELD, and `b.owner = owner` then fails to
// compile with "owner is not a field".
// end_sprite is optional: a modelindex painted as an additive billboard at the
// beam's far end (cl_env_beam.qc already draws this for env_laser's EndSprite).
// It is how the gauss gets HL's hotglow impact flare onto the networked beam and
// the shooter's local one at once, without a second entity type on either side.
entity(entity b, entity beam_owner, vector from, vector to, float sprite_idx,
       vector col, float bright, float width, float noise, float scroll,
       float end_sprite) HLBeam_EntUpdate =
{
    if (!b)
    {
        b = spawn();
        b.classname  = "hl_weapon_beam";
        b.owner      = beam_owner;
        b.SendEntity = HLBeam_SendEntity;
        b.framestart = 0;
        b.framerate  = 0;
        // A weapon beam is long and thin, so the leaf its ORIGIN happens to sit
        // in is a poor proxy for whether any of it is visible.  env_beam uses
        // the PHS for exactly this reason (sv_env_beam.qc), and NOREMOVE keeps
        // a sustained beam alive across a brief PVS drop instead of making the
        // client re-create it.
        b.pvsflags   = PVSF_USEPHS | PVSF_NOREMOVE;
    }
    // Compute this BEFORE overwriting the fields.  A sustained beam is refreshed
    // every weapon frame, and the egon refreshes TWO of them, so pulsing
    // SendFlags unconditionally re-sent ~30 bytes per beam at 20 Hz per firing
    // player for data that had not changed.  env_beam's own tick makes the same
    // test (EnvBeam_DamageTick, sv_env_beam.qc).  The egon's core beam DOES
    // change every frame (its colour pulses on a sine), so this is a saving on
    // the wash beam and on any beam whose owner is standing still — not a
    // behaviour change.
    float beam_changed = (b.ebeam_start_pos    != from
                       || b.ebeam_end_pos      != to
                       || b.ebeam_sprite_index != sprite_idx
                       || b.rendercolor        != col
                       || b.renderamt          != bright
                       || b.BoltWidth          != width
                       || b.NoiseAmplitude     != noise
                       || b.TextureScroll      != scroll
                       || b.ebeam_end_sprite_index != end_sprite
                       || !b.ebeam_active);

    b.ebeam_sprite_index = sprite_idx;
    b.rendercolor        = col;
    b.renderamt          = bright;
    b.BoltWidth          = width;
    b.NoiseAmplitude     = noise;
    b.TextureScroll      = scroll;
    b.ebeam_active       = TRUE;
    b.ebeam_start_pos    = from;
    b.ebeam_end_pos      = to;
    b.ebeam_end_sprite_index = end_sprite;
    setorigin(b, from);
    if (beam_changed)
        b.SendFlags = 1;

    // DEAD-MAN TIMER.  A sustained beam is refreshed every weapon frame, so if
    // it ever stops being refreshed the owner has died, disconnected, dropped
    // the gun, or hit a path that forgot to tear it down — and a persistent
    // networked entity that nothing owns any more would just hang in the air.
    // Re-arming it here means the beam cannot outlive its owner by more than
    // this, whatever the caller forgets.  Callers that tear down explicitly
    // (W_EgonBeamHide) still do, and should; this is the backstop, not the plan.
    b.think     = HLBeam_EntExpire;
    b.nextthink = time + 0.3;
    return b;
};

// One-shot beam that removes itself after `life` seconds — the gauss's shape,
// where HL uses R_BeamPoints with life 0.1 rather than a persistent CBeam.
void(entity beam_owner, vector from, vector to, float sprite_idx, vector col,
     float bright, float width, float noise, float scroll, float life,
     float end_sprite) HLBeam_EntFlash =
{
    entity b = HLBeam_EntUpdate(world, beam_owner, from, to, sprite_idx,
                                col, bright, width, noise, scroll, end_sprite);
    b.think     = HLBeam_EntExpire;
    b.nextthink = time + life;
};

void(entity b) HLBeam_EntKill =
{
    if (b)
        remove(b);
};

void(float beam_kind, entity owner, vector beam_start, vector beam_end) HLBeam_Multicast =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_HL_BEAM);
    // SHORT, not byte.  This doubles as the local-player exclude test AND the
    // beam's owner handle, so a truncated number does two wrong things at once:
    // it can silently suppress the beam for an innocent client whose entnum
    // happens to match (n & 255), and it anchors the trail on the wrong entity.
    // monster_alien_slave alone is 726 placements and fires exactly this beam,
    // so monster edict numbers past 255 are the normal case, not an edge one.
    WriteShort(MSG_MULTICAST, owner ? num_for_edict(owner) : 0);
    WriteByte(MSG_MULTICAST, beam_kind);
    WriteCoord(MSG_MULTICAST, beam_start_x);
    WriteCoord(MSG_MULTICAST, beam_start_y);
    WriteCoord(MSG_MULTICAST, beam_start_z);
    WriteCoord(MSG_MULTICAST, beam_end_x);
    WriteCoord(MSG_MULTICAST, beam_end_y);
    WriteCoord(MSG_MULTICAST, beam_end_z);
    multicast(beam_start, MULTICAST_PVS);
};

#endif // SSQC

#ifdef CSQC

// Forward declaration — cl_spectate.qc is compiled after this file, and
// HLBeam_Parse below needs to know whether we are watching someone else.
float() Spectate_IsActive;

float hlbeam_gauss_effect;
float hlbeam_egon_effect;
float hlbeam_shock_effect;
float hlbeam_arc_effect;
float hlbeam_flame_effect;
float hlbeam_fallback_effect;
float hlbeam_effects_resolved;

void() HLBeam_ResolveEffects =
{
    if (hlbeam_effects_resolved)
        return;

    hlbeam_gauss_effect    = particleeffectnum("weapons.gauss_beam");
    hlbeam_egon_effect     = particleeffectnum("weapons.egon_beam");
    hlbeam_shock_effect    = particleeffectnum("weapons.shock_beam");
    hlbeam_arc_effect      = particleeffectnum("weapons.islave_arc");
    hlbeam_flame_effect    = particleeffectnum("weapons.garg_flame");
    hlbeam_fallback_effect = particleeffectnum("weapons.rifletracer");
    hlbeam_effects_resolved = TRUE;
};

float(float beam_kind) HLBeam_EffectFor =
{
    HLBeam_ResolveEffects();
    if (beam_kind == HL_BEAM_EGON && hlbeam_egon_effect != 0)
        return hlbeam_egon_effect;
    if (beam_kind == HL_BEAM_GAUSS && hlbeam_gauss_effect != 0)
        return hlbeam_gauss_effect;
    if (beam_kind == HL_BEAM_SHOCK && hlbeam_shock_effect != 0)
        return hlbeam_shock_effect;
    if (beam_kind == HL_BEAM_ARC && hlbeam_arc_effect != 0)
        return hlbeam_arc_effect;
    if (beam_kind == HL_BEAM_FLAME && hlbeam_flame_effect != 0)
        return hlbeam_flame_effect;
    return hlbeam_fallback_effect;
};

void(float beam_kind, entity owner, vector beam_start, vector beam_end) HLBeam_Draw =
{
    float effect_num = HLBeam_EffectFor(beam_kind);
    vector beam_mid;

    if (effect_num != 0)
        trailparticles(effect_num, owner, beam_start, beam_end);

    beam_mid = (beam_start + beam_end) * 0.5;
    if (beam_kind == HL_BEAM_EGON)
    {
        dynamiclight_add(beam_mid, 80, '0.25 0.45 1.0');
        dynamiclight_add(beam_end, 72, '0.35 0.55 1.0');
    }
    else if (beam_kind == HL_BEAM_SHOCK)
    {
        // CYAN, and that is measured rather than remembered.  The shock rifle is
        // widely described as a green weapon; its own muzzle sprite is not.
        // sprites/muzzle_shock.spr (gearbox, 32x32, 3 frames) has a 256-entry
        // palette whose whole ramp sits at red ~= 0:
        //     (0,251,252) (1,213,237) (0,184,196) (4,148,203) (2,94,145)
        // so the brightest colour in the file is very nearly pure cyan.  Guessing
        // green here would have been a plausible, checkable, wrong answer.
        dynamiclight_add(beam_mid, 88,  '0.05 0.90 0.96');
        dynamiclight_add(beam_end, 104, '0.15 1.00 1.00');
    }
    else if (beam_kind == HL_BEAM_ARC)
    {
        // NO DYNAMIC LIGHT, deliberately.  Half-Life's arm beams are brightness
        // 64 out of 255 and cast none - and up to eight of them are alive at once
        // during a wind-up, so a light per arc would pulse a corridor eight times
        // brighter than the zap that follows it.  The arc is a texture, not a
        // light source.
    }
    else if (beam_kind == HL_BEAM_FLAME)
    {
        // Warm at the muzzle, warm at the far end, and BRIGHT: this is the only
        // sustained attack in the game, so unlike the one-shot beams it really is
        // a light source for as long as it burns.  The colours track the SDK's
        // 255/130/90 outer tint rather than the 0/120/255 inner one, because a
        // blue-lit room around an orange flame reads as a bug.
        dynamiclight_add(beam_start, 120, '1.00 0.52 0.32');
        dynamiclight_add(beam_mid,   104, '1.00 0.45 0.22');
        dynamiclight_add(beam_end,   128, '1.00 0.60 0.30');
    }
    else
    {
        dynamiclight_add(beam_mid, 96, '1.0 0.55 0.10');
        dynamiclight_add(beam_end, 112, '1.0 0.45 0.05');
    }
};

void() HLBeam_Parse =
{
    float exclude_entnum;
    float beam_kind;
    vector beam_start;
    vector beam_end;
    entity owner_ent;

    exclude_entnum = readshort();	// SHORT — must match HLBeam_Multicast above
    beam_kind = readbyte();

    beam_start_x = readcoord();
    beam_start_y = readcoord();
    beam_start_z = readcoord();
    beam_end_x = readcoord();
    beam_end_y = readcoord();
    beam_end_z = readcoord();

    // Skip the beam for the player who fired it — their own CSQC prediction
    // already drew it, and drawing the multicast copy too would double it.
    //
    // ...but ONLY when we are actually playing.  While spectating, FTE points
    // player_localentnum at the TRACKED player (pr_csqc.c sets it from
    // Cam_TrackNum), so this test matched the person being watched and threw
    // their beam away — and prediction, the other beam source, does not run for
    // a spectated player either.  The result was a gauss/egon/shock-rifle user
    // firing with no beam at all on a spectator's screen, and the same for
    // alien-slave arcs and gargantua flame.
    if (!Spectate_IsActive() && exclude_entnum == player_localentnum)
        return;

    owner_ent = world;
    if (exclude_entnum > 0)
        owner_ent = findfloat(world, entnum, exclude_entnum);

    HLBeam_Draw(beam_kind, owner_ent, beam_start, beam_end);
};

#endif // CSQC
