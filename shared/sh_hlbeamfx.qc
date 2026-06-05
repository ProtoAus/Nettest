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

#ifdef SSQC

void(float beam_kind, entity owner, vector beam_start, vector beam_end) HLBeam_Multicast =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_HL_BEAM);
    WriteByte(MSG_MULTICAST, owner ? num_for_edict(owner) : 0);
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

float hlbeam_gauss_effect;
float hlbeam_egon_effect;
float hlbeam_fallback_effect;
float hlbeam_effects_resolved;

void() HLBeam_ResolveEffects =
{
    if (hlbeam_effects_resolved)
        return;

    hlbeam_gauss_effect    = particleeffectnum("weapons.gauss_beam");
    hlbeam_egon_effect     = particleeffectnum("weapons.egon_beam");
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

    exclude_entnum = readbyte();
    beam_kind = readbyte();

    beam_start_x = readcoord();
    beam_start_y = readcoord();
    beam_start_z = readcoord();
    beam_end_x = readcoord();
    beam_end_y = readcoord();
    beam_end_z = readcoord();

    if (exclude_entnum == player_localentnum)
        return;

    owner_ent = world;
    if (exclude_entnum > 0)
        owner_ent = findfloat(world, entnum, exclude_entnum);

    HLBeam_Draw(beam_kind, owner_ent, beam_start, beam_end);
};

#endif // CSQC
