// server/sv_xen_flora.qc
// ----------------------------------------------------------------------------
// Half-Life's Xen flora — dlls/xen.cpp, in full.
//
// Six map classnames plus two runtime helpers, and together they are the entire
// set dressing of the Xen chapters.  Measured over the 36 Sven hl_ maps: 180
// placements across hl_c14, hl_c15, hl_c16_a1, hl_c16_a2 and hl_c17 —
// xen_plantlight 75, xen_hair 35, xen_spore_small 28, xen_tree 24,
// xen_spore_medium 14, xen_spore_large 4.  Every one of them was landing in
// SV_OnEntityNoSpawnFunction and becoming an invisible inert relay, so the
// alien world was a set of empty rooms.
//
// HOW THESE ANIMATE, and it is why most of this file has no think function:
//
//   .frame is the SEQUENCE INDEX and the CLIENT owns the playback clock.  The
//   server writes a sequence number; CL_LerpNetFrameState stamps the start time
//   whenever it changes and loops the sequence for as long as it is set (see the
//   header of sv_ai_anim.qc, which measured this from the engine).  So a purely
//   decorative animating prop needs NO server tick at all — HL's CXenHair::Think
//   and CXenSpore::Think exist only to call StudioFrameAdvance, which is work
//   FTE does client-side.  Dropping those thinks is not a shortcut; keeping them
//   would be 180 no-op entities thinking twice a second forever.
//
//   The two classes that DO tick are the two with a state machine: xen_plantlight
//   (retract, wait, unfurl) and xen_tree (the bite).
//
// THE MODELS ARE ALL PRESENT in the mounted svencoop gamedir — light.mdl,
// hair.mdl, tree.mdl, fungus(small).mdl, fungus.mdl, fungus(large).mdl and
// sprites/flare3.spr — so nothing here is precaching a file that may not exist.
// Note the PARENTHESES in the two fungus names; they are part of the filename,
// not a typo, and they are what a hand-written guess gets wrong.
// ----------------------------------------------------------------------------

// Externs from earlier compile units.
float(entity attacker, entity target, float damage) W_ApplyDamage;   // sh_weapon_standard.qc

const string XEN_GLOW_SPRITE = "sprites/flare3.spr";
// CXenPLight's retract time (xen.cpp:23, XEN_PLANT_HIDE_TIME).
const float  XEN_PLANT_HIDE_TIME = 5;
// CXenHair's one spawnflag (xen.cpp:191).  Set = every hair in the group runs on
// the same clock instead of being randomised, which is how a mapper makes a field
// of them wave together.
const float  SF_HAIR_SYNC = 1;
// CXenTree's attack event (xen.cpp:TREE_AE_ATTACK).
const float  XEN_TREE_AE_ATTACK = 1;

.float  xen_act;        // current activity, HL's CActAnimating::m_Activity
.float  xen_seqend;     // when the current sequence finishes (server clock)
.entity xen_glow;       // xen_plantlight's glow sprite
.entity xen_trigger;    // xen_tree's bite volume
.float  xen_evtdone;    // one-shot latch for the bite event
.float  xen_hidetime;   // xen_plantlight's reopen time.  HL reuses pev->dmgtime
                        // for this; that field is not declared in this tree and
                        // borrowing an unrelated one to save four bytes is how
                        // fields end up meaning two things.
.float  xen_hp;         // xen_tree's health watermark — see xen_tree_think

// ---------------------------------------------------------------------------
// CActAnimating::SetActivity (xen.cpp:49).
//
// Returns FALSE when the model does not carry the activity, exactly as HL's
// ACTIVITY_NOT_AVAILABLE check does — and the callers below rely on that, because
// a state machine that advanced on a sequence the model cannot play would sit in
// a state it can never leave.
// ---------------------------------------------------------------------------
float(entity e, float act) Xen_SetActivity =
{
    if (e.modelindex <= 0)
        return FALSE;
    float seq = frameforaction(e.modelindex, (int)act);
    if (seq < 0 || seq >= modelframecount(e.modelindex))
        return FALSE;

    e.frame     = seq;
    e.xen_act   = act;
    e.xen_seqend = time + frameduration(e.modelindex, seq);
    return TRUE;
};

// ---------------------------------------------------------------------------
// xen_plantlight — CXenPLight (xen.cpp:63-178)
//
// The glowing bud that folds up when you walk into it and opens again five
// seconds later, firing its target ON and OFF as it goes.  75 of them, which
// makes it the single commonest missing entity on the Xen maps.
// ---------------------------------------------------------------------------
void() xen_plantlight_lighton =
{
    if (self.xen_glow)
        self.xen_glow.effects = self.xen_glow.effects - (self.xen_glow.effects & EF_NODRAW);
    SUB_UseTargets(self, self, USE_ON);
};

void() xen_plantlight_lightoff =
{
    if (self.xen_glow)
        self.xen_glow.effects = self.xen_glow.effects | EF_NODRAW;
    SUB_UseTargets(self, self, USE_OFF);
};

void() xen_plantlight_think =
{
    self.nextthink = time + 0.1;

    if (self.xen_act == ACT_CROUCH)
    {
        // Finished folding up: hold closed and douse the glow.
        if (time >= self.xen_seqend)
        {
            Xen_SetActivity(self, ACT_CROUCHIDLE);
            xen_plantlight_lightoff();
        }
    }
    else if (self.xen_act == ACT_CROUCHIDLE)
    {
        // Set by the touch; HL keeps this in pev->dmgtime.
        if (time > self.xen_hidetime)
        {
            Xen_SetActivity(self, ACT_STAND);
            xen_plantlight_lighton();
        }
    }
    else if (self.xen_act == ACT_STAND)
    {
        if (time >= self.xen_seqend)
            Xen_SetActivity(self, ACT_IDLE);
    }
    // ACT_IDLE: nothing to do but wait to be stepped on.
};

void() xen_plantlight_touch =
{
    if (other.classname != "player")
        return;

    self.xen_hidetime = time + XEN_PLANT_HIDE_TIME;
    if (self.xen_act == ACT_IDLE || self.xen_act == ACT_STAND)
        Xen_SetActivity(self, ACT_CROUCH);
};

/*QUAKED xen_plantlight (0 .8 .3) (-80 -80 0) (80 80 32)
Xen light plant.  Folds up for 5 s when a player touches it, firing its target
USE_OFF as it closes and USE_ON as it reopens.

"rendercolor"  tint of the glow sprite
"renderamt"    glow brightness
*/
void() xen_plantlight =
{
    precache_model("models/light.mdl");
    precache_model(XEN_GLOW_SPRITE);

    setmodel(self, "models/light.mdl");
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_TRIGGER;
    setsize(self, '-80 -80 0', '80 80 32');

    Xen_SetActivity(self, ACT_IDLE);
    self.touch     = xen_plantlight_touch;
    self.think     = xen_plantlight_think;
    self.nextthink = time + 0.1;

    // The glow.  HL attaches it to attachment 1 with kRenderGlow; FTE reads the
    // blend mode out of the .spr itself, so a plain sprite entity parked at the
    // bud's midpoint gets the same additive flare without a render-mode key.
    // Parented by position rather than by attachment because the plant never
    // moves — all 75 are static — and a real attachment would cost a per-frame
    // bone lookup for no visible difference.
    entity glow = spawn();
    glow.classname = "xen_plantglow";
    glow.owner     = self;
    setmodel(glow, XEN_GLOW_SPRITE);
    setorigin(glow, self.origin + '0 0 16');   // (mins_z + maxs_z) * 0.5
    glow.movetype = MOVETYPE_NONE;
    glow.solid    = SOLID_NOT;
    glow.effects  = glow.effects | EF_FULLBRIGHT;
    if (self.rendercolor != '0 0 0')
        glow.colormod = self.rendercolor / 255;
    if (self.renderamt > 0)
        glow.alpha = self.renderamt / 255;
    self.xen_glow = glow;
};

// ---------------------------------------------------------------------------
// xen_hair — CXenHair (xen.cpp:183-224)
//
// A tuft of waving hair.  Non-solid, no think: sequence 0 loops on the client
// forever.  The randomised start frame and framerate are what stop a field of
// 35 of them waving in lockstep, and SF_HAIR_SYNC is the mapper's way of asking
// for exactly that lockstep.
// ---------------------------------------------------------------------------
/*QUAKED xen_hair (0 .8 .3) (-4 -4 0) (4 4 32) SYNC
Waving Xen hair.  SYNC (1) makes it run on the shared clock instead of a random
offset, so a group planted together moves as one.
*/
void() xen_hair =
{
    precache_model("models/hair.mdl");
    setmodel(self, "models/hair.mdl");
    setsize(self, '-4 -4 0', '4 4 32');

    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.frame    = 0;

    // HL randomises pev->frame (a phase offset into the sequence) and
    // pev->framerate.  Neither is reachable here: .frame IS the sequence index
    // in this engine, so writing a random number into it would select a random
    // ANIMATION, and .framerate is not networked for MDLs.  The de-sync is
    // therefore dropped rather than faked — a wrong-sequence tuft is a worse
    // outcome than a synchronised one, and the SYNC spawnflag says the map is
    // happy with synchronised anyway.
};

// ---------------------------------------------------------------------------
// xen_spore_small / _medium / _large — CXenSpore (xen.cpp:420-583)
//
// The bulbous fungus stalks.  Solid, damageable (HL swallows the damage and
// calls an empty Attack(), so they are effectively indestructible scenery), and
// again purely client-animated.
//
// The three sizes are one class in HL separated by pev->skin, which selects both
// the model and the hull.  Kept as three spawn functions here for the same
// reason the ammo aliases are kept apart: a map that places xen_spore_large
// expects the large one, and routing all three through a skin key would make a
// mis-set key silently produce the wrong plant.
// ---------------------------------------------------------------------------
void(string mdl, vector mins, vector maxs) Xen_SporeSpawn =
{
    precache_model(mdl);
    setmodel(self, mdl);
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_BBOX;
    self.takedamage = DAMAGE_NO;   // HL is DAMAGE_YES with a no-op handler; the
                                   // observable behaviour is identical and this
                                   // costs nothing per shot.
    setsize(self, mins, maxs);
    self.frame = 0;
};

/*QUAKED xen_spore_small (0 .8 .3) (-16 -16 0) (16 16 64) */
void() xen_spore_small =
{
    self.skin = 0;
    Xen_SporeSpawn("models/fungus(small).mdl", '-16 -16 0', '16 16 64');
};

/*QUAKED xen_spore_medium (0 .8 .3) (-40 -40 0) (40 40 120) */
void() xen_spore_medium =
{
    self.skin = 1;
    Xen_SporeSpawn("models/fungus.mdl", '-40 -40 0', '40 40 120');
};

// The big one stands on legs, and its bounding box starts 110 units UP so the
// player can walk underneath the cap.  HL fills the gap with five invisible
// SOLID_BBOX hulls, one per leg, rotated into place around the trunk — without
// them you walk straight through the stalk.  Offsets are Valve's own
// ("I just eyeballed these", xen.cpp:551).
void() xen_hull_spawn;

/*QUAKED xen_spore_large (0 .8 .3) (-48 -48 110) (48 48 240) */
void() xen_spore_large =
{
    self.skin = 2;
    Xen_SporeSpawn("models/fungus(large).mdl", '-48 -48 110', '48 48 240');

    makevectors(self.angles);
    vector legs_x_ofs = '90 25 -15';    // packed as three pairs below; see the
    vector legs_y_ofs = '-25 75 -100';  // SDK table at xen.cpp:551-558
    vector legs2_x    = '-90 -90 0';
    vector legs2_y    = '-35 60 0';

    float i;
    for (i = 0; i < 5; i = i + 1)
    {
        float fx, fy;
        if      (i == 0) { fx =  90; fy = -25;  }
        else if (i == 1) { fx =  25; fy =  75;  }
        else if (i == 2) { fx = -15; fy = -100; }
        else if (i == 3) { fx = -90; fy = -35;  }
        else             { fx = -90; fy =  60;  }

        entity hull = spawn();
        hull.classname = "xen_hull";
        hull.owner     = self;
        hull.movetype  = MOVETYPE_NONE;
        hull.solid     = SOLID_BBOX;
        setorigin(hull, self.origin + v_forward * fx + v_right * fy);
        setsize(hull, '-12 -12 0', '12 12 120');
    }
};

// ---------------------------------------------------------------------------
// xen_ttrigger — CXenTreeTrigger (xen.cpp:227-256)
//
// The tree's reach.  A separate trigger volume 64 units in front of the trunk
// that forwards its touch to the owner, because the tree itself is SOLID_BBOX
// and so can never receive a touch from something standing next to it.
// ---------------------------------------------------------------------------
void() xen_tree_attack;

void() xen_ttrigger_touch =
{
    if (!self.owner || self.owner == world || wasfreed(self.owner))
        return;
    entity oldself = self;
    self = self.owner;
    xen_tree_attack();
    self = oldself;
};

// ---------------------------------------------------------------------------
// xen_tree — CXenTree (xen.cpp:259-410)
//
// The snapping barnacle-plant.  Bites anything that touches its trigger volume
// or shoots it, and the bite itself lands on an animation EVENT rather than on a
// timer — which matters, because the damage has to coincide with the jaws
// closing and the sequence is over a second long.
// ---------------------------------------------------------------------------
void() xen_tree_attack =
{
    if (self.xen_act != ACT_IDLE)
        return;                       // already mid-bite; HL ignores it too

    if (!Xen_SetActivity(self, ACT_MELEE_ATTACK1))
        return;
    self.xen_evtdone = FALSE;

    float r = random();
    if (r < 0.5) sound(self, CHAN_WEAPON, "zombie/claw_miss1.wav", 1, ATTN_NORM);
    else         sound(self, CHAN_WEAPON, "zombie/claw_miss2.wav", 1, ATTN_NORM);
};

// The bite lands.  HL uses UTIL_EntitiesInBox over the TRIGGER's bounds, not the
// tree's, so the reach is the trigger volume and nothing else.
void() xen_tree_bite =
{
    entity trig = self.xen_trigger;
    if (!trig || trig == world || wasfreed(trig))
        return;

    makevectors(self.angles);
    vector fwd = v_forward;
    float hit = FALSE;

    // findradius rather than a box walk: QC has no EntitiesInBox, and the
    // trigger is a 48x48x128 volume whose diagonal is ~146.  Filter to the box
    // afterwards so the shape still matches the SDK's.
    entity e = findradius(trig.origin + '0 0 64', 160);
    while (e)
    {
        entity nxt = e.chain;
        if (e != self && e != trig && e.owner != self
         && (e.classname == "player" || (e.flags & FL_MONSTER))
         && e.health > 0
         && e.absmin_x <= trig.absmax_x && e.absmax_x >= trig.absmin_x
         && e.absmin_y <= trig.absmax_y && e.absmax_y >= trig.absmin_y
         && e.absmin_z <= trig.absmax_z && e.absmax_z >= trig.absmin_z)
        {
            hit = TRUE;
            W_ApplyDamage(self, e, 25);
            e.velocity = e.velocity + fwd * 100;
        }
        e = nxt;
    }

    if (hit)
    {
        float r = random();
        if      (r < 0.34) sound(self, CHAN_WEAPON, "zombie/claw_strike1.wav", 1, ATTN_NORM);
        else if (r < 0.67) sound(self, CHAN_WEAPON, "zombie/claw_strike2.wav", 1, ATTN_NORM);
        else               sound(self, CHAN_WEAPON, "zombie/claw_strike3.wav", 1, ATTN_NORM);
    }
};

void() xen_tree_think =
{
    self.nextthink = time + 0.1;

    // SHOOTING IT MAKES IT SNAP, and this is a poll rather than a callback
    // because there is no per-hit hook to hang one on.  W_ApplyDamage
    // (sv_weapons.qc:1680) walks a fixed chain of classname tests and then
    // subtracts from .health; nothing in it dispatches to a per-entity "I was
    // hurt" function, so the only honest way to notice is to watch the number.
    //
    // HL's CXenTree::TakeDamage returns 0 — the tree absorbs the shot entirely
    // and only reacts — so the watermark is restored rather than tracked down.
    if (self.health < self.xen_hp)
    {
        self.health = self.xen_hp;
        xen_tree_attack();
    }

    if (self.xen_act != ACT_MELEE_ATTACK1)
        return;

    // Find the attack event's timestamp on the playing sequence and fire once as
    // the clock passes it.  getmodeleventidx is the same reader AI_PumpEventRange
    // uses, so the tree bites on the same frame a monster's claw would.
    if (!self.xen_evtdone)
    {
        float elapsed = time - (self.xen_seqend - frameduration(self.modelindex, self.frame));
        float evi = 0;
        float ts; int code; string edata;
        while (evi < 16)
        {
            if (!getmodeleventidx(self.modelindex, (int)self.frame, (int)evi, ts, code, edata))
                break;
            evi = evi + 1;
            if ((float)code == XEN_TREE_AE_ATTACK && elapsed >= ts)
            {
                self.xen_evtdone = TRUE;
                xen_tree_bite();
                break;
            }
        }
    }

    if (time >= self.xen_seqend)
    {
        // Bite finished with no event on the model at all — land it anyway
        // rather than let a model without the event make the tree harmless.
        if (!self.xen_evtdone)
        {
            self.xen_evtdone = TRUE;
            xen_tree_bite();
        }
        Xen_SetActivity(self, ACT_IDLE);
    }
};

void() xen_tree_touch =
{
    // HL's test reads `!IsPlayer() && FClassnameIs("monster_bigmomma")` which is
    // a Valve typo - it can never be true, so in practice everything that
    // touches gets bitten. Ported as written rather than as intended, because
    // hl_c15 walks a monster_bigmomma through a grove of these and the shipped
    // behaviour is the one the map was built against.
    xen_tree_attack();
};

/*QUAKED xen_tree (0 .8 .3) (-30 -30 0) (30 30 188)
Snapping Xen tree.  Bites anything entering the volume 64 units in front of it,
or anything that shoots it, for 25 damage plus a shove.
*/
void() xen_tree =
{
    precache_model("models/tree.mdl");
    precache_model(XEN_GLOW_SPRITE);
    precache_sound("zombie/claw_strike1.wav");
    precache_sound("zombie/claw_strike2.wav");
    precache_sound("zombie/claw_strike3.wav");
    precache_sound("zombie/claw_miss1.wav");
    precache_sound("zombie/claw_miss2.wav");

    setmodel(self, "models/tree.mdl");
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_BBOX;
    self.takedamage = DAMAGE_AIM;
    if (!self.health)
        self.health = 1000;
    self.xen_hp = self.health;      // watermark; xen_tree_think restores from it
    setsize(self, '-30 -30 0', '30 30 188');

    Xen_SetActivity(self, ACT_IDLE);
    self.touch     = xen_tree_touch;
    self.think     = xen_tree_think;
    self.nextthink = time + 0.1;

    // The reach volume, 64 units along the tree's facing (xen.cpp:307-314).
    makevectors(self.angles);
    entity trig = spawn();
    trig.classname = "xen_ttrigger";
    trig.owner     = self;
    trig.solid     = SOLID_TRIGGER;
    trig.movetype  = MOVETYPE_NONE;
    trig.touch     = xen_ttrigger_touch;
    setorigin(trig, self.origin + v_forward * 64);
    setsize(trig, '-24 -24 0', '24 24 128');
    self.xen_trigger = trig;
};
