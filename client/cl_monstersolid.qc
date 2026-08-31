// client/cl_monstersolid.qc
// ----------------------------------------------------------------------------
// Make the PREDICTED player collide with monsters.
//
// THE BUG THIS EXISTS FOR: "the player collision with NPCs is not client sided
// correctly - cl_driftlock 1 shows the player sinking into the collision box
// before being shifted back out."
//
// The server has always collided properly: a live monster is SOLID_SLIDEBOX with
// a real hull (sv_ai_core.qc:3071-3079, sv_monsters.qc:1142-1150).  The CLIENT has
// never collided at all.  Monsters have no CSQC representation whatsoever - there
// is not one SendEntity in sv_monsters.qc - and a CSQC trace runs against
// csqc_world, a separate world holding only CSQC edicts and the worldmodel
// (engine pr_csqc.c:3035).  So sh_pmove.qc's tracebox, which is the SAME source
// compiled into both progs, walks the predicted player straight through a grunt,
// and the next snapshot shoves them back out.  cl_driftlock does not cause that -
// its lock branch requires !walking_on_ground, so a player walking into a monster
// always falls through to the smoother, which RENDERS the miss as a slide instead
// of a snap.  Turning it off would hide the symptom, not the error.
//
// THE FIX, at zero extra bandwidth, and it is the third time this tree has needed
// the same shape: replicated brushes get made SOLID_BSP on the client
// (cl_brushsync.qc:707-760), physics props get made SOLID_PHYSICS_BOX
// (cl_physprop.qc:1904-1909), and other players get player_visual_proxy.  Monsters
// get a small pool of SOLID_BBOX proxies driven from getentity(), relinked in the
// same slot and for the same reason as PhysProp_RelinkHullsForPrediction -
// immediately before PM_PlayerMove, so this frame's boxes are what the traces hit.
//
// Doing it with entities rather than a trace wrapper is deliberate.  sh_pmove.qc
// has 29 raw tracebox call sites and only one of them is inside PM_TraceHull; the
// ones a wrapper would miss include PM_TestPosition (stuck detection), the
// duck-stand-up fit test and PM_SoftDepenetrate.  You could stand up into a grunt.
//
// WHICH ENGINE ENTITIES ARE MONSTERS is answered by the modelindex whitelist the
// server already publishes for the bullet trace - see cl_monstertrace.qc.  This
// file adds no wire traffic of its own.
//
// >>> THE DEAD / CORPSE / SCENERY GATE IS EXACT, AND FREE. <<<
// GE_ABSMIN and GE_ABSMAX are decoded from the networked `solidsize` field
// (pr_csqc.c:6115), and sv_ents.c:3580-3593 only encodes a real hull for
// SOLID_BBOX / SOLID_SLIDEBOX / SOLID_BSP - everything else ships solidsize 0,
// which COM_DecodeSize turns into an INVERTED box (mins 0,0,0 / maxs 0,0,-32768).
// So `absmax_z > absmin_z` is a same-frame read of ent->v->solid on the server, and
// a corpse (SOLID_CORPSE) or a notsolid scenery monster fails it automatically.
// Note this is NOT the `bmin == bmax` test cl_monstertrace.qc:304 uses - that one
// does not catch these, because the box is inverted rather than degenerate.  It
// gets away with it only because the zero-width X/Y slabs make its ray test miss.
//
// EVERY UNCERTAINTY DEGRADES TO NON-SOLID.  Out of PVS, not whitelisted, inverted
// box, pool full, out of range, cvar off - all of them leave the proxy SOLID_NOT,
// which is exactly today's behaviour and therefore cannot be a regression.  That
// is the rule cl_brushsync.qc:755-759 exists to enforce: never be solid on the
// client where the server is not, because that direction rubber-bands.
//
// The server is not touched by any of this.  Not a field, not a byte, not a cvar.
// ----------------------------------------------------------------------------

// Pool size.  Deliberately small: this is "monsters close enough to walk into",
// not "monsters on the map".  pizza_ya_san1 alone places 419 assassins.
const float MONSOLID_MAX     = 32;
// Beyond this a monster cannot block a move you are about to make this frame.
const float MONSOLID_RANGE   = 512;
// Whole-pool rescan cadence.  The per-frame relink still reads every live slot's
// box; this only decides which slots are worth holding.
const float MONSOLID_RESCAN  = 0.2;

entity monsolid_ent[MONSOLID_MAX];
float  monsolid_slot[MONSOLID_MAX];   // engine entity index each proxy mirrors
float  monsolid_n;
float  monsolid_next_rescan;

// Counters, printed even when zero.  A collision that silently never happens and
// a collision that happens correctly look identical from a headless log otherwise
// - the same trap cl_monstertrace.qc documents having shipped once already.
float monsolid_dbg_live;        // whitelisted + active engine slots seen last scan
float monsolid_dbg_solid;       // ...that passed the solidsize gate and are live now
float monsolid_dbg_rej_flat;    // ...rejected for an inverted box (dead / notsolid)
float monsolid_dbg_rej_range;   // ...rejected for distance
float monsolid_dbg_poolfull;    // ...dropped because the pool was full

float(float midx) Montrace_IsMonsterIdx;   // cl_monstertrace.qc, compiled just above
void() CSQC_MonsterSolid_Report;           // defined at the foot of this file

// One proxy, created on demand and then reused forever.  Never churned: spawn()
// and remove() per monster per rescan would be the expensive part of this file.
entity(float i) MonSolid_Slot =
{
    if (!monsolid_ent[i])
    {
        entity e = spawn();
        e.classname = "csqc_monster_proxy";
        e.drawmask  = 0;              // collision only; the engine draws the monster
        e.movetype  = MOVETYPE_NONE;
        e.solid     = SOLID_NOT;      // until a relink proves otherwise
        monsolid_ent[i] = e;
    }
    return monsolid_ent[i];
};

// Is this engine entity slot a monster we should stand up a hull for, right now?
// `box_min` / `box_max` are returned through the trace-style globals below because
// QC has no multiple return.
vector monsolid_box_min;
vector monsolid_box_max;

float(float slot, vector eye) MonSolid_SlotUsable =
{
    if ((float)getentity(slot, GE_ACTIVE) == 0)
        return FALSE;
    if (!Montrace_IsMonsterIdx((float)getentity(slot, GE_MODELINDEX)))
        return FALSE;

    monsolid_box_min = (vector)getentity(slot, GE_ABSMIN);
    monsolid_box_max = (vector)getentity(slot, GE_ABSMAX);

    // The solidsize gate - see the header.  Z alone is enough and is the axis the
    // encoder cannot fake: a real hull always has height.
    if (monsolid_box_max_z <= monsolid_box_min_z)
    {
        monsolid_dbg_rej_flat = monsolid_dbg_rej_flat + 1;
        return FALSE;
    }

    vector c = (monsolid_box_min + monsolid_box_max) * 0.5;
    if (vlen(c - eye) > MONSOLID_RANGE)
    {
        monsolid_dbg_rej_range = monsolid_dbg_rej_range + 1;
        return FALSE;
    }
    return TRUE;
};

void(vector eye) MonSolid_Rescan =
{
    monsolid_n            = 0;
    monsolid_dbg_live     = 0;
    monsolid_dbg_rej_flat = 0;
    monsolid_dbg_rej_range = 0;
    monsolid_dbg_poolfull = 0;

    float maxents = (float)getentity(0, GE_MAXENTS);
    float i;
    for (i = 1; i <= maxents; i = i + 1)
    {
        if (!MonSolid_SlotUsable(i, eye))
            continue;
        monsolid_dbg_live = monsolid_dbg_live + 1;
        if (monsolid_n >= MONSOLID_MAX)
        {
            monsolid_dbg_poolfull = monsolid_dbg_poolfull + 1;
            continue;
        }
        monsolid_slot[monsolid_n] = i;
        monsolid_n = monsolid_n + 1;
    }

    // Anything the scan did not claim must stop being solid immediately - a proxy
    // left standing where its monster used to be is precisely the client-solid /
    // server-not case this file must never create.
    for (i = monsolid_n; i < MONSOLID_MAX; i = i + 1)
        if (monsolid_ent[i])
            monsolid_ent[i].solid = SOLID_NOT;
};

// Called from CSQC_PredictCurrentCommand immediately before PM_PlayerMove, beside
// PhysProp_RelinkHullsForPrediction and for the same reason.
void() MonSolid_RelinkHullsForPrediction =
{
    float i;

    if (!cvar("cl_monstersolid") || montrace_n <= 0)
    {
        // Cvar flipped off mid-game, or a map with no monsters: retire everything
        // rather than leaving stale hulls standing in the world.
        if (monsolid_n)
        {
            for (i = 0; i < MONSOLID_MAX; i = i + 1)
                if (monsolid_ent[i])
                    monsolid_ent[i].solid = SOLID_NOT;
            monsolid_n = 0;
        }
        return;
    }

    vector eye = predicted_player.origin;

    if (cltime >= monsolid_next_rescan)
    {
        monsolid_next_rescan = cltime + MONSOLID_RESCAN;
        MonSolid_Rescan(eye);
    }

    monsolid_dbg_solid = 0;

    for (i = 0; i < monsolid_n; i = i + 1)
    {
        entity p = MonSolid_Slot(i);

        // Re-ask every gate every frame.  The rescan only chose the candidates; a
        // monster can die, leave the PVS or walk out of range between rescans, and
        // each of those has to take its hull down on the very next prediction.
        if (!MonSolid_SlotUsable(monsolid_slot[i], eye))
        {
            p.solid = SOLID_NOT;
            continue;
        }

        // Centre-anchored, not origin-anchored.  PM_SoftDepenetrate and
        // PM_DisentangleFromPlayer both use .origin as the escape reference, and
        // the tree's own AABB-midpoint idiom (sv_use.qc:377, sv_momentary.qc:614)
        // exists because a GoldSrc .origin cannot be trusted to be inside the box.
        vector c = (monsolid_box_min + monsolid_box_max) * 0.5;
        setsize(p, monsolid_box_min - c, monsolid_box_max - c);
        setorigin(p, c);
        p.solid = SOLID_BBOX;
        monsolid_dbg_solid = monsolid_dbg_solid + 1;
    }

    CSQC_MonsterSolid_Report();
};

// Deliberately prints its zeroes.  `live` separates "getentity answers nothing"
// from "it answers and nothing qualified"; those look identical in `solid` and
// want completely different fixes.
//
// THREE call sites, and the third is the one that matters.  CSQC_UpdateView does
// not exist under `vid_renderer headless`, and the event parser only fires when
// something is inbound - so on the harness the pair cl_monstertrace.qc uses
// sampled exactly once, before the player had even spawned, and reported the
// zeroes of an empty world as though they were a result.  This one is called from
// the relink itself, which runs once per predicted command whatever the renderer
// is doing.  Self-rate-limited, so a third caller costs one float compare.
float monsolid_next_report;

void() CSQC_MonsterSolid_Report =
{
    if (!cvar("developer"))
        return;
    if (montrace_n <= 0)
        return;
    if (cltime < monsolid_next_report)
        return;
    monsolid_next_report = cltime + 2;

    print(sprintf("[monsolid] on=%g pool=%g live=%g solid=%g flat=%g range=%g full=%g\n",
                  cvar("cl_monstersolid") ? 1 : 0, monsolid_n,
                  monsolid_dbg_live, monsolid_dbg_solid,
                  monsolid_dbg_rej_flat, monsolid_dbg_rej_range,
                  monsolid_dbg_poolfull));
};
