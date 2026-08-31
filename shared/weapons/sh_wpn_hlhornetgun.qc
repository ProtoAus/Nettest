// ============================================================
//  shared/weapons/sh_wpn_hlhornetgun.qc  -  HL Hornet Gun (hivehand)
//
//  Slot  : SLOT_PRIMARY
//  Stats : ammo_hornet, max 8 (HORNET_MAX_CARRY, weapons.h:120).  There is no
//          reload: the hive grows its own ammo back, one hornet at a time.
//  Fire  : +attack  — a slow hornet that hunts whatever it can see.
//          +attack2 — a fast dart that flies straight, from one of eight
//                     muzzle positions in rotation.
//
//  Ported from the SDK: dlls/hornetgun.cpp and dlls/hornet.cpp.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

.float hgun_recharge_time;   // when the hive grows the next one back
.float hgun_fire_phase;      // 1..8, which of the eight muzzles the dart leaves from
.float hgun_alt_finished;    // secondary's own debounce (attack_finished is the primary's)

// --- Sequence indices, read out of v_hgun.mdl (6 sequences) --------------
const float HGUN_SEQ_IDLE         = 0;   // idle1,       1.875 s, looping
const float HGUN_SEQ_FIDGETSWAY   = 1;   // fidgetSway,  2.500 s
const float HGUN_SEQ_FIDGETSHAKE  = 2;   // fidgetShake, 2.188 s
const float HGUN_SEQ_DOWN         = 3;   // down,        1.125 s
const float HGUN_SEQ_UP           = 4;   // up,          1.000 s
const float HGUN_SEQ_SHOOT        = 5;   // Shoot,       0.417 s

const float HGUN_FRAME_INTERVAL   = 0.05;
const float HGUN_DRAW_DURATION    = 1.0;    // the "up" sequence's own length
const float HGUN_FIRE_DURATION    = 0.417;  // the "Shoot" sequence's own length

const float MAX_AMMO_HORNET       = 8;      // HORNET_MAX_CARRY, weapons.h:120

// --- Balance -------------------------------------------------------------
// sk_hornet_dmg = 5 on medium (valve/skill.cfg).
const float HORNET_DAMAGE         = 5;
const float HGUN_PRIMARY_DELAY    = 0.25;   // hornetgun.cpp:141
const float HGUN_SECONDARY_DELAY  = 0.1;    // hornetgun.cpp:220
const float HORNET_TRACK_SPEED    = 300;    // hornetgun.cpp:125
const float HORNET_DART_SPEED     = 1200;   // hornetgun.cpp:201
const float HORNET_RED_SPEED      = 600;    // hornet.h:24
const float HORNET_ORANGE_SPEED   = 800;    // hornet.h:25
const float HORNET_LIFETIME_SP    = 5.0;    // hornet.cpp:63
const float HORNET_LIFETIME_MP    = 3.5;    // hornet.cpp:59
const float HORNET_SIGHT_RANGE    = 512;    // hornet.cpp:216 Look(512)

const string HGUN_VIEWMODEL       = "models/v_hgun.mdl";
const string HGUN_WORLDMODEL      = "models/w_hgun.mdl";
const string HORNET_MODEL         = "models/hornet.mdl";
const string HGUN_DEPLOY_SOUND    = "";
const string HGUN_DISPLAY_NAME    = "HORNETGUN";

// hornetgun.cpp:8 — the hive regrows a hornet every 0.3 s in multiplayer and
// every 0.5 s otherwise.  Both numbers are kept because this mod runs HL's
// single-player campaign maps on a multiplayer engine, and the faster rate
// would quietly rebalance them.
float() HGun_RechargeTime =
{
#ifdef CSQC
    if (maxclients > 1) return 0.3;
#else
    // maxclients is a CSQC-only global in this tree's defs; on the server the
    // same number is the cvar.
    if (cvar("maxclients") > 1) return 0.3;
#endif
    return 0.5;
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_HGunTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= HGUN_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= HGUN_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// hornetgun.cpp:229 Reload — not a reload at all, a regrow.  It is called at
// the top of BOTH attacks and from the idle, so the hive is always catching up
// whether or not you are shooting.
void(float now) SH_HGunRegrow =
{
    if (self.ammo_hornet >= MAX_AMMO_HORNET)
        return;
    if (self.hgun_recharge_time <= 0)
    { self.hgun_recharge_time = now + HGun_RechargeTime(); return; }

    while (self.ammo_hornet < MAX_AMMO_HORNET && self.hgun_recharge_time < now)
    {
        self.ammo_hornet   += 1;
        self.hgun_recharge_time += HGun_RechargeTime();
    }
};

float(float now) SH_HGunTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE && self.weaponstate != WS_FIRE) return 0;
    if (now < self.attack_finished) return 0;

    SH_HGunRegrow(now);
    if (self.ammo_hornet <= 0) return 0;

    self.ammo_hornet    -= 1;
    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + HGUN_PRIMARY_DELAY;
    // hornetgun.cpp:145 — emptying the hive costs an extra recharge period
    // before you may pull the trigger again.
    if (self.ammo_hornet <= 0)
        self.attack_finished += HGun_RechargeTime();
    self.hgun_recharge_time = now + HGun_RechargeTime();
    return 1;
};

float(float now) SH_HGunTryAltFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE && self.weaponstate != WS_FIRE) return 0;
    if (now < self.hgun_alt_finished) return 0;

    SH_HGunRegrow(now);
    if (self.ammo_hornet <= 0) return 0;

    self.ammo_hornet    -= 1;
    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished   = now + HGUN_SECONDARY_DELAY;
    self.hgun_alt_finished = now + HGUN_SECONDARY_DELAY;
    if (self.ammo_hornet <= 0)
    {
        self.attack_finished   += 0.5;    // hornetgun.cpp:225
        self.hgun_alt_finished += 0.5;
    }
    self.hgun_recharge_time = now + HGun_RechargeTime();
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Trail handles.  These are now a PRECACHE ONLY — nothing reads them, because the
// ribbon is drawn client-side (see the long note in W_HGunSpawnHornet).
//
// The calls are kept deliberately rather than deleted: on the server
// particleeffectnum IS SV_ParticlePrecache_Add, so this is what puts the two names
// into the precache list that ships to each client, and the client's own
// particleeffectnum in cl_throwtrail.qc resolves the same names locally.  Delete
// these and the names stop being reserved server-side.
float pe_hornet_trail_red;
float pe_hornet_trail_orange;

void() Hornet_PrecacheTrails =
{
    pe_hornet_trail_red    = particleeffectnum("weapons.hornet_trail_red");
    pe_hornet_trail_orange = particleeffectnum("weapons.hornet_trail_orange");
};

// hornetgun.cpp:53 — every hivehand is picked up full in multiplayer, and it
// regrows its own ammo anyway, so the larger of the two is the right answer.
void(entity player) W_HGunPickupCopy =
{ if (self.ammo_hornet > player.ammo_hornet) player.ammo_hornet = self.ammo_hornet; };

.float hornet_stop_attack;
.float hornet_born;          // spawn time, for the lifetime report
.float hornet_flyspeed;
.entity hornet_enemy;
.vector hornet_lkp;         // last known position, hornet.cpp:m_vecEnemyLKP

void() W_HornetDieTouch;
void() W_HornetTrackTouch;

float() Hornet_Lifetime =
{
    if (cvar("maxclients") > 1) return HORNET_LIFETIME_MP;
    return HORNET_LIFETIME_SP;
};

void() W_HornetRemove = { remove(self); };

void() W_HornetDieTouch =
{
    if (other == self.owner)
        return;

    // hornet.cpp:369 — a hornet NEVER dies on another hornet, and it goes
    // SOLID_NOT rather than just returning, so the pair stop colliding for
    // good instead of re-touching every frame.  Missing this made the primary
    // and secondary shots annihilate each other 0 s after leaving the muzzle:
    // measured as [hornet] died on "hornet" after 0 s.
    if (other.classname == "hornet")
    {
        self.solid = SOLID_NOT;
        return;
    }

    // "the hornets are gone by the time I look" has two completely different
    // causes - they expired normally, or they hit a wall 16 units from the
    // muzzle - and only the thing they touched separates them.
    if (cvar("sv_hlequip_test"))
        dprint(sprintf("[hornet] died on \"%s\" after %g s\n",
                       other.classname, time - self.hornet_born));

    // Players sit at DAMAGE_NO in this mod and are accepted inside
    // W_CanDamageTarget instead — see the same note in sh_wpn_hlsnark.qc.
    if (other && (other.takedamage || other.classname == "player"))
    {
        float r = random();
        string s;
        if      (r < 0.333) s = "hornet/ag_hornethit1.wav";
        else if (r < 0.666) s = "hornet/ag_hornethit2.wav";
        else                s = "hornet/ag_hornethit3.wav";
        sound(self, CHAN_VOICE, s, 1, ATTN_NORM);
        W_ApplyDamage(self.owner ? self.owner : self, other, HORNET_DAMAGE);
    }
    remove(self);
};

// hornet.cpp:367 TrackTouch.  A tracking hornet that hits something it has no
// quarrel with turns around and carries on rather than dying - which is why one
// can chase you round a corner instead of splashing on the wall you ducked
// behind.  Only the fast dart dies on contact with anything.
void() W_HornetTrackTouch =
{
    if (other == self.owner || other.classname == "hornet")
    {
        self.solid = SOLID_NOT;
        return;
    }

    if (!other || (!other.takedamage && other.classname != "player"))
    {
        // Reverse and nudge clear, hornet.cpp:378-386.
        vector d = normalize(self.velocity);
        d_x = 0 - d_x;
        d_y = 0 - d_y;
        setorigin(self, self.origin + d * 4);
        self.velocity = d * self.hornet_flyspeed;
        return;
    }

    W_HornetDieTouch();
};

// hornet.cpp:203 TrackTarget.  A tracking hornet is not a homing missile: it
// turns at a rate that falls off with how wide the turn is, which is why one
// can be outrun in a straight line but never in a corridor.
void() W_HornetTrackThink =
{
    self.nextthink = time + 0.1;

    if (time > self.hornet_stop_attack)
    { self.touch = __NULL__; remove(self); return; }

    // The buzz.  hornet.cpp:295-297 and :352-354 re-emit it on CHAN_VOICE on
    // EVERY TrackTarget tick — it is how a hornet is findable by ear rather
    // than only by eye, and this tree played nothing after the single agrunt
    // fire sample at spawn.  This think IS the analogue of TrackTarget (same
    // 0.1 s cadence), so the cue belongs here.  CHAN_VOICE per HL, so it does
    // not fight the weapon channel.
    float rb = random();
    if (rb < 0.333)      sound(self, CHAN_VOICE, "hornet/ag_buzz1.wav", 1, ATTN_NORM);
    else if (rb < 0.666) sound(self, CHAN_VOICE, "hornet/ag_buzz2.wav", 1, ATTN_NORM);
    else                 sound(self, CHAN_VOICE, "hornet/ag_buzz3.wav", 1, ATTN_NORM);

    if (!self.hornet_enemy || self.hornet_enemy.health <= 0)
    {
        entity best = world;
        float bestd = HORNET_SIGHT_RANGE;
        entity e = findradius(self.origin, HORNET_SIGHT_RANGE);
        while (e)
        {
            if (e != self && e != self.owner && e.health > 0
                && e.classname != "hornet"
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
        self.hornet_enemy = best;
    }

    if (self.hornet_enemy)
    {
        traceline(self.origin, self.hornet_enemy.origin + self.hornet_enemy.view_ofs, TRUE, self);
        if (trace_fraction == 1 || trace_ent == self.hornet_enemy)
            self.hornet_lkp = self.hornet_enemy.origin + self.hornet_enemy.view_ofs;
    }

    if (self.hornet_lkp == '0 0 0')
        return;                             // never seen anything; keep coasting

    vector dirto = normalize(self.hornet_lkp - self.origin);
    vector flight = (vlen(self.velocity) < 0.1) ? dirto : normalize(self.velocity);

    // hornet.cpp:243 — the wider the turn the slower it goes this tick.
    float delta = flight * dirto;
    if (delta < 0.5) delta = 0.5;

    self.velocity = normalize(flight + dirto * 0.3) * self.hornet_flyspeed * delta;
    self.angles   = vectoangles(self.velocity);
};

// hornet.cpp:150 StartDart — no tracking at all, and it dies on its own after
// four seconds rather than hunting for five.
void() W_HornetDartThink =
{
    self.touch = W_HornetDieTouch;
    self.think = W_HornetRemove;
    self.nextthink = time + 4;
};

entity(entity shooter, vector org, vector dir, float tracking) W_HornetSpawn =
{
    entity h = spawn();
    h.owner     = shooter;
    h.classname = "hornet";
    h.movetype  = MOVETYPE_FLY;
    h.solid     = SOLID_BBOX;
    setmodel(h, HORNET_MODEL);
    setsize(h, '-4 -4 -4', '4 4 4');        // hornet.cpp:80
    setorigin(h, org);
    h.takedamage = DAMAGE_YES;
    h.health     = 1;                       // hornet.cpp:57 — "weak!"
    h.on_killed  = W_HornetRemove;

    // NO EF_DIMLIGHT.  In FTE that flag is not model shading — it attaches a
    // 200-unit DYNAMIC LIGHT coloured by r_dimlight_colour, whose default is
    // "2.0 1.0 0.5", i.e. a 2x-overbright orange.  One per hornet, and a held
    // alt-fire sprays eight of them, so a burst floodlit the whole corridor.
    // That is the reported "hornets are WAY too bright".
    //
    // CHornet::Spawn (hornet.cpp:60-110) sets no effects, no rendermode and no
    // light at all — in Half-Life the glow comes ENTIRELY from the trail below,
    // which this weapon was never drawing.
    //
    // hornet.cpp:69 — two in five are the slow red kind.
    if (random() <= 0.4) h.hornet_flyspeed = HORNET_RED_SPEED;
    else                 h.hornet_flyspeed = HORNET_ORANGE_SPEED;

    // The trail, in place of HL's TE_BEAMFOLLOW (which FTE does not implement).
    // .traileffectnum genuinely works HERE, unlike on the mod's other projectiles:
    // a hornet has no SendEntity, so it is a real delta-replicated packet entity
    // and CL_LinkPacketEntities walks the trail for it (cl_ents.c:5601).
    //
    // The handles MUST come from Hornet_PrecacheTrails, resolved at map load, not
    // from a particleeffectnum() call here.  On the server that builtin is
    // SV_ParticlePrecache_Add, and the precache list is sent to a client when it
    // CONNECTS -- registering a new entry at first-shot time means an
    // already-connected client has no name for the index it is handed, and draws
    // nothing.  Resolving both at precache time is what makes the trail appear
    // for the player who is already in the map, which is every player.
    // NO .traileffectnum.  The trail is drawn CLIENT-side now, by
    // ThrowTrail_ScanHornets in client/cl_throwtrail.qc.
    //
    // This weapon really does satisfy every documented precondition for
    // .traileffectnum — it is a genuine packet entity, and the handles really are
    // resolved at precache time as the note above insists.  It still never drew,
    // and the reason is a step neither side can reach: the client turns the
    // server's particle NAME into a local index exactly once, at PRESPAWN, and
    // P_FindParticleType returns P_INVALID for any name whose config is not
    // loaded at that instant — it triggers the load as a side effect and then
    // returns the failure without re-searching.  The connect-time particle flush
    // is what makes that true, so the slot is poisoned for the whole session.
    // That happens before CSQC_Init, so no QC hook exists to repair it.
    //
    // Assigning it anyway would be worse than useless once the CSQC path works:
    // on any client where the name DID happen to resolve, both would draw and the
    // hornet would carry a doubled ribbon.  One owner.
    //
    // .hornet_flyspeed above stays as it is: it still picks the flight speed, and
    // that speed is precisely what the client measures to choose red vs orange,
    // so the colour distinction survives without being networked.

    h.hornet_stop_attack = time + Hornet_Lifetime();
    h.hornet_born        = time;

    if (tracking)
    {
        h.velocity  = dir * HORNET_TRACK_SPEED;
        h.think     = W_HornetTrackThink;
        h.touch     = W_HornetTrackTouch;   // bounces off scenery, hornet.cpp:376
        h.nextthink = time + 0.1;
    }
    else
    {
        h.velocity  = dir * HORNET_DART_SPEED;
        h.think     = W_HornetDartThink;
        h.touch     = W_HornetDieTouch;     // a dart dies on everything, hornet.cpp:393
        h.nextthink = time + 0.01;
    }
    h.angles = vectoangles(h.velocity);

    float r = random();
    string s;
    if      (r < 0.333) s = "agrunt/ag_fire1.wav";
    else if (r < 0.666) s = "agrunt/ag_fire2.wav";
    else                s = "agrunt/ag_fire3.wav";
    sound(h, CHAN_WEAPON, s, 1, ATTN_NORM);
    return h;
};

// hornetgun.cpp:123 / :195 — both attacks leave from the same place, 16
// forward, 8 right and 12 down from the eye.
vector() HGun_MuzzleOrigin =
{
    return self.origin + self.view_ofs + v_forward * 16 + v_right * 8 + v_up * -12;
};

void() W_HGunFire =
{
    if (!SH_HGunTryFire(time)) return;

    self.weaponframe   = HGUN_SEQ_SHOOT;
    // MUST schedule, not clear -- sv_weapons.qc only calls wepframe while
    // wep_nextframe > 0, so a 0 here retires the frame function permanently and
    // weaponstate never leaves WS_FIRE (this weapon's try-fire accepts WS_FIRE, so
    // it kept shooting and the freeze went unnoticed -- but the idle animation and
    // every per-tick behaviour behind the frame function stopped).  Clear it only
    // on the idle-retire, the way the *Frame functions below do.
    self.wep_nextframe = time + HGUN_FRAME_INTERVAL;

    makevectors(self.v_angle);
    W_HornetSpawn(self, HGun_MuzzleOrigin(), v_forward, TRUE);
};

void() W_HGunAltFire =
{
    if (!SH_HGunTryAltFire(time)) return;

    self.weaponframe   = HGUN_SEQ_SHOOT;
    // MUST schedule, not clear -- sv_weapons.qc only calls wepframe while
    // wep_nextframe > 0, so a 0 here retires the frame function permanently and
    // weaponstate never leaves WS_FIRE (this weapon's try-fire accepts WS_FIRE, so
    // it kept shooting and the freeze went unnoticed -- but the idle animation and
    // every per-tick behaviour behind the frame function stopped).  Clear it only
    // on the idle-retire, the way the *Frame functions below do.
    self.wep_nextframe = time + HGUN_FRAME_INTERVAL;

    makevectors(self.v_angle);
    vector src = HGun_MuzzleOrigin();

    // hornetgun.cpp:200 — eight muzzle positions walked in a circle, so a
    // held-down secondary sprays a ring rather than a line.
    self.hgun_fire_phase = self.hgun_fire_phase + 1;
    if (self.hgun_fire_phase > 8) self.hgun_fire_phase = 1;
    float p = self.hgun_fire_phase;
    if      (p == 1) src = src + v_up * 8;
    else if (p == 2) src = src + v_up * 8 + v_right * 8;
    else if (p == 3) src = src + v_right * 8;
    else if (p == 4) src = src + v_up * -8 + v_right * 8;
    else if (p == 5) src = src + v_up * -8;
    else if (p == 6) src = src + v_up * -8 + v_right * -8;
    else if (p == 7) src = src + v_right * -8;
    else             src = src + v_up * 8 + v_right * -8;

    W_HornetSpawn(self, src, v_forward, FALSE);
};

void() W_HGunFrame =
{
    SH_HGunRegrow(time);

    float result = SH_HGunTickState(time);
    if (result & 1)
    {
        self.weaponframe   = HGUN_SEQ_IDLE;
        self.wep_nextframe = 0;
    }
};

void() W_HGunEquip =
{
    W_StandardEquipSetup(HGUN_VIEWMODEL, HGUN_DISPLAY_NAME, HGUN_SEQ_UP,
        HGUN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_HGunFire;
    self.altfire  = W_HGunAltFire;
    self.reload   = __NULL__;
    self.wepframe = W_HGunFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    // hornetgun.cpp:110 — an empty hive can never be refilled from the world,
    // so holstering it hands back one hornet rather than stranding the weapon.
    if (self.ammo_hornet <= 0)
        self.ammo_hornet = 1;
    W_SetCrosshairProfile(0, 0, 320, 1.2, TRUE);
};

void() W_HGunDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_hornet = self.ammo_hornet;
    self.ammo_hornet = 0;

    setmodel(tgt, HGUN_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 32');
    tgt.classname    = "weapon_hornetgun";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HORNETGUN;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_HGunEquip;
    tgt.weap_drop_func = W_HGunDrop;
    tgt.pickupcopy   = W_HGunPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hornetgun =
{
    setmodel(self, HGUN_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 32');
    self.classname     = "weapon_hornetgun";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HORNETGUN;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_HGunEquip;
    self.weap_drop_func = W_HGunDrop;
    self.pickupcopy    = W_HGunPickupCopy;
    self.touch         = weapon_touch;
    // hornetgun.cpp:53 — in multiplayer every hivehand is picked up full.
    self.ammo_hornet   = MAX_AMMO_HORNET;
    W_RegisterMapWeapon(weapon_hornetgun);
};
void() spawnfunc_weapon_hornetgun = { weapon_hornetgun(); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictHGunCommand =
{
    // The regrow runs whether or not the trigger is touched, so the ammo
    // counter climbs on the client at the same rate the server climbs it
    // rather than stepping up a ping late.
    SH_HGunRegrow(csqc_pred_time);

    if (input_buttons & 1)
    {
        if (SH_HGunTryFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }
    // Bit 4 is +attack2; bit 2 is PM_BTN_JUMP (sh_pmove.qc:42).  Same
    // wrong-bit defect the satchel had - the alt fire predicted on jump and
    // not on the key that actually fires it.
    else if (input_buttons & 4)
    {
        if (SH_HGunTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    SH_HGunTickState(csqc_pred_time);
};

float(float elapsed) CSQC_HGunDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return HGUN_SEQ_UP;
    if (predicted_player.weaponstate == WS_FIRE)
        return HGUN_SEQ_SHOOT;
    return HGUN_SEQ_IDLE;
};

void() CSQC_HGunDropClear =
{ self.ammo_hornet = 0; };

void() CSQC_HGunEquip =
{
    self.weapon_name         = HGUN_DISPLAY_NAME;
    self.weapon_viewmodel    = HGUN_VIEWMODEL;
    self.weapon_worldmodel   = HGUN_WORLDMODEL;
    self.weapon_deploy_sound = HGUN_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictHGunCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_HGunDisplayFrame;
    self.csqc_drop_clear     = CSQC_HGunDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
