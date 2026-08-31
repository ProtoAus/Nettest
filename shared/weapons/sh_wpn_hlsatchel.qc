// ============================================================
//  shared/weapons/sh_wpn_hlsatchel.qc  -  HL Satchel Charge
//
//  Slot  : SLOT_UTILITY  (impulse 4 / key 4)
//  Stats : ammo_satchel (direct pool, max 5 — SATCHEL_MAX_CARRY, weapons.h:117)
//  Fire  : +attack throws a charge.  The viewmodel becomes the RADIO, and
//          +attack2 on the radio detonates every charge you have out.
//
//  Ported from the SDK: dlls/satchel.cpp.  Every number below carries the
//  line it came from, because "about right" and "right" look identical
//  until you play the two side by side.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Charge-ready state, satchel.cpp's m_chargeReady ---------------------
// 0 = holding satchels, satchel viewmodel      (satchel.cpp:474)
// 1 = at least one charge out, radio viewmodel (satchel.cpp:415)
// 2 = just detonated, radio still out until the idle swaps it back (:382)
const float SATCHEL_STATE_HOLD  = 0;
const float SATCHEL_STATE_ARMED = 1;
const float SATCHEL_STATE_SPENT = 2;

.float satchel_state;

// --- Sequence indices ----------------------------------------------------
// Read out of the models, not the enum: v_satchel.mdl has 4 sequences and
// v_satchel_radio.mdl has 5, and they happen to agree with satchel.cpp's
// satchel_e / satchel_radio_e in both order and count.
const float SATCHEL_SEQ_IDLE     = 0;   // idle1,   5.000 s, looping
const float SATCHEL_SEQ_FIDGET   = 1;   // fidget1, 2.000 s
const float SATCHEL_SEQ_DRAW     = 2;   // draw,    2.000 s
const float SATCHEL_SEQ_DROP     = 3;   // drop,    0.500 s

const float SATCHEL_RADIO_SEQ_IDLE    = 0;  // idle1,   2.667 s, looping
const float SATCHEL_RADIO_SEQ_FIDGET  = 1;  // fidget1, 3.667 s
const float SATCHEL_RADIO_SEQ_DRAW    = 2;  // draw,    0.600 s
const float SATCHEL_RADIO_SEQ_FIRE    = 3;  // fire,    1.000 s
const float SATCHEL_RADIO_SEQ_HOLSTER = 4;  // holster, 0.500 s

// Durations are the sequences' own, so the state machine cannot drift from
// what is on screen.  v_satchel draw is 2.0 s but satchel.cpp:497 gates the
// next attack at 1.0 s, and that gate is what the player actually feels.
const float SATCHEL_DRAW_DURATION       = 1.0;    // satchel.cpp:497
const float SATCHEL_THROW_DURATION      = 0.6;    // radio draw, played on the throw
const float SATCHEL_DETONATE_DURATION   = 1.0;    // radio fire

const float SATCHEL_FRAME_INTERVAL      = 0.05;

const float MAX_AMMO_SATCHEL            = 5;      // SATCHEL_MAX_CARRY, weapons.h:117

// --- Balance -------------------------------------------------------------
// sk_plr_satchel = 150 (valve/skill.cfg).  HL's RadiusDamage derives the
// radius from the damage when none is given - flRadius = flDamage * 2.5 -
// so 150 damage is a 375-unit blast, and that ratio is why the satchel
// out-ranges the hand grenade so dramatically.
const float SATCHEL_DAMAGE              = 150;
const float SATCHEL_RADIUS              = 375;
const float SATCHEL_MIN_DAMAGE          = 15;
const float SATCHEL_KNOCKBACK_PUSH      = 1000;
const float SATCHEL_KNOCKBACK_UPLIFT    = 400;

const float SATCHEL_THROW_FORWARD       = 274;    // satchel.cpp:396
const float SATCHEL_THROW_AVELOCITY_Y   = 400;    // satchel.cpp:401
const float SATCHEL_GRAVITY             = 0.5;    // satchel.cpp:84
const float SATCHEL_FRICTION            = 0.8;    // satchel.cpp:85

// w_satchel.mdl ships exactly two sequences: 0 "idle" (the charge stood on its
// end, which is how it sits in the world-model pickup) and 1 "onback" (lying
// flat, face up).  CSatchelCharge::Spawn ends with `pev->sequence = 1`
// (satchel.cpp:88), so a THROWN charge is on its back in Half-Life and an
// UNTHROWN one on the ground is not.  Leaving .frame at 0 is what left every
// charge in this tree standing upright like a little tombstone.
const float SATCHEL_SEQ_ONBACK          = 1;      // satchel.cpp:88

const float SATCHEL_THROW_DELAY         = 1.0;    // satchel.cpp:417
const float SATCHEL_DETONATE_DELAY      = 0.5;    // satchel.cpp:382
const float SATCHEL_DRYFIRE_DELAY       = 0.2;

// Straight off the valve mount - these are GoldSrc-format (IDST) models, so
// the viewmodel is sequence-indexed rather than frame-indexed.  No converted
// IDPO copy is needed for any of them.
const string SATCHEL_VIEWMODEL       = "models/v_satchel.mdl";
const string SATCHEL_RADIO_VIEWMODEL = "models/v_satchel_radio.mdl";
const string SATCHEL_WORLDMODEL      = "models/w_satchel.mdl";
const string SATCHEL_CHARGE_MODEL    = "models/w_satchel.mdl";   // satchel.cpp:73
const string SATCHEL_DEPLOY_SOUND    = "";
const string SATCHEL_DISPLAY_NAME    = "SATCHEL";

float(float spent_wep) W_UtilityNextAfterSpent;

// ============================================================
//  SHARED — state machine
// ============================================================

// Which viewmodel the current charge state puts in your hands.  satchel.cpp
// swaps this in three separate places (Deploy :493, Throw :409, WeaponIdle
// :447); doing it from one function means the three can never disagree.
string() SH_SatchelViewmodel =
{
    if (self.satchel_state == SATCHEL_STATE_HOLD)
        return SATCHEL_VIEWMODEL;
    return SATCHEL_RADIO_VIEWMODEL;
};

float(float now) SH_SatchelTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SATCHEL_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        // A throw and a detonation are both WS_FIRE but they play different
        // sequences of different lengths, so the exit time depends on which
        // one we are in.  SPENT can only be reached by detonating.
        float dur = (self.satchel_state == SATCHEL_STATE_SPENT)
                        ? SATCHEL_DETONATE_DURATION : SATCHEL_THROW_DURATION;
        if (elapsed >= dur)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// +attack — throw a charge.  satchel.cpp:353: the throw is refused only
// while chargeReady == 2, i.e. between pressing the detonator and the idle
// putting the satchel back in your hand.
//
// Returns  1 threw, 0 blocked, -1 dry-fire, -2 "detonate instead" (see below).
//
// The -2 case is a DELIBERATE DIVERGENCE from Half-Life, which never detonates
// on primary - satchel.cpp:351 is `if (m_chargeReady != 2) Throw();` and
// Throw() (:391) silently does nothing at zero ammo.  Faithfully ported, that
// leaves +attack as a key that clicks at you and does nothing whenever you have
// thrown everything you had, which reads as a broken detonator rather than as
// the wrong key.  So: with charges live and nothing left to throw, +attack
// detonates.  Every case where the throw could still do something is untouched,
// so multi-charge play is exactly HL's - throw up to five, then blow them.
float(float now) SH_SatchelTryThrow =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.satchel_state == SATCHEL_STATE_SPENT) return 0;

    if (self.ammo_satchel <= 0)
    {
        // Nothing left to throw but something out there to set off.  Note this
        // returns WITHOUT touching attack_finished: the dry-fire push below was
        // able to starve the +attack2 gate at sv_weapons.qc:3801 when both keys
        // were held, and the caller's SH_SatchelTryDetonate sets its own delay.
        if (self.satchel_state == SATCHEL_STATE_ARMED)
            return -2;

        self.attack_finished = now + SATCHEL_DRYFIRE_DELAY;
        return -1;
    }

    self.ammo_satchel   -= 1;
    self.satchel_state   = SATCHEL_STATE_ARMED;
    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SATCHEL_THROW_DELAY;
    return 1;
};

// +attack2 — squeeze the detonator.  satchel.cpp:360 only fires on
// chargeReady == 1: with nothing out there is nothing to set off, and once
// SPENT the radio is already on its way out of your hands.
float(float now) SH_SatchelTryDetonate =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.satchel_state != SATCHEL_STATE_ARMED) return 0;

    self.satchel_state   = SATCHEL_STATE_SPENT;
    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SATCHEL_DETONATE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// ADDITIVE, not assign.  satchel.cpp's weapon is ITEM_FLAG_EXHAUSTIBLE with a
// DEFAULT_GIVE of 1 (weapons.h:155) - a map hands you charges one at a time and
// you accumulate up to five.  Assigning would mean walking over a second
// satchel SET you back to one.  Picking a dropped pouch back up adds what was
// in it, capped the same way, so the round trip is lossless.
void(entity player) W_SatchelPickupCopy =
{ player.ammo_satchel = bound(0, player.ammo_satchel + self.ammo_satchel, MAX_AMMO_SATCHEL); };

void() W_SatchelChargeExplode =
{
    float snd = random();
    float snd_idx = (snd < 0.333) ? 0 : (snd < 0.666 ? 1 : 2);
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_GRENADE_EXPLODE);
    // 0, not the owner: unlike a thrown grenade the satchel's owner is not
    // predicting anything here - they pressed a button and the server decided.
    // Excluding them would cost them the explosion they just asked for.
    WriteShort(MSG_MULTICAST, 0);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z + 8);
    WriteByte(MSG_MULTICAST, snd_idx);
    multicast(self.origin, MULTICAST_PVS);

    W_RadiusExplode(self.origin, SATCHEL_RADIUS,
                    SATCHEL_DAMAGE, SATCHEL_MIN_DAMAGE,
                    SATCHEL_KNOCKBACK_PUSH, SATCHEL_KNOCKBACK_UPLIFT, self.owner);

    remove(self);
};

// satchel.cpp:92 SatchelSlide.  Two things happen on the first contact that
// do not happen again: gravity goes to normal (the charge is thrown on a
// lobbed 0.5 and then behaves like a brick), and the slide is damped.
void() W_SatchelChargeTouch =
{
    if (other == self.owner)
        return;

    self.gravity = 1;                       // satchel.cpp:99

    // THE DAMPING IS GROUND-ONLY, and that is the whole reason the charge
    // skitters across a floor in Half-Life instead of dying where it lands.
    //
    // satchel.cpp:103-113 gates both multipliers behind an explicit downward
    // trace, comment and all:
    //     // HACKHACK - On ground isn't always set, so look for ground underneath
    //     UTIL_TraceLine(pev->origin, pev->origin - Vector(0,0,10),
    //                    ignore_monsters, edict(), &tr);
    //     if (tr.flFraction < 1.0)
    //     {
    //         // add a bit of static friction
    //         pev->velocity  = pev->velocity  * 0.95;
    //         pev->avelocity = pev->avelocity * 0.9;
    //     }
    // Applying 0.95/0.9 on EVERY contact instead — which is what this used to
    // do — charges the static-friction tax to wall grazes and ceiling clips as
    // well.  A charge lobbed down a corridor clips the wall once on the way out
    // and lands with most of its throw speed already gone, so it drops at your
    // feet rather than sliding away down the hall.
    //
    // ignore_monsters matters too: a charge bouncing off a player or a monster
    // must not be treated as having found ground.  MOVE_NOMONSTERS is that.
    traceline(self.origin, self.origin - '0 0 10', MOVE_NOMONSTERS, self);
    if (trace_fraction < 1.0)
    {
        self.velocity  = self.velocity  * 0.95; // satchel.cpp:110
        self.avelocity = self.avelocity * 0.9;  // satchel.cpp:111
    }

    if (!(self.flags & FL_ONGROUND) && vlen(self.velocity) > 10)
    {
        float r = random();
        string s;
        if      (r < 0.333) s = "weapons/g_bounce1.wav";
        else if (r < 0.666) s = "weapons/g_bounce2.wav";
        else                s = "weapons/g_bounce3.wav";
        sound(self, CHAN_VOICE, s, 1, ATTN_NORM);
    }
};

void() W_SatchelChargeThink =
{
    self.nextthink = time + 0.1;

    // satchel.cpp:135 — a charge that finds itself in water swims rather
    // than sinking, which is what lets you mine an underwater doorway.
    if (self.waterlevel == 3)
    {
        self.movetype = MOVETYPE_FLY;
        self.velocity  = self.velocity  * 0.8;
        self.avelocity = self.avelocity * 0.9;
        self.velocity_z = self.velocity_z + 8;
    }
    else if (self.waterlevel == 0)
        self.movetype = MOVETYPE_BOUNCE;
    else
        self.velocity_z = self.velocity_z - 8;
};

// Deliberately a plain server entity rather than a CSQC-replicated one: a
// satchel is placed and then walked away from, so its owner has to see it,
// and projectile_SendEntity exists precisely to HIDE a projectile from its
// owner.  Engine replication shows it to everybody, which is what HL does.
entity(entity thrower, vector org, vector vel) W_SatchelChargeSpawn =
{
    entity c = spawn();
    c.owner     = thrower;
    c.classname = "monster_satchel";        // satchel.cpp:54, so the detonate sweep finds it
    c.movetype  = MOVETYPE_BOUNCE;
    c.solid     = SOLID_BBOX;
    setmodel(c, SATCHEL_CHARGE_MODEL);
    c.frame = SATCHEL_SEQ_ONBACK;           // satchel.cpp:88 — thrown charges lie flat
    setsize(c, '-4 -4 -4', '4 4 4');        // satchel.cpp:76 — point-sized to HL
    // ...but NOT point-sized to FTE, which picks the world clipping hull from
    // the bbox SIZE with Quake's `size[0] < 3` threshold (q1bsp.c:1554) rather
    // than GoldSrc's `size[0] <= 8`.  size[0] here is 8, so without this the
    // charge collides with the world as HL's 32x32x36 crouch hull (hulls[3],
    // gl_model.c:5564), offset by clip_mins - mins = (-12,-12,-14), i.e. a
    // volume 28 units oversized in +x/+y.  It stops short of walls and can come
    // to rest visibly hanging off a ledge.  Same defect as the snark — see the
    // long note in sh_wpn_hlsnark.qc's W_SnarkSpawn.  1 == hulls[0] == point.
    c.hull = 1;
    setorigin(c, org);
    c.velocity    = vel;
    c.avelocity_y = SATCHEL_THROW_AVELOCITY_Y;
    c.gravity     = SATCHEL_GRAVITY;
    // .friction is NOT the MOVETYPE_BOUNCE damping in FTE — no server physics
    // path reads that field (only ODE's contact mu, com_phys_ode.c:2771).  The
    // backoff comes from .bouncefactor: `1 + bouncefactor`, default 1.5
    // (sv_phys.c:1447).  GoldSrc's is `2.0 - pev->friction`, so the conversion
    // is bouncefactor = 1 - friction: 0.8 here gives HL's backoff of 1.2, a
    // noticeably deader bounce than the 1.5 this charge has been using.
    c.bouncefactor = 1 - SATCHEL_FRICTION;
    c.touch       = W_SatchelChargeTouch;
    c.think       = W_SatchelChargeThink;
    c.nextthink   = time + 0.1;
    return c;
};

// HL's DeactivateSatchels (multiplay_gamerules.cpp, on PlayerKilled).  It
// REMOVES the charges rather than detonating them - a detonation on death
// would be a free posthumous frag - and it is the reason PlayerSpawn can
// reset satchel_state to HOLD honestly: without this, a player who died with
// charges out would respawn disowning charges that were still on the map with
// nothing left able to set them off.
//
// The cached c.chain is enough HERE, because remove() does not touch any other
// entity's .chain -- nxt is already read and stays valid.  Do not generalise that
// to W_SatchelDetonateAll below: exploding runs findradius, which REBUILDS .chain
// across the map, and no amount of look-ahead survives that.  This function is
// safe only because removing is all it does.
void(entity who) W_SatchelDeactivateAll =
{
    if (!who) return;
    entity c = findchain(classname, "monster_satchel");
    while (c)
    {
        entity nxt = c.chain;
        if (c.owner == who)
            remove(c);
        c = nxt;
    }
    who.satchel_state = SATCHEL_STATE_HOLD;
};

// satchel.cpp:365 — every charge this player owns, anywhere on the map.  HL
// bounds the sweep to a 4096-unit sphere; that is an artefact of
// UTIL_FindEntityInSphere being the only search it had, not a design choice,
// so the sweep here is by classname over the whole map.
//
// TWO PASSES, and the split is load-bearing.  Exploding inside the findchain walk
// corrupts it: W_SatchelChargeExplode -> W_RadiusExplode uses findradius
// (sh_weapon_standard.qc:608), and findchain and findradius BUILD THEIR LISTS IN
// THE SAME .chain FIELD.  Caching `nxt` only protects the current hop -- by the
// second detonation nxt.chain has already been overwritten, so from there the loop
// walks the blast-radius list instead of the satchel list.  Charges past the second
// survived ("doesn't blow them ALL up"), and worse, `if (c.owner == who)` then
// matched arbitrary player-owned entities inside the 375-unit sphere
// (player_visual_proxy, pm_prediction_proxy, tripmine_beam) and explode+remove()d
// them.  Latent until the wep_nextframe freeze above was fixed, because nothing
// detonated at all; and invisible to W_SatchelSelfTest, which uses exactly 2
// charges -- the one count where the cached nxt still happens to be right.
//
// HL is immune because UTIL_FindEntityInSphere is a stateless edict-index scan
// with no per-entity link field to clobber.
//
// remove() during the walk was never the hazard the old comment claimed; the
// findradius inside the explosion was.
// Re-scan per charge rather than snapshotting the list up front.  A snapshot
// would need a fixed bound, and there is no honest one: W_SatchelPickupCopy caps
// CARRIED ammo at 5 but never counts live charges the way HL's AddDuplicate does
// (satchel.cpp:177), so throwing five, picking more up and throwing again leaves
// more than five out.  A snapshot could also hold a charge that a previous blast
// already remove()d.  W_SatchelChargeExplode ends in remove(), so re-finding
// always shrinks the set and the loop terminates; the counter is a backstop
// against an explosion that somehow fails to remove.
void(entity who) W_SatchelDetonateAll =
{
    entity oldself = self;
    float  guard = 0;

    for (;;)
    {
        entity target = world;
        entity c = findchain(classname, "monster_satchel");
        while (c)
        {
            if (c.owner == who)
            {
                target = c;
                break;
            }
            c = c.chain;
        }

        if (!target)
            break;

        guard = guard + 1;
        if (guard > 64)
        {
            dprint("[satchel] W_SatchelDetonateAll: bailed at 64 - a charge is not being removed\n");
            break;
        }

        self = target;
        W_SatchelChargeExplode();
        self = oldself;
    }
};

// Defined just below; W_SatchelFire's out-of-charges branch calls it.
void() W_SatchelAltFire;

void() W_SatchelFire =
{
    float r = SH_SatchelTryThrow(time);

    // -2: nothing left to throw, charges live.  Route into the SAME detonate
    // path +attack2 uses rather than duplicating it - SH_SatchelTryDetonate
    // owns the SPENT transition, the animation timing and attack_finished.
    if (r == -2)
    {
        W_SatchelAltFire();
        return;
    }

    if (r == 1)
    {
        makevectors(self.v_angle);
        vector src = self.origin + self.view_ofs + v_forward * 16;
        W_SatchelChargeSpawn(self, src, v_forward * SATCHEL_THROW_FORWARD + self.velocity);

        // The radio comes up the moment the charge leaves your hand
        // (satchel.cpp:409), not when the animation finishes.
        self.weaponmodel = SATCHEL_RADIO_VIEWMODEL;
        self.weaponframe = SATCHEL_RADIO_SEQ_DRAW;
        // MUST schedule, not clear.  sv_weapons.qc:3820 only calls wepframe when
        // wep_nextframe > 0, so a 0 here retires W_SatchelFrame permanently --
        // and W_SatchelFrame is the only thing that reaches SH_WeaponEnterIdle.
        // weaponstate then sits at WS_FIRE forever, and SH_SatchelTryThrow:147 /
        // SH_SatchelTryDetonate:180 both refuse on exactly that, so you got one
        // charge per equip and a dead detonator.  CSQC has no such gate
        // (cl_weapons.qc:1592 predicts unconditionally), so the client threw and
        // the server did not -- which is why the charge never appeared and the
        // ammo count flickered back.  0 is only correct in a holster path.
        self.wep_nextframe = time + SATCHEL_FRAME_INTERVAL;
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_SatchelAltFire =
{
    if (!SH_SatchelTryDetonate(time)) return;

    self.weaponframe   = SATCHEL_RADIO_SEQ_FIRE;
    self.wep_nextframe = time + SATCHEL_FRAME_INTERVAL;   // see W_SatchelFire
    W_SatchelDetonateAll(self);
};

void() W_SatchelFrame =
{
    float result = SH_SatchelTickState(time);
    if (result & 1)
    {
        // satchel.cpp:440 — the idle after a detonation is where the radio
        // goes away and the satchel comes back, and it is also the only place
        // that retires the weapon when the last charge has been used.
        if (self.satchel_state == SATCHEL_STATE_SPENT)
        {
            self.satchel_state = SATCHEL_STATE_HOLD;
            if (self.ammo_satchel <= 0 && self.weapon == WEP_SATCHEL)
            {
                // Re-point slot_utility BEFORE trying to switch.  Without this
                // the auto-switch was a literal no-op: slot_utility still said
                // WEP_SATCHEL, and W_SelectWeapon early-returns on
                // `new_weapon == cur` (sv_weapons.qc), so the `return` below
                // then skipped the whole fallback chain and left the player
                // holding a satchel they no longer owned.  Every other utility
                // weapon already does this at spend time (hlgrenade, snark,
                // tripmine all call W_UtilityNextAfterSpent); the satchel is the
                // one that never did, because its retire is deferred until the
                // last charge has actually been detonated.
                //
                // That deferral is correct and is HL's rule -- CSatchel::Holster
                // clears the weapon bit only when the count is 0 AND
                // m_chargeReady is 0, so you keep the radio while charges are
                // live (satchel.cpp:340-347, :277-291).  This tree already
                // encodes the ownership half of that in
                // W_UtilityPlayerHasWeapon; only the slot re-point was missing.
                self.slot_utility = W_UtilityNextAfterSpent(WEP_SATCHEL);

                if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
                else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
                else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
                else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
                return;
            }
            self.weaponmodel = SATCHEL_VIEWMODEL;
            self.weaponframe = SATCHEL_SEQ_DRAW;
        }
        else
        {
            self.weaponmodel = SH_SatchelViewmodel();
            self.weaponframe = (self.satchel_state == SATCHEL_STATE_HOLD)
                                ? SATCHEL_SEQ_IDLE : SATCHEL_RADIO_SEQ_IDLE;
        }
        self.wep_nextframe = 0;
    }
};

void() W_SatchelEquip =
{
    // satchel.cpp:493 picks the viewmodel from the charge state, so drawing
    // the weapon while charges are live puts the radio in your hand.
    W_StandardEquipSetup(SH_SatchelViewmodel(), SATCHEL_DISPLAY_NAME,
        (self.satchel_state == SATCHEL_STATE_HOLD) ? SATCHEL_SEQ_DRAW : SATCHEL_RADIO_SEQ_DRAW,
        SATCHEL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire       = W_SatchelFire;
    self.altfire    = W_SatchelAltFire;
    self.reload     = __NULL__;
    self.wepframe   = W_SatchelFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_SatchelDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_satchel = self.ammo_satchel;
    self.ammo_satchel = 0;

    setmodel(tgt, SATCHEL_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_satchel";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_SATCHEL;
    tgt.weapon_slot  = SLOT_UTILITY;
    tgt.weap_draw    = W_SatchelEquip;
    tgt.weap_drop_func = W_SatchelDrop;
    tgt.pickupcopy   = W_SatchelPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_satchel =
{
    setmodel(self, SATCHEL_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_satchel";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_SATCHEL;
    self.weapon_slot   = SLOT_UTILITY;
    self.weap_draw     = W_SatchelEquip;
    self.weap_drop_func = W_SatchelDrop;
    self.pickupcopy    = W_SatchelPickupCopy;
    self.touch         = weapon_touch;
    // SATCHEL_DEFAULT_GIVE is 1 (weapons.h:155).  Map placements hand over a
    // single charge, not a full pouch - ammo_satchel pickups top it up.
    self.ammo_satchel  = 1;
    W_RegisterMapWeapon(weapon_satchel);
};
void() spawnfunc_weapon_satchel = { weapon_satchel(); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void(float new_weapon) CSQC_PredictSelectWeapon;

void() CSQC_PredictSatchelCommand =
{
    if (input_buttons & 1)
    {
        float r = SH_SatchelTryThrow(csqc_pred_time);
        // -2: out of charges with satchels live, so +attack detonates.  Mirrors
        // W_SatchelFire exactly - same shared gate, same detonate call - so the
        // two sides cannot disagree about which of the two things the key did.
        if (r == -2)
        {
            if (SH_SatchelTryDetonate(csqc_pred_time))
                CSQC_MarkPendingWeaponAck();
        }
        else if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            self.weapon_viewmodel = SATCHEL_RADIO_VIEWMODEL;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Bit 4 is +attack2.  This read bit 2 for the whole life of the file, which
    // is PM_BTN_JUMP (sh_pmove.qc:42) - so the detonator predicted nothing on
    // the key that actually detonates (the server still did it, with no local
    // radio animation, which is what made the weapon feel dead) and predicted a
    // phantom detonation on +jump.  Every other secondary-fire weapon in the
    // tree tests 4; see sh_weapon_logic.qc:320.
    if (input_buttons & 4)
    {
        if (SH_SatchelTryDetonate(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (SH_SatchelTickState(csqc_pred_time) & 1)
    {
        if (self.satchel_state == SATCHEL_STATE_SPENT)
        {
            self.satchel_state = SATCHEL_STATE_HOLD;
            if (self.ammo_satchel <= 0)
            {
                // Mirror of the server's re-point above -- CSQC_PredictSelectWeapon
                // has the same `new_weapon == self.weapon` early-return, so
                // without this the predicted switch was a no-op too and the two
                // sides at least agreed about being stuck.
                self.slot_utility = W_UtilityNextAfterSpent(WEP_SATCHEL);

                if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
                else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
                else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
                else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
                return;
            }
        }
        self.weapon_viewmodel = SH_SatchelViewmodel();
    }
};

float(float elapsed) CSQC_SatchelDisplayFrame =
{
    float armed = (predicted_player.satchel_state != SATCHEL_STATE_HOLD);

    if (predicted_player.weaponstate == WS_DRAW)
        return armed ? SATCHEL_RADIO_SEQ_DRAW : SATCHEL_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // The throw plays the RADIO's draw (satchel.cpp:412 sends
        // SATCHEL_RADIO_DRAW straight after swapping the model), and the
        // detonation plays the radio's fire.
        if (predicted_player.satchel_state == SATCHEL_STATE_SPENT)
            return SATCHEL_RADIO_SEQ_FIRE;
        return SATCHEL_RADIO_SEQ_DRAW;
    }
    return armed ? SATCHEL_RADIO_SEQ_IDLE : SATCHEL_SEQ_IDLE;
};

void() CSQC_SatchelDropClear =
{
    self.ammo_satchel = 0;
    self.satchel_state = SATCHEL_STATE_HOLD;
};

void() CSQC_SatchelEquip =
{
    self.weapon_name         = SATCHEL_DISPLAY_NAME;
    self.weapon_viewmodel    = SH_SatchelViewmodel();
    self.weapon_worldmodel   = SATCHEL_WORLDMODEL;
    self.weapon_deploy_sound = SATCHEL_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSatchelCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_SatchelDisplayFrame;
    self.csqc_drop_clear     = CSQC_SatchelDropClear;
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game, and it is the ONLY Half-Life or
    // Opposing Force weapon in the tree that needs this.  The reason is the mount
    // order rather than anything about the satchel: svencoop is line 1 of
    // fs_addons.txt, and Sven ships its own remodelled v_satchel.mdl (375 KB) and
    // v_satchel_radio.mdl (386 KB) against Valve's 82 KB / 61 KB, so neither of
    // these two paths loads a Valve asset any more.  Sven's pair was authored the
    // other way round from Valve's.  One field covers both viewmodels because
    // SH_SatchelViewmodel only swaps the path, not the flip.
    //
    // cl_lefthand XORs against this, so reverting is one word.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
