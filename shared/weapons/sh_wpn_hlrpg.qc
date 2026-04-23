// ============================================================
//  shared/weapons/sh_wpn_hlrpg.qc  -  HL RPG (Laser-Guided Rocket Launcher)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 1-rocket magazine, 5 reserve
//  Fire  : spawns a guided rocket projectile (MOVETYPE_FLYMISSILE)
//         Explodes on contact, laser-guided when active
//  Alt   : Toggle laser guide — rocket homes toward aim point
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_hlrpg;
.float ammo_hlrpg;
.float rpg_laser_active;
.entity rpg_rocket;

// --- Animation frames ---
const float RPG_FRAME_INTERVAL        = 0.05;   // 1/20

const float RPG_DRAW_START            = 0;
const float RPG_DRAW_END              = 10;

const float RPG_FIRE_START            = 22;
const float RPG_FIRE_END              = 38;
const float RPG_FIRE_DELAY            = 1.5;

const float RPG_RELOAD_START          = 39;
const float RPG_RELOAD_END            = 79;
const float RPG_RELOAD_APPLY          = 79;

const float RPG_IDLE_FRAME            = 80;

const float MAX_MAG_HLRPG             = 1;
const float MAX_AMMO_HLRPG            = 5;

// --- Balance ---
const float RPG_EXPLOSION_DAMAGE      = 120;
const float RPG_EXPLOSION_RADIUS      = 300;
const float RPG_EXPLOSION_MIN_DAMAGE  = 20;
const float RPG_INITIAL_SPEED         = 250;
const float RPG_ACCEL_PER_THINK       = 20;   // speed added each 0.05s think
const float RPG_MAX_GUIDED_SPEED      = 1500;
const float RPG_DRYFIRE_DELAY         = 0.2;
const float RPG_KNOCKBACK_PUSH        = 800;
const float RPG_KNOCKBACK_UPLIFT      = 350;

// --- Pre-computed durations ---
const float RPG_DRAW_DURATION         = (RPG_DRAW_END - RPG_DRAW_START) * RPG_FRAME_INTERVAL;
const float RPG_FIRE_DURATION         = (RPG_FIRE_END - RPG_FIRE_START) * RPG_FRAME_INTERVAL;
const float RPG_RELOAD_DURATION       = (RPG_RELOAD_END - RPG_RELOAD_START) * RPG_FRAME_INTERVAL;
const float RPG_RELOAD_APPLY_TIME     = (RPG_RELOAD_APPLY - RPG_RELOAD_START) * RPG_FRAME_INTERVAL;

const string RPG_VIEWMODEL    = "models/weapons/wpn_hlrpg/v_rpg.mdl";
const string RPG_WORLDMODEL   = "models/weapons/wpn_hlrpg/w_rpg.mdl";
const string RPG_DEPLOY_SOUND = "";
const string RPG_DISPLAY_NAME = "RPG";

const string RPG_FIRE_SOUND   = "sounds/weapons/wpn_hlrpg/fire.wav";
const string RPG_FLY_SOUND    = "sounds/weapons/wpn_hlrpg/fly.wav";
const string RPG_ROCKET_MODEL = "models/weapons/wpn_hlrpg/rpgrocket.mdl";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_RPGTickState =
{
    return SH_StandardTickState(now, mag_hlrpg, ammo_hlrpg, MAX_MAG_HLRPG,
        RPG_DRAW_DURATION, RPG_FIRE_DURATION,
        RPG_RELOAD_DURATION, RPG_RELOAD_APPLY_TIME);
};

float(float now) SH_RPGTryFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    return SH_StandardTryFire(now, mag_hlrpg, RPG_FIRE_DELAY, RPG_DRYFIRE_DELAY);
};

float(float now) SH_RPGTryReload =
{
    return SH_StandardTryReload(now, mag_hlrpg, ammo_hlrpg, MAX_MAG_HLRPG, RPG_RELOAD_DURATION);
};

float(float now) SH_RPGTryAltFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.altfire_finished) return 0;

    self.rpg_laser_active = !self.rpg_laser_active;
    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_RPGPickupCopy =
{
    player.mag_hlrpg  = self.mag_hlrpg;
    player.ammo_hlrpg = self.ammo_hlrpg;
};

// Rocket explosion — radius damage
void() W_RPGExplode =
{
    float dist, damage;
    float saved_dim;
    entity e;

    // Exclude shooter from explosion effects — they see the client-predicted one
    saved_dim = dimension_send;
    if (self.owner)
        dimension_send = dimension_send & ~self.owner.dimension_seen;

    te_explosion(self.origin + '0 0 8');

    dimension_send = saved_dim;

    // Radius damage + push-back
    e = findradius(self.origin, RPG_EXPLOSION_RADIUS);
    while (e)
    {
        if (W_CanDamageTarget(e))
        {
            dist = vlen(e.origin - self.origin);
            damage = W_LinearDamageFalloff(dist, RPG_EXPLOSION_DAMAGE, RPG_EXPLOSION_MIN_DAMAGE, RPG_EXPLOSION_RADIUS);
            W_ApplyDamage(self.owner, e, damage);
        }

        // Push players away from explosion
        if (e.classname == "player" && e.health > 0)
        {
            dist = vlen(e.origin - self.origin);
            float push_scale = 1 - (dist / RPG_EXPLOSION_RADIUS);
            push_scale = max(0, push_scale);
            vector push_dir = normalize(e.origin - self.origin);
            e.velocity += push_dir * RPG_KNOCKBACK_PUSH * push_scale;
            e.velocity_z += RPG_KNOCKBACK_UPLIFT * push_scale;
        }

        e = e.chain;
    }

    // Stop fly sound on the same clients that received it — skip shooter,
    // whose CSQC fake rocket will stop its own local fly sound on explode.
    entity fc = player_chain_head;
    while (fc)
    {
        if (fc != self.owner)
        {
            msg_entity = fc;
            sound(self, CHAN_VOICE, "sounds/null.wav", 0, ATTN_NORM, 0,
                  SOUNDFLAG_UNICAST);
        }
        fc = fc.player_chain_next;
    }

    // Clear owner's rocket reference
    if (self.owner)
        self.owner.rpg_rocket = world;

    remove(self);
};

void() W_RPGRocketTouch =
{
    if (other == self.owner)
        return;   // don't explode on shooter
    W_RPGExplode();
};

void() W_RPGRocketThink =
{
    float spd = vlen(self.velocity);
    vector dir = normalize(self.velocity);

    // Laser guidance: home toward owner's aim point
    if (self.owner && self.owner.rpg_laser_active)
    {
        makevectors(self.owner.v_angle);
        vector src = self.owner.origin + self.owner.view_ofs;
        traceline(src, src + v_forward * 8192, MOVE_NORMAL, self.owner);
        dir = normalize(trace_endpos - self.origin);
    }

    // Always accelerate toward max speed (aggressive ramp-up)
    spd = spd + RPG_ACCEL_PER_THINK;
    if (spd > RPG_MAX_GUIDED_SPEED)
        spd = RPG_MAX_GUIDED_SPEED;
    self.velocity = dir * spd;
    self.angles = vectoangles(self.velocity);

    self.nextthink = time + 0.05;
};

void() W_RPGFire =
{
    float r;
    entity rocket;

    r = SH_RPGTryFire(time);
    if (r == 1)
    {
        self.weaponframe = RPG_FIRE_START;
        self.wep_nextframe = time + RPG_FRAME_INTERVAL;

        // Spawn rocket projectile
        makevectors(self.v_angle);
        rocket = spawn();
        rocket.owner = self;
        rocket.classname = "proj_rpg_rocket";
        rocket.movetype = MOVETYPE_FLYMISSILE;
        rocket.solid = SOLID_BBOX;
        setmodel(rocket, RPG_ROCKET_MODEL);
        setsize(rocket, '-2 -2 -2', '2 2 2');
        setorigin(rocket, self.origin + self.view_ofs + v_forward * 16);
        rocket.velocity = v_forward * RPG_INITIAL_SPEED;
        rocket.angles = vectoangles(rocket.velocity);
        rocket.touch = W_RPGRocketTouch;
        rocket.think = W_RPGRocketThink;
        rocket.nextthink = time + 0.05;
        rocket.nodrawtoclient = self;   // shooter sees client-predicted rocket instead

        // Looping fly sound attached to the rocket, unicast to everyone
        // except the shooter.  SOUNDFLAG_FOLLOW makes the engine update the
        // channel's origin to the rocket's position each frame, but only
        // when the client is receiving entity updates for it — the shooter's
        // nodrawtoclient suppresses the rocket entirely, so their client
        // would fall back to the spawn origin and stay stuck there.  Their
        // CSQC fake rocket plays an equivalent local sound instead.
        entity c = player_chain_head;
        while (c)
        {
            if (c != self)
            {
                msg_entity = c;
                sound(rocket, CHAN_VOICE, RPG_FLY_SOUND, 1, ATTN_NORM, 0,
                      SOUNDFLAG_FOLLOW | SOUNDFLAG_UNICAST);
            }
            c = c.player_chain_next;
        }

        // Track active rocket
        self.rpg_rocket = rocket;

        sound(self, CHAN_WEAPON, RPG_FIRE_SOUND, 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_RPGAltFire =
{
    SH_RPGTryAltFire(time);
};

void() W_RPGReload =
{
    if (SH_RPGTryReload(time))
    {
        self.weaponframe   = RPG_RELOAD_START;
        self.wep_nextframe = time + RPG_FRAME_INTERVAL;
    }
};

void() W_RPGFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += RPG_FRAME_INTERVAL;

    result = SH_RPGTickState(time);
    if (result & 1)
    {
        self.weaponframe   = RPG_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_RPGEquip =
{
    W_StandardEquipSetup(RPG_VIEWMODEL, RPG_DISPLAY_NAME, RPG_DRAW_START,
        RPG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_RPGFire;
    self.reload   = W_RPGReload;
    self.wepframe = W_RPGFrame;
    self.altfire  = W_RPGAltFire;
    self.rpg_laser_active = 0;
    self.rpg_rocket = world;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_RPGDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_hlrpg  = self.mag_hlrpg;
    tgt.ammo_hlrpg = self.ammo_hlrpg;

    self.mag_hlrpg  = 0;
    self.ammo_hlrpg = 0;
    self.rpg_laser_active = 0;
    self.rpg_rocket = world;

    setmodel(tgt, RPG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_hlrpg";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLRPG;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_RPGEquip;
    tgt.weap_drop_func = W_RPGDrop;
    tgt.pickupcopy   = W_RPGPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlrpg =
{
    setmodel(self, RPG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_hlrpg";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLRPG;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_RPGEquip;
    self.weap_drop_func = W_RPGDrop;
    self.pickupcopy    = W_RPGPickupCopy;
    self.touch         = weapon_touch;
    self.mag_hlrpg     = MAX_MAG_HLRPG;
    self.ammo_hlrpg    = MAX_AMMO_HLRPG;
    W_RegisterMapWeapon(weapon_hlrpg);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_FakeRPGRocketExplode =
{
    // Stop the looping fly sound attached to this CSQC-local ent before
    // the entity vanishes — otherwise CF_FOLLOW leaves it playing forever
    // at the last-known origin.
    sound(self, CHAN_VOICE, "sounds/null.wav", 0, ATTN_NORM);
    pointsound(self.origin, "sounds/weapons/explode1.wav", 1, ATTN_NORM);
    te_explosion(self.origin + '0 0 8');
    remove(self);
};

// Accelerate fake rocket to match server behavior
void() CSQC_FakeRPGRocketThink =
{
    float spd = vlen(self.velocity);
    vector dir = normalize(self.velocity);
    spd = spd + RPG_ACCEL_PER_THINK;
    if (spd > RPG_MAX_GUIDED_SPEED)
        spd = RPG_MAX_GUIDED_SPEED;
    self.velocity = dir * spd;
    self.angles = vectoangles(self.velocity);
    self.nextthink = time + 0.05;
};

void() CSQC_FakeRPGRocketTouch =
{
    if (other == self.owner)
        return;
    CSQC_FakeRPGRocketExplode();
};

void() CSQC_PredictRPGCommand =
{
    float r;

    // Alt-fire: toggle laser guide
    if (input_buttons & 4)
    {
        if (SH_RPGTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_RPGTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, RPG_FIRE_SOUND, 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();

                // Spawn fake rocket projectile for instant visual
                {
                    entity rocket = spawn();
                    makevectors(input_angles);
                    setmodel(rocket, RPG_ROCKET_MODEL);
                    setsize(rocket, '-2 -2 -2', '2 2 2');
                    setorigin(rocket, self.origin + self.view_ofs + v_forward * 16);
                    rocket.owner = self;
                    rocket.velocity = v_forward * RPG_INITIAL_SPEED;
                    rocket.angles = vectoangles(rocket.velocity);
                    rocket.movetype = MOVETYPE_FLYMISSILE;
                    rocket.solid = SOLID_BBOX;
                    rocket.drawmask = MASK_ENGINE;
                    rocket.touch = CSQC_FakeRPGRocketTouch;
                    rocket.think = CSQC_FakeRPGRocketThink;
                    rocket.nextthink = time + 0.05;

                    // Local looping fly sound that follows the shooter's
                    // predicted rocket — the server-side sound is unicast-
                    // skipped for this client so there's no double audio.
                    sound(rocket, CHAN_VOICE, RPG_FLY_SOUND, 1, ATTN_NORM, 0,
                          SOUNDFLAG_FOLLOW);
                }
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    SH_RPGTickState(csqc_pred_time);
};

void() CSQC_PredictRPGReload =
{
    if (SH_RPGTryReload(csqc_pred_time))
        CSQC_MarkPendingWeaponAck();
};

float(float elapsed) CSQC_RPGDisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, RPG_FRAME_INTERVAL,
        RPG_DRAW_START, RPG_DRAW_END,
        RPG_FIRE_START, RPG_FIRE_END,
        RPG_RELOAD_START, RPG_RELOAD_END,
        RPG_IDLE_FRAME);
};

void() CSQC_RPGDropClear =
{
	self.mag_hlrpg = 0;
	self.ammo_hlrpg = 0;
	self.rpg_laser_active = 0;
};

void() CSQC_RPGEquip =
{
	self.weapon_name         = RPG_DISPLAY_NAME;
	self.weapon_viewmodel    = RPG_VIEWMODEL;
	self.weapon_worldmodel   = RPG_WORLDMODEL;
	self.weapon_deploy_sound = RPG_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictRPGCommand;
	self.csqc_predict_reload = CSQC_PredictRPGReload;
	self.csqc_display_frame  = CSQC_RPGDisplayFrame;
	self.csqc_drop_clear     = CSQC_RPGDropClear;
};

#endif // CSQC
