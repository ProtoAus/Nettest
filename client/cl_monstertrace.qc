// client/cl_monstertrace.qc
// ----------------------------------------------------------------------------
// Make the SHOOTER's own bullets stop on monsters.
//
// THE BUG THIS EXISTS FOR: "when I shoot the NPCs they don't bleed like shooting
// a player".  That is the symptom; the cause is bigger than blood.
//
// The person firing is the only person who never receives the server's impact
// event - W_ImpactEffectSend skips the shooter (sv_weapons.qc:918) so their own
// predicted ricochet is not echoed back a ping later on top of itself.  Their
// whole visual is therefore CSQC's LOCAL trace.  And CSQC cannot see monsters:
// they are plain engine-networked entities, not CSQC entities, so a CSQC
// traceline passes straight through a monster and hits the wall behind it.
//
// So shooting a headcrab did not merely fail to produce blood.  It produced a
// concrete-dust puff AND a bullet hole on the wall behind, at the wrong depth,
// with the tracer visibly overshooting through the body.  Everyone ELSE watching
// saw it correctly, because they get the server's version.
//
// THE FIX, at zero extra bandwidth: getentity() (#504) exposes engine entities to
// CSQC - GE_ACTIVE, GE_ORIGIN, GE_ABSMIN, GE_ABSMAX, GE_MODELINDEX - so the ray
// test can be done here.  This is the same technique cl_physprop.qc already uses
// for barrels and cans (CSQC_PhysProp_OverrideTrace), and it slots into the same
// place in the fire path.
//
// The one thing CSQC cannot work out for itself is WHICH engine entities are
// monsters, so the server publishes the set of monster modelindexes once per map
// (CSQC_EVENT_MONSTER_MODELS, AI_PublishMonsterModels in sv_ai_core.qc).  A
// hardcoded list here would have been shorter and wrong: Sven maps ship custom
// monster models constantly and Monster_Build honours a per-placement `model`
// override, so the set is genuinely per-map.
// ----------------------------------------------------------------------------

const float MONTRACE_MAX_MODELS = 64;
float montrace_idx[MONTRACE_MAX_MODELS];
float montrace_n;

// One reusable stand-in so trace_ent has something with a classname on it.  The
// impact classifier keys on the classname exactly as it does for
// player_visual_proxy, and one shared entity is enough because the trace globals
// only ever describe a single hit at a time.
entity montrace_proxy;

// Counters.  A local visual effect leaves no trace in a headless log, so without
// these "the sweep ran and found nothing" and "the sweep never ran" are the same
// observation - which is the exact trap that let the original bug ship.
float montrace_dbg_sweeps;	// fire traces that ran the sweep
float montrace_dbg_hits;	// ...that landed on a monster

void() CSQC_MonsterModels_Parse =
{
	float n = readbyte();
	montrace_n = 0;
	float i;
	for (i = 0; i < n; i = i + 1)
	{
		float mi = readshort();
		// Read every one off the wire even if the table is full, or the byte
		// stream desyncs and every event after this is garbage.
		if (montrace_n < MONTRACE_MAX_MODELS)
		{
			montrace_idx[montrace_n] = mi;
			montrace_n = montrace_n + 1;
		}
	}
	if (cvar("developer"))
		print(sprintf("[montrace] %g monster modelindexes registered\n", montrace_n));
};

float(float midx) Montrace_IsMonsterIdx =
{
	if (midx <= 0)
		return FALSE;
	float i;
	for (i = 0; i < montrace_n; i = i + 1)
		if (montrace_idx[i] == midx)
			return TRUE;
	return FALSE;
};

// Slab method, axis-aligned.  Returns the distance along `dir_unit` at which the
// ray enters the box, or -1 for a miss.  `mt_hit_normal` is set to the face that
// was entered, which the impact FX use to orient the particle spray.
vector mt_hit_normal;

float(vector src, vector dir_unit, float maxdist, vector bmin, vector bmax) Montrace_RayBox =
{
	float tmin = 0, tmax = maxdist;
	vector n_min = '0 0 0', n_max = '0 0 0';

	// fteqcc scopes locals to the whole FUNCTION, not the block, so the three
	// axes share one set of temporaries rather than redeclaring them (which
	// compiles, with three warnings per axis, and silently aliases anyway).
	float inv, t1, t2, sw;
	vector nn;

	// X
	if (dir_unit_x == 0)
	{
		if (src_x < bmin_x || src_x > bmax_x) return -1;
	}
	else
	{
		inv = 1 / dir_unit_x;
		t1 = (bmin_x - src_x) * inv;
		t2 = (bmax_x - src_x) * inv;
		nn = '-1 0 0';
		if (t1 > t2) { sw = t1; t1 = t2; t2 = sw; nn = '1 0 0'; }
		if (t1 > tmin) { tmin = t1; n_min = nn; }
		if (t2 < tmax) tmax = t2;
		if (tmin > tmax) return -1;
	}

	// Y
	if (dir_unit_y == 0)
	{
		if (src_y < bmin_y || src_y > bmax_y) return -1;
	}
	else
	{
		inv = 1 / dir_unit_y;
		t1 = (bmin_y - src_y) * inv;
		t2 = (bmax_y - src_y) * inv;
		nn = '0 -1 0';
		if (t1 > t2) { sw = t1; t1 = t2; t2 = sw; nn = '0 1 0'; }
		if (t1 > tmin) { tmin = t1; n_min = nn; }
		if (t2 < tmax) tmax = t2;
		if (tmin > tmax) return -1;
	}

	// Z
	if (dir_unit_z == 0)
	{
		if (src_z < bmin_z || src_z > bmax_z) return -1;
	}
	else
	{
		inv = 1 / dir_unit_z;
		t1 = (bmin_z - src_z) * inv;
		t2 = (bmax_z - src_z) * inv;
		nn = '0 0 -1';
		if (t1 > t2) { sw = t1; t1 = t2; t2 = sw; nn = '0 0 1'; }
		if (t1 > tmin) { tmin = t1; n_min = nn; }
		if (t2 < tmax) tmax = t2;
		if (tmin > tmax) return -1;
	}

	if (tmax < 0)
		return -1;

	// Starting INSIDE the box (point-blank, muzzle overlapping the body) leaves
	// tmin at 0 with no entry face.  Treat it as an immediate hit facing back
	// down the ray rather than rejecting it - a contact shot must still bleed.
	if (tmin <= 0)
	{
		mt_hit_normal = dir_unit * -1;
		return 0;
	}

	mt_hit_normal = n_min;
	return tmin;
};

// Called from the shared fire path, immediately after the engine traceline and
// alongside the physics-prop override.  Overrides the trace globals if a monster
// sits closer than whatever the engine trace found.
void(vector trace_src, vector trace_end) CSQC_Monster_OverrideTrace =
{
	if (montrace_n <= 0)
		return;			// no monsters on this map, or the set has not arrived

	vector dir = trace_end - trace_src;
	float dirlen = vlen(dir);
	if (dirlen < 0.001)
		return;
	vector dir_unit = dir * (1 / dirlen);

	montrace_dbg_sweeps = montrace_dbg_sweeps + 1;

	// Distance the current best hit sits at.  A clean miss counts as the full
	// ray length, so any monster along it wins.
	float best_t = trace_fraction * dirlen;
	if (trace_fraction >= 1.0)
		best_t = dirlen;

	float found = FALSE;
	vector best_normal = '0 0 0';
	vector best_pos = '0 0 0';

	float maxents = (float)getentity(0, GE_MAXENTS);
	if (maxents <= 0)
		return;
	if (maxents > 4096)
		maxents = 4096;

	float i;
	for (i = 1; i < maxents; i = i + 1)
	{
		if ((float)getentity(i, GE_ACTIVE) == 0)
			continue;

		// Cheapest test first, by a wide margin: one array walk over a handful of
		// shorts rejects every crate, door and light in the map before any vector
		// maths happens.
		if (!Montrace_IsMonsterIdx((float)getentity(i, GE_MODELINDEX)))
			continue;

		vector bmin = (vector)getentity(i, GE_ABSMIN);
		vector bmax = (vector)getentity(i, GE_ABSMAX);
		if (bmin == bmax)
			continue;		// degenerate / no size known

		float t = Montrace_RayBox(trace_src, dir_unit, dirlen, bmin, bmax);
		if (t < 0 || t >= best_t)
			continue;

		best_t      = t;
		best_normal = mt_hit_normal;
		best_pos    = trace_src + dir_unit * t;
		found       = TRUE;
	}

	if (!found)
		return;

	montrace_dbg_hits = montrace_dbg_hits + 1;

	// Stand the proxy up lazily - a map with no monsters never allocates it.
	if (!montrace_proxy)
	{
		montrace_proxy = spawn();
		montrace_proxy.classname = "csqc_monster_proxy";
		montrace_proxy.drawmask  = 0;		// never rendered; it is a label
		montrace_proxy.solid     = SOLID_NOT;
	}

	trace_fraction     = best_t / dirlen;
	trace_endpos       = best_pos;
	trace_plane_normal = best_normal;
	trace_ent          = montrace_proxy;
	// The engine trace set these from whatever it hit; a monster has no BSP
	// surface, and leaving stale values behind would let the surface->material
	// fallback in Impact_ClassifyLocal resolve a texture that is not there.
	trace_surfaceflags = 0;
	trace_endcontents  = 0;
};

void() CSQC_MonsterTrace_Report =
{
	if (!montrace_dbg_sweeps)
		return;
	print(sprintf("[montrace] models=%g sweeps=%g monster-hits=%g\n",
	              montrace_n, montrace_dbg_sweeps, montrace_dbg_hits));
	montrace_dbg_sweeps = 0;
	montrace_dbg_hits = 0;
};
