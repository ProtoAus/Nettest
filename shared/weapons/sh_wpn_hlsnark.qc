// ============================================================
//  shared/weapons/sh_wpn_hlsnark.qc  -  HL Snark (squeak grenade)
//
//  Slot  : SLOT_UTILITY  (impulse 4 / key 4)
//  Stats : ammo_snark (direct pool, max 15 — SNARK_MAX_CARRY, weapons.h:119)
//  Fire  : +attack drops a live snark in front of you.  It hunts, bites, and
//          pops on a 15 s fuse — or when killed, which is the same thing.
//
//  Ported from the SDK: dlls/squeakgrenade.cpp.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Sequence indices ----------------------------------------------------
// v_squeak.mdl, 6 sequences, matching squeak_e (squeakgrenade.cpp:31).
const float SNARK_SEQ_IDLE       = 0;   // idle1,      1.875 s, looping
const float SNARK_SEQ_FIDGETFIT  = 1;   // fidgetfit,  4.375 s
const float SNARK_SEQ_FIDGETNIP  = 2;   // fidgetnip,  5.000 s
const float SNARK_SEQ_DOWN       = 3;   // down,       1.250 s
const float SNARK_SEQ_UP         = 4;   // up,         1.667 s
const float SNARK_SEQ_THROW      = 5;   // throw,      0.542 s

// w_squeak.mdl, 4 sequences, matching w_squeak_e (squeakgrenade.cpp:25).
const float SNARK_W_SEQ_IDLE   = 0;
const float SNARK_W_SEQ_FIDGET = 1;
const float SNARK_W_SEQ_JUMP   = 2;
const float SNARK_W_SEQ_RUN    = 3;     // 0.178 s at 45 fps, looping

const float SNARK_FRAME_INTERVAL = 0.05;
const float SNARK_DRAW_DURATION  = 1.0;    // squeakgrenade.cpp:390 gates at 0.5, the
                                           // "up" sequence runs 1.667; 1.0 is where
                                           // the snark is actually in shot.
const float SNARK_THROW_DURATION = 0.542;  // the throw sequence's own length

const float MAX_AMMO_SNARK       = 15;     // SNARK_MAX_CARRY, weapons.h:119

// --- Balance -------------------------------------------------------------
// valve/skill.cfg: sk_snark_health 2, sk_snark_dmg_bite 10, sk_snark_dmg_pop 5.
const float SNARK_HEALTH         = 2;
const float SNARK_DMG_BITE       = 10;
const float SNARK_DMG_POP        = 5;
const float SNARK_POP_RADIUS     = 12.5 * 2.5;  // pop damage * 2.5, HL's derived radius
const float SNARK_FUSE           = 15.0;   // SQUEEK_DETONATE_DELAY, squeakgrenade.cpp:76
const float SNARK_THROW_FORWARD  = 200;    // squeakgrenade.cpp:456
const float SNARK_GRAVITY        = 0.5;    // squeakgrenade.cpp:112
const float SNARK_FRICTION       = 0.5;    // squeakgrenade.cpp:132 — bounce damping
const float SNARK_SIGHT_RANGE    = 512;    // squeakgrenade.cpp:206 Look(512)
const float SNARK_HUNT_INTERVAL  = 2.0;    // squeakgrenade.cpp:196
const float SNARK_ATTACK_DELAY   = 0.3;    // squeakgrenade.cpp:468

const string SNARK_VIEWMODEL     = "models/v_squeak.mdl";
// w_sqknest.mdl is the nest HL uses for the ground pickup.  This used to read
// "It is NOT on this mount, so the pickup is a snark instead - visibly a snark
// rather than a nest of them, and the one asset compromise in this weapon."
// That was wrong: valve/models/w_sqknest.mdl is present and always has been
// (listed alongside w_squeak.mdl, w_squeakt.mdl and w_sqknestt.mdl).  The
// pickup is the nest now, which is what Half-Life shows and what the pickup
// giving FIVE snarks has always implied.
const string SNARK_WORLDMODEL    = "models/w_sqknest.mdl";
const string SNARK_LIVE_MODEL    = "models/w_squeak.mdl";
const string SNARK_DEPLOY_SOUND  = "";
const string SNARK_DISPLAY_NAME  = "SNARK";

float(float spent_wep) W_UtilityNextAfterSpent;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_SnarkTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SNARK_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SNARK_THROW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// IS THERE ROOM TO LET THE CREATURE GO?
//
// squeakgrenade.cpp:444 traces 24→60 units out and releases only if that space
// is clear, or you would spawn a live monster inside the wall you are facing.
// This port ran that trace AFTER stamping SNARK_SEQ_THROW, so facing a wall
// played a full throw animation and produced nothing — the same shape as the
// tripmine's place take.  Both weapons are server-autonomous, so CSQC ran the
// identical permissive gate and animated too.
//
// THE ANGLES ARE A PARAMETER, not read from self, and that is load-bearing:
// predicted_player carries no .v_angle on CSQC (sh_wpn_csknife.qc:610 and
// csshield.qc:310 both record this), so a shared body reading self.v_angle would
// trace along world +X on the client and gate on where the player is standing
// rather than where they are looking.  SSQC passes self.v_angle, CSQC passes
// input_angles.
//
// The penguin calls this too — it is a re-skin of the snark and already
// delegates its spawn to W_SnarkSpawn.
//
// Client and server WILL disagree occasionally: the third traceline argument is
// FALSE, so monsters, players and doors block it, and the client's entity set is
// not the server's.  That is accepted, not solved — Half-Life itself does not
// even use the same trace on both sides (a point trace server-side, a hull trace
// with a 0.25 fraction floor client-side).  The client's copy is cosmetic; the
// server's is authoritative.
float(vector aim_angles) SH_SnarkHasReleaseRoom =
{
    makevectors(aim_angles);
    vector src = self.origin + self.view_ofs;
    traceline(src + v_forward * 24, src + v_forward * 60, FALSE, self);
    return !(trace_allsolid || trace_startsolid || trace_fraction <= 0);
};

float(float now) SH_SnarkTryThrow =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.ammo_snark <= 0) return 0;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SNARK_ATTACK_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Additive and capped — see W_SatchelPickupCopy for why.
void(entity player) W_SnarkPickupCopy =
{ player.ammo_snark = bound(0, player.ammo_snark + self.ammo_snark, MAX_AMMO_SNARK); };

.float snark_die_time;
.float snark_next_hunt;
.float snark_next_hit;
.float snark_next_bite;
.float snark_pop_damage;      // grows by SNARK_DMG_POP per bite (squeakgrenade.cpp:296)
.vector snark_prev_pos;
.entity snark_enemy;
// Attribution, kept SEPARATE from .owner on purpose.  squeakgrenade.cpp:266
// clears pev->owner on the first bounce - that is what lets a snark turn round
// and bite the person who threw it - but it keeps m_hOwner so the kill still
// goes on their scoreboard.  Collapsing the two would silently hand every snark
// kill to the snark.
.entity snark_owner;

// squeakgrenade.cpp:216 — the squeak rises in pitch as the fuse burns down.
// It is the single most recognisable thing about the weapon, so it is worth
// getting exactly: 155 down to 95 over the 15 seconds, floored at 80.
float(entity s) Snark_Pitch =
{
    float p = 155.0 - 60.0 * ((s.snark_die_time - time) / SNARK_FUSE);
    if (p < 80) p = 80;
    return p;
};

void() W_SnarkPop =
{
    // squeakgrenade.cpp:135 Killed.  The blast damage is the accumulated
    // pop damage, so a snark that has been chewing on somebody hits harder.
    sound(self, CHAN_ITEM, "squeek/sqk_blast1.wav", 1, 0.5);

    float dmg = self.snark_pop_damage;
    if (dmg < SNARK_DMG_POP) dmg = SNARK_DMG_POP;

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_GRENADE_EXPLODE);
    WriteShort(MSG_MULTICAST, 0);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z + 4);
    WriteByte(MSG_MULTICAST, floor(random() * 3));
    multicast(self.origin, MULTICAST_PVS);

    // squeakgrenade.cpp:184 falls back to the snark ITSELF when m_hOwner is
    // NULL, and an ownerless snark is now common: every map-placed one and every
    // squadmaker child spawns with owner == world (monstermaker.cpp:211-212 sets
    // the owner only after DispatchSpawn).  Without the fallback all 76 corpus
    // makers' explosions would be credited to `world`.
    W_RadiusExplode(self.origin, dmg * 2.5, dmg, 1, 200, 100,
                    self.snark_owner ? self.snark_owner : self);
    remove(self);
};

void() W_SnarkDie = { W_SnarkPop(); };

// squeakgrenade.cpp:258 SuperBounceTouch.  A snark bites whatever it lands on
// if that thing can be hurt, and squeaks either way.
void() W_SnarkTouch =
{
    // squeakgrenade.cpp:327 — `if ( pev->owner && pOther->edict() == pev->owner )`.
    // THE NULL-CHECK IS LOAD-BEARING and was dropped in the port.  FTE delivers a
    // world contact with other == world (world.c:2632 deliberately "misreports"
    // trace.ent as the world edict, and sv_phys.c:1437 only skips the impact when
    // trace.ent is null), so once line below has set .owner to world, EVERY
    // subsequent world bounce matched `other == self.owner` and returned here.
    // Consequences, all of which this restores:
    //   * the hunt re-arm at the bottom stopped happening from the second bounce
    //     on, so a snark steered on the 2 s HuntThink timer where HL re-steers on
    //     every bounce;
    //   * the bounce squeak was skipped on every world bounce after the first;
    //   * a MAP-PLACED monster_snark is spawned with thrower == world
    //     (sv_monsters.qc), so its owner IS world and it returned on its very
    //     first floor contact — it never re-armed at all.
    if (self.owner != world && other == self.owner)
        return;
    self.owner = world;             // squeakgrenade.cpp:331 — after one bounce it is nobody's

    if (time < self.snark_next_hit)
        return;

    float pitch = Snark_Pitch(self);

    // .takedamage is NOT the test for a player: this mod leaves players at
    // DAMAGE_NO and accepts them inside W_CanDamageTarget instead (see
    // sv_weapons.qc:1149), so gating on takedamage alone means a snark bites
    // crates and monsters but walks straight over the person it is hunting.
    if (other && other != world && time >= self.snark_next_bite
        && other.classname != "monster_snark"
        && (other.takedamage || other.classname == "player"))
    {
        W_ApplyDamage(self.snark_owner ? self.snark_owner : self, other, SNARK_DMG_BITE);
        self.snark_pop_damage += SNARK_DMG_POP;   // squeakgrenade.cpp:296
        sound(self, CHAN_WEAPON, "squeek/sqk_deploy1.wav", 1, ATTN_NORM, pitch, 0);
        self.snark_next_bite = time + 0.5;
    }

    self.snark_next_hit  = time + 0.1;
    self.snark_next_hunt = time;      // re-aim on the very next think

    if (!(self.flags & FL_ONGROUND))
    {
        float r = random();
        string s;
        if      (r <= 0.33) s = "squeek/sqk_hunt1.wav";
        else if (r <= 0.66) s = "squeek/sqk_hunt2.wav";
        else                s = "squeek/sqk_hunt3.wav";
        sound(self, CHAN_VOICE, s, 1, ATTN_NORM, pitch, 0);
    }
};

// squeakgrenade.cpp:163 HuntThink, at 10 Hz.
void() W_SnarkThink =
{
    self.nextthink = time + 0.1;

    if (time >= self.snark_die_time)
    { W_SnarkPop(); return; }

    // Float rather than sink (squeakgrenade.cpp:180).
    if (self.waterlevel != 0)
    {
        self.movetype = MOVETYPE_FLY;
        self.velocity = self.velocity * 0.9;
        self.velocity_z = self.velocity_z + 8;
    }
    else if (self.movetype == MOVETYPE_FLY)
        self.movetype = MOVETYPE_BOUNCE;

    if (time < self.snark_next_hunt)
        return;
    self.snark_next_hunt = time + SNARK_HUNT_INTERVAL;

    // Death squeak, in the last half second (squeakgrenade.cpp:212).
    if ((self.snark_die_time - time) <= 0.5 && (self.snark_die_time - time) >= 0.3)
        sound(self, CHAN_VOICE, "squeek/sqk_die1.wav", 1, ATTN_NORM,
              100 + floor(random() * 63), 0);

    // Retarget.  A snark will chase anything that can be hurt and is not
    // another snark - squeakgrenade.cpp's Look/BestVisibleEnemy with the
    // insect relationship, reduced to what matters here.
    if (!self.snark_enemy || self.snark_enemy.health <= 0)
    {
        entity best = world;
        float bestd = SNARK_SIGHT_RANGE;
        entity e = findradius(self.origin, SNARK_SIGHT_RANGE);
        while (e)
        {
            if (e != self && e.health > 0 && e.classname != "monster_snark"
                && (e.takedamage || e.classname == "player"))
            {
                traceline(self.origin, e.origin + e.view_ofs, TRUE, self);
                if (trace_fraction == 1 || trace_ent == e)
                {
                    float d = vlen(e.origin - self.origin);
                    if (d < bestd) { bestd = d; best = e; }
                }
            }
            e = e.chain;
        }
        self.snark_enemy = best;
    }

    if (self.snark_enemy)
    {
        vector dir = normalize((self.snark_enemy.origin + self.snark_enemy.view_ofs) - self.origin);
        // squeakgrenade.cpp:228: the slower it is going the harder it steers,
        // capped at 1.2, which is what makes a cornered snark so relentless.
        float flvel = vlen(self.velocity);
        float adj = 50.0 / (flvel + 10.0);
        if (adj > 1.2) adj = 1.2;
        self.velocity = self.velocity * adj + dir * 300;
    }

    if (self.flags & FL_ONGROUND)
        self.avelocity = '0 0 0';
    else if (self.avelocity == '0 0 0')
    {
        self.avelocity_x = random() * 200 - 100;
        self.avelocity_z = random() * 200 - 100;
    }

    // Anti-stick (squeakgrenade.cpp:246): if it has not moved a unit since the
    // last hunt, kick it somewhere random rather than let it vibrate in a corner.
    if (vlen(self.origin - self.snark_prev_pos) < 1.0)
    {
        self.velocity_x = random() * 200 - 100;
        self.velocity_y = random() * 200 - 100;
    }
    self.snark_prev_pos = self.origin;

    self.angles = vectoangles(self.velocity);
    self.angles_x = 0;
    self.angles_z = 0;
};

entity(entity thrower, vector org, vector vel) W_SnarkSpawn =
{
    entity s = spawn();
    s.owner       = thrower;
    s.snark_owner = thrower;
    s.classname = "monster_snark";       // squeakgrenade.cpp:64
    s.movetype  = MOVETYPE_BOUNCE;
    s.solid     = SOLID_BBOX;
    setmodel(s, SNARK_LIVE_MODEL);
    setsize(s, '-4 -4 0', '4 4 8');      // squeakgrenade.cpp:103
    // FORCE THE POINT HULL.  FTE picks the world clipping hull from the bbox
    // SIZE, and its point-hull threshold is Quake's `size[0] < 3`
    // (q1bsp.c:1554), not GoldSrc's `size[0] <= 8`.  An 8-wide snark therefore
    // falls through to hulls[3], which on a Half-Life BSP is HL's 32x32x36
    // CROUCH hull (gl_model.c:5564).  Worse, the hull offset is
    // clip_mins - mins = (-16,-16,-18) - (-4,-4,0) = (-12,-12,-18)
    // (q1bsp.c:1569), so the real collision volume sits at
    // origin+(-4,-4,0)..(28,28,36) — correct at one corner and 28/28/36 units
    // oversized at the other.  That is the entire "stuck in the air, doesn't
    // move, doesn't fly around accurately" report: the snark rests on a point
    // 12 units diagonally off the model it draws at, and needs a crouching
    // player's worth of clearance to travel anywhere.
    //
    // .hull overrides the choice (q1bsp.c:1532) and World_Move honours it for
    // physics pushes (world.c:2749).  1 == hulls[0] == the point hull, whose
    // clip_mins are zero, so the Z offset becomes exactly 0 and ground contact
    // is exact.  The bbox stays 8x8x8, so the snark is still shootable and
    // still touch-tests against players and monsters at its real size.
    //
    // Consequence to expect: hull 0 on a Q1/HL bsp carries no CONTENTS_CLIP
    // (qcsg only emits clip brushes into hulls 1-3), so the snark now passes
    // through player-clip brushes — exactly as a GoldSrc snark does.
    s.hull = 1;
    setorigin(s, org);
    s.velocity   = vel;
    s.gravity    = SNARK_GRAVITY;
    // squeakgrenade.cpp:132 sets friction 0.5 alongside gravity 0.5.  In FTE the
    // MOVETYPE_BOUNCE damping is NOT read from .friction — nothing in the server
    // physics touches that field (the only engine reader is the ODE rigid-body
    // path, com_phys_ode.c:2771, i.e. MOVETYPE_PHYSICS).  The bounce backoff
    // comes from .bouncefactor: sv_phys.c:1447 does
    // `backoff = ent->xv->bouncefactor ? 1 + bouncefactor : 1.5`.
    // So the old `s.friction = 0.5` was a no-op, which is why the
    // "snarks float around a little too much" report came back after it.
    // GoldSrc's bounce backoff is `2.0 - pev->friction` (engine-side; not in the
    // SDK on disk), so the CONVERSION IS `bouncefactor = 1 - friction`, NOT
    // `bouncefactor = friction`.  Those two agree only at 0.5, which is exactly
    // the snark's value — write it as the subtraction anyway so the next weapon
    // ported through here (the satchel is at 0.8) does not copy the wrong rule.
    // 1 + (1 - 0.5) == 1.5 == HL's 2.0 - 0.5 == FTE's own default, so the damping
    // was already right by accident and this only makes it explicit.  The real
    // cause of the float-around/stuck report is the collision hull forced above
    // — do NOT damp harder as a substitute for it.
    s.bouncefactor = 1 - SNARK_FRICTION;
    s.frame      = SNARK_W_SEQ_RUN;      // squeakgrenade.cpp:124
    s.takedamage = DAMAGE_AIM;
    s.health     = SNARK_HEALTH;
    s.on_killed  = W_SnarkDie;
    s.flags      = s.flags | FL_MONSTER;

    s.snark_die_time   = time + SNARK_FUSE;
    s.snark_pop_damage = SNARK_DMG_POP;
    s.snark_prev_pos   = org;
    // squeakgrenade.cpp:108 parks the first hunt a million seconds out.  That is
    // NOT a one-second flight grace period, which is how it was ported: it is an
    // effectively infinite gate, and the ONLY thing that ever opens it is the
    // first bounce — SuperBounceTouch sets m_flNextHunt = gpGlobals->time on
    // every touch (squeakgrenade.cpp:376), which W_SnarkTouch already mirrors.
    // A HL snark that has not touched anything yet never steers; its throw arc
    // is pure ballistics.  With `time + 1.0` this one got a free 300-unit
    // steering kick toward the target's eyes while still airborne.
    // ORDER MATTERS: this line is only safe because W_SnarkTouch's owner guard
    // above has been given back its null-check.  Without that, a map-placed
    // monster_snark (thrower == world, sv_monsters.qc) returns from its very
    // first floor contact, never re-arms, and a million-second gate would leave
    // all 18 corpus placements inert lumps until the 15 s fuse.  With the guard
    // fixed it lands, touches, re-arms and hunts exactly as HL does.
    //
    // Honest scope note: at SNARK_GRAVITY 0.5 x sv_gravity 800 = 400 u/s^2 from
    // eye height, an ordinary throw hits the floor at ~0.5-0.7 s — BEFORE the old
    // 1.0 s gate — so on a normal throw this changes nothing visible.  It is
    // faithfulness, not the cure for floaty snarks; the hull above is that.
    s.snark_next_hunt  = time + 1000000;

    s.touch     = W_SnarkTouch;
    s.think     = W_SnarkThink;
    s.nextthink = time + 0.1;
    return s;
};

void() W_SnarkFire =
{
    // BEFORE the try-throw, so a blocked release costs no WS_FIRE, no action-id
    // bump, no weaponframe and no cooldown.  Silent, like Half-Life: both
    // squeakgrenade.cpp:565 and ev_hldm.cpp:1663 simply skip the animation with
    // no sound — a thrown creature has no dry-fire.
    if (!SH_SnarkHasReleaseRoom(self.v_angle)) return;
    if (!SH_SnarkTryThrow(time)) return;

    self.weaponframe   = SNARK_SEQ_THROW;
    // MUST schedule, not clear -- the same defect the satchel and tripmine both
    // had.  sv_weapons.qc only calls wepframe while wep_nextframe > 0, and
    // W_SnarkFrame below is the ONLY route to SH_WeaponEnterIdle, so a 0 here
    // retires the frame function permanently: weaponstate pins at WS_FIRE and
    // SH_SnarkTryThrow's `weaponstate != WS_IDLE` gate then refuses every later
    // throw.  One snark per equip.
    self.wep_nextframe = time + SNARK_FRAME_INTERVAL;

    // Re-run for the spawn point.  SH_SnarkHasReleaseRoom above already proved
    // the space is clear and left makevectors pointing the right way, but the
    // try-throw sits between them, so trace_endpos is re-derived here rather than
    // assumed to have survived.
    if (!SH_SnarkHasReleaseRoom(self.v_angle))
        return;

    W_SnarkSpawn(self, trace_endpos, v_forward * SNARK_THROW_FORWARD + self.velocity);
    self.ammo_snark -= 1;

    if (random() <= 0.5)
        sound(self, CHAN_VOICE, "squeek/sqk_hunt2.wav", 1, ATTN_NORM, 105, 0);
    else
        sound(self, CHAN_VOICE, "squeek/sqk_hunt3.wav", 1, ATTN_NORM, 105, 0);

    if (self.ammo_snark <= 0)
        self.slot_utility = W_UtilityNextAfterSpent(WEP_SNARK);
};

void() W_SnarkFrame =
{
    float result = SH_SnarkTickState(time);
    if (result & 1)
    {
        if (self.ammo_snark <= 0 && self.weapon == WEP_SNARK)
        {
            if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
            else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
            else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
            return;
        }
        self.weaponframe   = SNARK_SEQ_IDLE;
        self.wep_nextframe = 0;
    }
};

void() W_SnarkEquip =
{
    W_StandardEquipSetup(SNARK_VIEWMODEL, SNARK_DISPLAY_NAME, SNARK_SEQ_UP,
        SNARK_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_SnarkFire;
    self.altfire  = __NULL__;
    self.reload   = __NULL__;
    self.wepframe = W_SnarkFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    // squeakgrenade.cpp:376 — drawing the weapon squeaks.
    if (random() <= 0.5)
        sound(self, CHAN_VOICE, "squeek/sqk_hunt2.wav", 1, ATTN_NORM, 100, 0);
    else
        sound(self, CHAN_VOICE, "squeek/sqk_hunt3.wav", 1, ATTN_NORM, 100, 0);
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_SnarkDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_snark = self.ammo_snark;
    self.ammo_snark = 0;

    setmodel(tgt, SNARK_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_snark";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_SNARK;
    tgt.weapon_slot  = SLOT_UTILITY;
    tgt.weap_draw    = W_SnarkEquip;
    tgt.weap_drop_func = W_SnarkDrop;
    tgt.pickupcopy   = W_SnarkPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_snark =
{
    setmodel(self, SNARK_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_snark";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_SNARK;
    self.weapon_slot   = SLOT_UTILITY;
    self.weap_draw     = W_SnarkEquip;
    self.weap_drop_func = W_SnarkDrop;
    self.pickupcopy    = W_SnarkPickupCopy;
    self.touch         = weapon_touch;
    self.ammo_snark    = 5;             // SNARK_DEFAULT_GIVE, weapons.h:157
    W_RegisterMapWeapon(weapon_snark);
};
void() spawnfunc_weapon_snark = { weapon_snark(); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void(float new_weapon) CSQC_PredictSelectWeapon;

void() CSQC_PredictSnarkCommand =
{
    if (input_buttons & 1)
    {
        // input_angles, NOT self.v_angle — predicted_player has no v_angle on
        // CSQC.  This is the half that actually stops the phantom animation:
        // the client stamps its own WS_FIRE and reconcile never rewinds it
        // (client/cl_player.qc:1022), so a server-only gate would be invisible.
        if (SH_SnarkHasReleaseRoom(input_angles)
            && SH_SnarkTryThrow(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (SH_SnarkTickState(csqc_pred_time) & 1)
    {
        if (self.ammo_snark <= 0)
        {
            if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
            else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
            else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
        }
    }
};

float(float elapsed) CSQC_SnarkDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SNARK_SEQ_UP;
    if (predicted_player.weaponstate == WS_FIRE)
        return SNARK_SEQ_THROW;
    return SNARK_SEQ_IDLE;
};

void() CSQC_SnarkDropClear =
{ self.ammo_snark = 0; };

void() CSQC_SnarkEquip =
{
    self.weapon_name         = SNARK_DISPLAY_NAME;
    self.weapon_viewmodel    = SNARK_VIEWMODEL;
    self.weapon_worldmodel   = SNARK_WORLDMODEL;
    self.weapon_deploy_sound = SNARK_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSnarkCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_SnarkDisplayFrame;
    self.csqc_drop_clear     = CSQC_SnarkDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
