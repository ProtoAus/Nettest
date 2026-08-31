// ============================================================
//  shared/sh_envblood.qc  -  env_blood, the mapper-fired blood spray
//
//  HL's CBlood (effects.cpp:1718) is a point entity that sprays blood when
//  triggered: a burst of drips, or a directed stream, optionally stamping a
//  decal where the spray lands.  Six of the They Hunger maps use it for set
//  dressing that fires on entry — the tower kill, the rat, the smashed
//  paint cans in ep1.
//
//  IT HAS TO BE A CSQC EVENT, and the reason is structural rather than a
//  preference: the particle config is only ever loaded into the CLIENT VM, so
//  a server-side pointparticles() cannot resolve a recipe name at all.  That is
//  written up at sv_physprop.qc:557 and is the same wall env_spark and the
//  breakables hit.  So the server sends the WHAT and the client owns the HOW,
//  exactly as shared/sh_alienfx.qc does for the creature effects.
// ============================================================

// effects.cpp:1743-1746.
const float SF_BLOOD_RANDOM = 1;    // ignore `angles`, pick a direction per burst
const float SF_BLOOD_STREAM = 2;    // a jet rather than a puff
const float SF_BLOOD_PLAYER = 4;    // spray at the activating player's eyes
const float SF_BLOOD_DECAL  = 8;    // stamp where the spray lands

const float BLOODCOL_RED    = 0;
const float BLOODCOL_YELLOW = 1;

#ifdef SSQC

void(vector pos, vector dir, float amount, float col, float flags) EnvBlood_Multicast =
{
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_BLOOD);
	WriteCoord(MSG_MULTICAST, pos_x);
	WriteCoord(MSG_MULTICAST, pos_y);
	WriteCoord(MSG_MULTICAST, pos_z);
	// Unit vector quantised to three signed bytes — the same encoding
	// AlienFX_Multicast and W_ImpactEffectSend use.
	WriteByte(MSG_MULTICAST, bound(0, rint(127 + dir_x * 127), 255));
	WriteByte(MSG_MULTICAST, bound(0, rint(127 + dir_y * 127), 255));
	WriteByte(MSG_MULTICAST, bound(0, rint(127 + dir_z * 127), 255));
	WriteShort(MSG_MULTICAST, bound(0, rint(amount), 32767));
	WriteByte(MSG_MULTICAST, col);
	WriteByte(MSG_MULTICAST, flags);
	multicast(pos, MULTICAST_PVS);
};

#endif // SSQC

#ifdef CSQC

// cl_bloodsplat.qc owns the projected decal quads.  Forward-declared rather
// than reordered: this file sits with the other shared FX, ahead of the client
// half of the blood system.
void(vector pos, vector normal) CSQC_SpawnBloodDecalAt;

float envblood_fx_red;
float envblood_fx_yellow;
float envblood_fx_resolved;

// particleeffectnum RETURNS A SLOT FOR A NAME THAT WAS NEVER REGISTERED, so the
// number alone proves nothing — cl_bulletimpact.qc:90 documents the trap at
// length and this reuses its answer rather than restating it.  A recipe that
// does not exist simply draws nothing; the decal half still works, which is the
// half that persists and is therefore the half a mapper notices.
void() EnvBlood_ResolveFX =
{
	if (envblood_fx_resolved)
		return;
	envblood_fx_resolved = TRUE;
	envblood_fx_red    = particleeffectnum("weapons.flesh_impact");
	envblood_fx_yellow = particleeffectnum("weapons.flesh_impact_lethal");
};

void() CSQC_EnvBlood_Parse =
{
	vector pos, dir;
	pos_x = readcoord();
	pos_y = readcoord();
	pos_z = readcoord();
	dir_x = (readbyte() - 127) * (1.0 / 127.0);
	dir_y = (readbyte() - 127) * (1.0 / 127.0);
	dir_z = (readbyte() - 127) * (1.0 / 127.0);
	float amount = readshort();
	float col    = readbyte();
	float flags  = readbyte();

	EnvBlood_ResolveFX();

	float fx = (col == BLOODCOL_YELLOW) ? envblood_fx_yellow : envblood_fx_red;

	// `amount` is HL's "damage to simulate" (effects.cpp:1740) — the corpus
	// runs 100 to 500.  UTIL_BloodDrips scales its particle count by it; we
	// scale the pointparticles count the same way and cap it, because a 500
	// on a stream would otherwise ask for a spray no one is looking at.
	float count = bound(1, rint(amount * 0.1), 48);

	// A stream is a jet: fewer, faster, tightly along the direction.  A puff
	// is the default burst, thrown outward at the impact speed the flesh
	// recipe already expects.
	float speed = (flags & SF_BLOOD_STREAM) ? 220 : 90;

	if (fx > 0)
		pointparticles(fx, pos, dir * speed, count);

	// effects.cpp:1826 — trace out along the spray and stamp where it lands.
	// HL traces `amount * 2` units, which for the corpus is 200..1000.
	if (flags & SF_BLOOD_DECAL)
	{
		vector end = pos + dir * (amount * 2);
		traceline(pos, end, TRUE, world);
		if (trace_fraction < 1)
			CSQC_SpawnBloodDecalAt(trace_endpos, trace_plane_normal);
	}
};

#endif // CSQC
