//
//  sv_goldsrc_effects.qc  –  gibshooter / env_shooter / env_glow / env_blood
//
//  Four HL/GoldSrc point entities that every They Hunger episode places and
//  that this mod either did not have at all (gibshooter, env_glow, env_blood)
//  or accepted as an inert stub (env_shooter, which sat on GoldSrc_InertMonster
//  in sv_goldsrc_compat.qc:268 — spawned, invisible, doing nothing).
//
//  Corpus counts across the 20 They Hunger maps + pizza_ya_san1/2:
//      env_shooter   55 placements / 15 maps
//      env_glow      49 placements /  8 maps   (all episode 3 + th_escape)
//      gibshooter    28 placements / 12 maps
//      env_blood      8 placements /  6 maps
//
//  env_shooter is the largest of the four and was NOT in the original plan —
//  it only surfaced because the key census dumped every classname's real keys
//  rather than trusting the "unimplemented" list, and a stub counts as
//  implemented.  It is also nearly free here: HL's CEnvShooter *derives from*
//  CGibShooter (effects.cpp:1520) and adds one model key, so both classes are
//  the same code with a different default model.
//
//  Source of truth: halflife/dlls/effects.cpp — CGibShooter at :1346,
//  CEnvShooter at :1520, CGlow at :1112, CBlood at :1718.  Keys and defaults
//  cross-checked against Sven's sven-coop.fgd (GibShooterBase at :629,
//  env_shooter at :1940, env_glow at :1836, env_blood at :1736).
//

// sv_push.qc compiles after us — same forward declaration sv_doors.qc:62 uses.
void() SetMovedir;
// sv_brushsync.qc, for the rendermode/renderamt/rendercolor/renderfx keys.
void() BrushSync_ApplyRenderKeys;

// ---------------------------------------------------------------------------
//  Map keys.
//
//  DECLARED LOWER CASE ON PURPOSE.  Entity keys are matched with strcmp
//  (ED_FindField), and GoldSrc map compilers disagree about the casing they
//  write — the BSPs here spell it "m_iGibs" but other compilers emit
//  "m_igibs".  GoldSrc_TryCaseFoldedField (sv_multi_manager.qc:410) retries a
//  missed key folded to lower case, so a lower-case declaration is the one
//  spelling that catches BOTH.  Same reasoning as .m_flcustomrespawntime.
// ---------------------------------------------------------------------------
.float  m_igibs;          // how many pieces to throw          (default 3)
.float  m_flvelocity;     // launch speed                      (default 200)
.float  m_flvariance;     // cone spread, 0..1                 (default 0.15)
.float  m_flgiblife;      // seconds each piece survives       (default 4)
.string shootmodel;       // env_shooter only — what to throw
.float  shootsounds;      // env_shooter only — material index, -1 = silent

// .body is a real entvar in this engine (PEXT2_BODYGROUP); .skin and .scale are
// engine fields.  .body already exists — sv_cycler.qc:50 owns the declaration
// and compiles ahead of us — so this line is only here to keep the file
// readable on its own; duplicate .float declarations of matching type share one
// slot, the same arrangement sv_env_sprite.qc has with .sequence.
.float  body;

const float SF_GIBSHOOTER_REPEATABLE = 1;   // effects.cpp:26

// Resolved once at spawn so the think never re-derives them.
.vector gs_aim;           // angles, saved before SetMovedir zeroes them
.float  gs_remaining;     // shots left in this burst
.float  gs_capacity;      // reload value for REPEATABLE
.float  gs_delay;         // seconds between shots
.string gs_model;         // what to throw
.float  gs_bodies;        // submodel count of gs_model (see Shooter_BodyCount)
.string gs_matsnd;        // sh_matsounds.qc set name, "" = silent

// Per-gib.
.float  gib_born;         // spawn time — the reaper picks the oldest
.float  gib_expire;
.string gib_matsnd;

// ---------------------------------------------------------------------------
//  How many submodels a gib model carries.
//
//  Half-Life asks the engine (`pev->body = MODEL_FRAMES(m_iGibModelIndex)`,
//  effects.cpp:1443) and then throws a random body in 1..body-1 so the skull,
//  which is submodel 0 of hgibs.mdl, does not come out five at a time.  QC has
//  no equivalent call: modelframecount() answers about SPRITE frames and is not
//  the submodel count for a studio model, so asking it would quietly give every
//  gib body 0 — one model, repeated.
//
//  So the counts are a table, read out of the .mdl headers on disk rather than
//  remembered (studiohdr numbodyparts/bodypartindex -> mstudiobodyparts_t
//  nummodels).  Everything not listed is a single-submodel prop — which is all
//  but one of the models the corpus actually throws — and gets body 0.
// ---------------------------------------------------------------------------
float(string mdl) Shooter_BodyCount =
{
    if (mdl == "models/hgibs.mdl")           return 11;
    if (mdl == "models/metalplategibs.mdl")  return 13;
    if (mdl == "models/agibs.mdl")           return 4;
    if (mdl == "models/fleshgibs.mdl")       return 4;
    return 1;
};

// shootsounds index -> sh_matsounds.qc set name.  MatSnd_Pick returns "" for a
// set the material config does not define, and the caller skips the sound, so
// an unknown name degrades to silence rather than to a missing-sound warning.
string(float idx) Shooter_MatSet =
{
    if (idx == 0) return "glass";
    if (idx == 1) return "wood";
    if (idx == 2) return "metal";
    if (idx == 3) return "flesh";
    if (idx == 4) return "concrete";
    return "";                 // -1 "None", and anything unrecognised
};

// ---------------------------------------------------------------------------
//  Live-gib budget.
//
//  Half-Life has no cap because its gibs are client-side temporary entities.
//  Ours are real server edicts (MOVETYPE_BOUNCE, so they fall and settle where
//  the map author aimed them), and the corpus makes that a real number: 21 of
//  the 55 env_shooters set m_flGibLife 600 and one throws 10 pieces, so a map
//  that fires its set dressing on entry can hold hundreds of edicts for ten
//  minutes.  At the cap the OLDEST piece is recycled rather than the new throw
//  being dropped — a shooter that silently stops working is the worse failure,
//  because the thing the player is standing in front of is the new one.
// ---------------------------------------------------------------------------
const float SHOOTER_GIB_MAX = 96;
float shooter_gib_live;

// ---------------------------------------------------------------------------
//  Per-map census.  ONE LINE, ONCE, AND ONLY ON A MAP THAT HAS ANY.
//
//  A cosmetic entity leaves nothing at all in a log — the trap cl_alienfx and
//  cl_monstertrace.qc both document — so "the effect looked wrong" and "the
//  entity never spawned" are the same observation without this.  Same shape and
//  the same self-latching as Modellist_Report (sh_modellist.qc:371), including
//  the print-not-dprint choice: cfg/default.cfg re-execs `developer 0` on every
//  map load, so a developer-gated line in a per-map hook is invisible.
// ---------------------------------------------------------------------------
float gsfx_reported;

// Counted by walking the edicts rather than incremented at spawn, and that is
// the stronger evidence of the two: a spawn counter says "the function ran",
// while this says "the entity is still here" — which is what a mapper is
// actually asking when the effect does not appear.  It also needs no per-map
// reset, which a global counter would.
float(string cls) GoldSrcFX_Count =
{
    float n = 0;
    entity e = find(world, classname, cls);
    while (e)
    {
        n = n + 1;
        e = find(e, classname, cls);
    }
    return n;
};

// THE LATCH GOES AFTER THE EMPTINESS CHECK, NOT BEFORE IT, and that ordering is
// load-bearing rather than stylistic.  AI_Tick's first call lands on a frame
// where the map's entity lump has NOT been parsed yet — measured: 40 edicts,
// every classname empty, time 0 — so a report that latches on entry consumes
// itself before there is anything to count and never prints again.  Reporting
// nothing and staying unlatched means the next tick, with the world populated,
// is the one that answers.  Modellist_Report (sh_modellist.qc:373) tests
// `!ml_paircount` in the same breath as its latch for exactly this reason.
void() GoldSrcFX_Report =
{
    if (gsfx_reported)
        return;

    float a = GoldSrcFX_Count("gibshooter");
    float b = GoldSrcFX_Count("env_shooter");
    float c = GoldSrcFX_Count("env_glow");
    float d = GoldSrcFX_Count("env_blood");
    if (!a && !b && !c && !d)
        return;

    gsfx_reported = TRUE;
    print(sprintf("[goldsrc-fx] gibshooter=%g env_shooter=%g env_glow=%g env_blood=%g\n",
                  a, b, c, d));
};

void() ShooterGib_Expire =
{
    shooter_gib_live = shooter_gib_live - 1;
    if (shooter_gib_live < 0)
        shooter_gib_live = 0;
    remove(self);
};

void() ShooterGib_ReapOldest =
{
    entity best = world;
    entity e = find(world, classname, "shooter_gib");
    while (e)
    {
        if (best == world || e.gib_born < best.gib_born)
            best = e;
        e = find(e, classname, "shooter_gib");
    }
    if (best != world)
    {
        remove(best);
        shooter_gib_live = shooter_gib_live - 1;
        if (shooter_gib_live < 0)
            shooter_gib_live = 0;
    }
};

// Watch for the landing so the material sound plays where it belongs, then get
// out of the way.  A gib is SOLID_NOT (Quake's own ThrowGib idiom) so it never
// blocks a player or eats a bullet trace — but SV_Impact skips .touch on a
// SOLID_NOT entity, so a per-bounce touch sound is not available and this is
// the substitute: SV_Physics_Toss still raises FL_ONGROUND when the piece
// settles, which is the bounce a player actually hears anyway.
//
// The watch is bounded: a gib thrown into a pit never lands, and a 0.1 s think
// that runs for the full 600 s lifetime of 96 pieces is 96,000 wasted calls.
const float SHOOTER_GIB_WATCH = 4;

void() ShooterGib_LandWatch =
{
    if (time >= self.gib_expire)
    {
        ShooterGib_Expire();
        return;
    }

    if (self.flags & FL_ONGROUND)
    {
        if (self.gib_matsnd != "")
        {
            string s = MatSnd_PickName(self.gib_matsnd, MSND_HARD);
            if (s != "")
                sound(self, CHAN_BODY, s, 0.8, ATTN_NORM);
        }

        // LIE FLAT.  This is CGib::BounceGibTouch's own three lines
        // (dlls/combat.cpp) and it was the missing half of the landing:
        //
        //     pev->angles.x = 0;  pev->angles.z = 0;
        //     pev->avelocity.x = 0;  pev->avelocity.z = 0;
        //
        // Without them a piece keeps whatever pitch and roll the tumble left it
        // with - and keeps TUMBLING, because nothing else ever clears .avelocity -
        // so it comes to rest at an arbitrary angle around an origin that is sitting
        // on the floor.  Every one of these models is authored with its origin at
        // its BASE (gib_skull.mdl spans z -0.4..14.0, ribcage -1.3..9.1, gib_legbone
        // 0..6), so tipping it over is exactly what buries half of it in the ground.
        // That is the reported "skull is half in ground when spawned in the map"; on
        // th_ep1_01 the piece in question is `skull_shooter`'s single gib_skull, a
        // 360-second scenery prop that has to look placed rather than dropped.
        //
        // Yaw is deliberately kept, spin included: HL zeroes only x and z, so a gib
        // may settle facing any direction, which is what stops six pieces out of one
        // furnace shooter looking stamped from the same die.
        self.angles_x    = 0;
        self.angles_z    = 0;
        self.avelocity_x = 0;
        self.avelocity_z = 0;
        setorigin(self, self.origin);   // re-link at the corrected resting pose

        // Settled — stop watching, just wait out the lifetime.
        self.think     = ShooterGib_Expire;
        self.nextthink = self.gib_expire;
        return;
    }

    if (time >= self.gib_born + SHOOTER_GIB_WATCH)
    {
        self.think     = ShooterGib_Expire;
        self.nextthink = self.gib_expire;
        return;
    }

    self.nextthink = time + 0.1;
};

// ---------------------------------------------------------------------------
//  ShootThink — effects.cpp:1489.
//
//  ONE DELIBERATE DIVERGENCE, and it is a bug fix rather than a liberty.  HL
//  spreads the shot with `gpGlobals->v_right / v_forward / v_up`, which it never
//  sets in this function: those globals hold whatever the last UTIL_MakeVectors
//  anywhere in the frame left behind, so HL's gib cone points somewhere
//  arbitrary and different every time the entity fires.  We re-derive the basis
//  from the shooter's own angles, which is what the key means and what a mapper
//  setting m_flVariance is aiming for.
// ---------------------------------------------------------------------------
void() Shooter_ShootThink =
{
    makevectors(self.gs_aim);

    vector dir = self.movedir;
    dir = dir + v_right   * ((random() * 2) - 1) * self.m_flvariance;
    dir = dir + v_forward * ((random() * 2) - 1) * self.m_flvariance;
    dir = dir + v_up      * ((random() * 2) - 1) * self.m_flvariance;
    dir = normalize(dir);
    if (dir == '0 0 0')
        dir = '0 0 1';

    if (shooter_gib_live >= SHOOTER_GIB_MAX)
        ShooterGib_ReapOldest();

    entity gib = spawn();
    gib.classname = "shooter_gib";
    setmodel(gib, self.gs_model);
    // The piece is decoration, so it stays SOLID_NOT: it must not push a player,
    // wedge a door, or take part in any trace.  MOVETYPE_BOUNCE still collides
    // with the world through SV_PushEntity regardless of .solid, which is the
    // whole reason a SOLID_NOT gib still lands on the floor.
    //
    // NOT the point hull HL uses, and the difference is deliberate.  CGib::Spawn
    // calls UTIL_SetSize(pev, g_vecZero, g_vecZero), which leaves the piece
    // balancing its collision on a single mathematical point - it comes to rest
    // wherever that one point happens to find a floor, including on the lip of a
    // step or the corner of a crate, and settles with the model hanging off it.
    // Four units of horizontal footprint costs nothing (the box takes part in no
    // trace but its own movement) and gives it something to actually stand on.
    //
    // mins_z is ZERO, which is the load-bearing part: these models are authored
    // with the origin at the base, so a box that extended BELOW the origin would
    // hold every gib up in the air by that much.  Keeping the floor of the box at
    // the origin reproduces the point hull's resting height exactly.
    setsize(gib, '-4 -4 0', '4 4 8');
    gib.solid     = SOLID_NOT;
    gib.movetype  = MOVETYPE_BOUNCE;
    setorigin(gib, self.origin);
    gib.velocity  = dir * self.m_flvelocity;

    // effects.cpp:1509 — the tumble.  Pitch and yaw only; HL leaves roll alone.
    gib.avelocity_x = 100 + random() * 100;
    gib.avelocity_y = 100 + random() * 200;

    if (self.gs_bodies > 1)
        gib.body = floor(1 + random() * (self.gs_bodies - 1));
    gib.skin  = self.skin;
    gib.scale = self.scale;

    // effects.cpp:1523 — lifetime is +/- 5% per piece so a burst does not all
    // vanish on the same frame.
    gib.gib_born   = time;
    gib.gib_expire = time + self.m_flgiblife * (0.95 + random() * 0.1);
    gib.gib_matsnd = self.gs_matsnd;
    gib.think      = ShooterGib_LandWatch;
    gib.nextthink  = time + 0.1;
    shooter_gib_live = shooter_gib_live + 1;

    self.gs_remaining = self.gs_remaining - 1;
    if (self.gs_remaining > 0)
    {
        self.nextthink = time + self.gs_delay;
        return;
    }

    // effects.cpp:1533 — a REPEATABLE shooter rearms and waits for the next
    // trigger; a one-shot removes itself.
    if (self.spawnflags & SF_GIBSHOOTER_REPEATABLE)
    {
        self.gs_remaining = self.gs_capacity;
        self.think        = __NULL__;
        self.nextthink    = 0;
        return;
    }
    remove(self);
};

void() Shooter_Use =
{
    // Already firing — HL restarts the think unconditionally, which for a
    // mid-burst retrigger just resets the cadence.  Same here.
    if (self.gs_remaining <= 0)
        self.gs_remaining = self.gs_capacity;
    self.think     = Shooter_ShootThink;
    self.nextthink = time;
};

// Shared spawn body.  `def` is the model thrown when the map does not name one.
void(string def) Shooter_SpawnCommon =
{
    self.gs_model = self.shootmodel;
    if (self.gs_model == "" || !self.gs_model)
        self.gs_model = def;

    precache_model(self.gs_model);
    self.gs_bodies = Shooter_BodyCount(self.gs_model);

    // FGD defaults (sven-coop.fgd:629).  m_flGibLife 0 means "unset", not
    // "vanish instantly" — effects.cpp:1466 substitutes 25 there, but Sven's
    // FGD documents 4 and every corpus placement sets it explicitly, so the
    // value only matters for a map that omits the key entirely.
    if (self.m_igibs <= 0)      self.m_igibs      = 3;
    if (self.m_flvelocity <= 0) self.m_flvelocity = 200;
    if (self.m_flvariance <= 0) self.m_flvariance = 0.15;
    if (self.m_flgiblife <= 0)  self.m_flgiblife  = 4;

    // effects.cpp:1461 — a zero delay becomes 0.1, NOT "all at once".  The FGD
    // says all-at-once; the code disagrees and the code is what the maps were
    // built against.
    self.gs_delay = self.delay;
    if (self.gs_delay <= 0)
        self.gs_delay = 0.1;

    self.gs_capacity  = self.m_igibs;
    self.gs_remaining = self.m_igibs;

    self.gs_matsnd = Shooter_MatSet(self.shootsounds);

    if (self.scale <= 0)
        self.scale = 1;

    // Save the aim before SetMovedir zeroes .angles — ShootThink needs the full
    // basis, not just forward.
    self.gs_aim = self.angles;
    SetMovedir();

    self.solid     = SOLID_NOT;
    self.movetype  = MOVETYPE_NONE;
    self.effects  |= EF_NODRAW;
    self.use       = Shooter_Use;
};

/*QUAKED gibshooter (1 0 0) (-8 -8 -8) (8 8 8) REPEATABLE
Throws human gibs on trigger.

"m_iGibs"       pieces per burst (default 3)
"m_flVelocity"  launch speed (default 200)
"m_flVariance"  cone spread 0..1 (default 0.15)
"m_flGibLife"   seconds each piece survives (default 4)
"delay"         seconds between pieces (default 0.1)
*/
void() gibshooter =
{
    // effects.cpp:1401 also has a LANGUAGE_GERMAN branch swapping in
    // germanygibs.mdl.  Not ported: there is no language channel here, and a
    // censored-gib option belongs to a cvar rather than to a locale.
    Shooter_SpawnCommon("models/hgibs.mdl");
};

/*QUAKED env_shooter (.7 .3 .6) (-8 -8 -8) (8 8 8) REPEATABLE
As gibshooter, but throws an arbitrary model.

"shootmodel"    model path
"shootsounds"   material for the landing sound: 0 glass, 1 wood, 2 metal,
                3 flesh, 4 concrete, -1 silent
"skin"          submodel skin
"scale"         render scale
*/
void() env_shooter =
{
    // No shootmodel and no default worth guessing: HL leaves pev->model empty
    // and CEnvShooter::CreateGib spawns a gib with an empty model, which draws
    // nothing.  Fall back to hgibs rather than throwing invisible entities, so
    // a map with a typo'd path still shows the mapper something moved.
    Shooter_SpawnCommon("models/hgibs.mdl");
};

// ===========================================================================
//  env_glow  —  effects.cpp:1112, CGlow
// ===========================================================================
//  A sprite, always drawn, with the render keys doing the work: 28 of the 49
//  corpus placements are sprites/glow01.spr on rendermode 5 (additive) and the
//  other 21 are rendermode 3 (glow) with renderfx 14 (constant glow).
//
//  ONE DIVERGENCE, in the safe direction.  HL's CGlow has no Use at all, so a
//  trigger naming one does nothing — but 10 of the placements DO carry a
//  targetname (nine of them `bulb7`, alongside the light they belong to), which
//  only makes sense if the mapper expected the glow to go out with the bulb.
//  So .use toggles here.  What it deliberately does NOT do is honour a
//  START_ON-style spawnflag: an env_glow always starts visible, exactly as in
//  HL, because starting a named-but-never-triggered glow hidden would REMOVE
//  light the original game shows.  `good_powerbox` is precisely that entity —
//  named, no spawnflag — and it stays lit.
// ===========================================================================
.float eg_visible;
.float framestart;          // sven-coop.fgd:1840, starting sprite frame

void() env_glow_use =
{
    if (self.eg_visible)
    {
        self.effects |= EF_NODRAW;
        self.eg_visible = 0;
    }
    else
    {
        self.effects = self.effects - (self.effects & EF_NODRAW);
        self.eg_visible = 1;
    }
};

/*QUAKED env_glow (.2 .8 .1) (-4 -4 -4) (4 4 4)
Always-on light glow sprite.

"model"        sprite path (default sprites/glow01.spr)
"scale"        size multiplier
"framestart"   initial sprite frame
"rendermode" / "renderamt" / "rendercolor" / "renderfx"   GoldSrc render keys
*/
void() env_glow =
{
    if (!self.model || self.model == "")
        self.model = "sprites/glow01.spr";

    // Same Source-material guard env_sprite carries: a .vmt is a MATERIAL, not
    // a model, and feeding it to setmodel loads a dummy that crashes the sprite
    // render path.  See sv_env_sprite.qc.
    if (substring(self.model, strlen(self.model) - 4, 4) == ".vmt")
    {
        remove(self);
        return;
    }

    precache_model(self.model);
    setmodel(self, self.model);
    setsize(self, '0 0 0', '0 0 0');
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;

    if (self.scale <= 0)
        self.scale = 1;
    if (self.framestart > 0)
        self.frame = self.framestart;

    BrushSync_ApplyRenderKeys();

    self.eg_visible = 1;
    self.use        = env_glow_use;
};

// ===========================================================================
//  env_blood  —  effects.cpp:1718, CBlood
// ===========================================================================
//  The spray itself lives in shared/sh_envblood.qc, because the particle config
//  is client-only and a server-side pointparticles() cannot resolve a recipe
//  name.  This half is the entity: the keys, the direction, and where the blood
//  comes from.
// ===========================================================================
.float amount;      // "damage to simulate" — the corpus runs 100..500

// THE `color` KEY LANDS IN AN ENGINE VECTOR, NOT A FLOAT.  `.vector color` is
// declared in sv_defs.qc:448 (it tints realtime lights), so FTE's entdata parser
// matches "color" there first and a map's `color "1"` arrives as '1 0 0'.
// Declaring a `.float color` here would not shadow it — it would be a type
// clash — so the x component IS the value.  Harmless in the other direction
// too: .color only reaches the renderer through pflags, which env_blood never
// sets.
float() EnvBlood_Color =
{
    return (self.color_x >= 1) ? BLOODCOL_YELLOW : BLOODCOL_RED;
};

// effects.cpp:1799 — SF_BLOOD_RANDOM overrides the mapper's angles with a fresh
// direction every burst; otherwise the entity's own facing is the jet.
vector() EnvBlood_Direction =
{
    if (self.spawnflags & SF_BLOOD_RANDOM)
    {
        // No crandom() in this codebase's defs (sv_ai_combat.qc:80) —
        // (random()*2 - 1) is the same number.
        vector v;
        v_x = (random() * 2) - 1;
        v_y = (random() * 2) - 1;
        v_z = (random() * 2) - 1;
        v = normalize(v);
        if (v == '0 0 0')
            v = '0 0 1';
        return v;
    }
    return self.movedir;
};

// effects.cpp:1806 — SF_BLOOD_PLAYER sprays at the ACTIVATING player's eyes
// with a little jitter, which is how a map does the "something bled on you"
// shot.  HL falls back to entity index 1 when the activator is not a player;
// here that is `activator` failing the classname test, and the honest fallback
// is the entity's own origin rather than whichever player happens to be first
// in the edict table.
vector() EnvBlood_Position =
{
    if (self.spawnflags & SF_BLOOD_PLAYER)
    {
        if (activator && activator.classname == "player")
            return activator.origin + activator.view_ofs
                 + [((random() * 2) - 1) * 10,
                    ((random() * 2) - 1) * 10,
                    ((random() * 2) - 1) * 10];
    }
    return self.origin;
};

void() env_blood_use =
{
    // A RANDOM direction is re-rolled per burst, so it is resolved ONCE here
    // and the same vector travels on the wire for both the spray and the decal
    // trace — otherwise the stain lands somewhere the blood never went.
    EnvBlood_Multicast(EnvBlood_Position(), EnvBlood_Direction(),
                       self.amount, EnvBlood_Color(), self.spawnflags);
};

/*QUAKED env_blood (.8 0 0) (-8 -8 -8) (8 8 8) RANDOM STREAM PLAYER DECAL
Sprays blood when triggered.

"amount"   damage to simulate — scales the spray (default 100)
"color"    0 red (human), 1 yellow (alien)
"angles"   spray direction, unless RANDOM
*/
void() env_blood =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.effects |= EF_NODRAW;

    if (self.amount <= 0)
        self.amount = 100;      // sven-coop.fgd:1743

    SetMovedir();
    self.use = env_blood_use;
};
