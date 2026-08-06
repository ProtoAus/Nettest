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
float(float now) SH_SatchelTryThrow =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.satchel_state == SATCHEL_STATE_SPENT) return 0;

    if (self.ammo_satchel <= 0)
    { self.attack_finished = now + SATCHEL_DRYFIRE_DELAY; return -1; }

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
    self.velocity  = self.velocity  * 0.95; // satchel.cpp:110
    self.avelocity = self.avelocity * 0.9;  // satchel.cpp:111

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
    setsize(c, '-4 -4 -4', '4 4 4');        // satchel.cpp:76 — point-sized, steppable
    setorigin(c, org);
    c.velocity    = vel;
    c.avelocity_y = SATCHEL_THROW_AVELOCITY_Y;
    c.gravity     = SATCHEL_GRAVITY;
    c.friction    = SATCHEL_FRICTION;
    c.touch       = W_SatchelChargeTouch;
    c.think       = W_SatchelChargeThink;
    c.nextthink   = time + 0.1;
    return c;
};

// satchel.cpp:365 — every charge this player owns, anywhere on the map.  HL
// bounds the sweep to a 4096-unit sphere; that is an artefact of
// UTIL_FindEntityInSphere being the only search it had, not a design choice,
// so the sweep here is by classname over the whole map.
void(entity who) W_SatchelDetonateAll =
{
    entity c = findchain(classname, "monster_satchel");
    entity oldself = self;
    while (c)
    {
        entity nxt = c.chain;
        if (c.owner == who)
        {
            self = c;
            W_SatchelChargeExplode();
            self = oldself;
        }
        c = nxt;
    }
};

void() W_SatchelFire =
{
    float r = SH_SatchelTryThrow(time);
    if (r == 1)
    {
        makevectors(self.v_angle);
        vector src = self.origin + self.view_ofs + v_forward * 16;
        W_SatchelChargeSpawn(self, src, v_forward * SATCHEL_THROW_FORWARD + self.velocity);

        // The radio comes up the moment the charge leaves your hand
        // (satchel.cpp:409), not when the animation finishes.
        self.weaponmodel = SATCHEL_RADIO_VIEWMODEL;
        self.weaponframe = SATCHEL_RADIO_SEQ_DRAW;
        self.wep_nextframe = 0;
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_SatchelAltFire =
{
    if (!SH_SatchelTryDetonate(time)) return;

    self.weaponframe   = SATCHEL_RADIO_SEQ_FIRE;
    self.wep_nextframe = 0;
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
        if (r == 1)
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

    if (input_buttons & 2)
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
};

#endif // CSQC
