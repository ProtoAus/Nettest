// ============================================================
//  shared/weapons/sh_wpn_hlgrenade.qc  -  HL Hand Grenade
//
//  Slot  : SLOT_UTILITY  (impulse 1 / key 1)
//  Stats : ammo_hlgrenade (no magazine, direct ammo pool, max 15)
//  Fire  : hold +attack to pull pin, release to throw grenade
//         Throw velocity scales with hold time (max 500)
//         Grenade explodes after 3s fuse (not on contact)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float ammo_hlgrenade;
.float hlgren_throw_vel;      // stored throw velocity (set on release, grenade spawns after delay)
.float hlgren_spawn_time;     // time when the grenade entity should actually spawn

// --- Animation frames ---
const float HLGREN_FRAME_INTERVAL         = 0.05;    // 1/20

const float HLGREN_DRAW_START             = 0;
const float HLGREN_DRAW_END               = 10;

const float HLGREN_PIN_START              = 11;
const float HLGREN_PIN_END                = 22;

const float HLGREN_THROW1_START           = 23;
const float HLGREN_THROW1_END             = 41;
const float HLGREN_THROW1_INTERVAL        = 0.077;   // ~13fps — low velocity

const float HLGREN_THROW2_START           = 42;
const float HLGREN_THROW2_END             = 60;
const float HLGREN_THROW2_INTERVAL        = 0.05;    // 20fps — medium velocity

const float HLGREN_THROW3_START           = 61;
const float HLGREN_THROW3_END             = 79;
const float HLGREN_THROW3_INTERVAL        = 0.033;   // ~30fps — high velocity

const float HLGREN_IDLE_FRAME             = 80;

const float MAX_AMMO_HLGRENADE            = 5;

// --- Balance ---
const float HLGREN_EXPLOSION_DAMAGE       = 100;
const float HLGREN_EXPLOSION_RADIUS       = 250;
const float HLGREN_EXPLOSION_MIN_DAMAGE   = 10;
const float HLGREN_FUSE_TIME              = 3.0;
const float HLGREN_MAX_THROW_SPEED        = 800;
const float HLGREN_THROW_CHARGE_RATE      = 400;   // velocity per second of hold
const float HLGREN_DRYFIRE_DELAY          = 0.2;
const float HLGREN_THROW_DELAY           = 0.1;  // delay after release before grenade spawns
const float HLGREN_KNOCKBACK_PUSH         = 800;
const float HLGREN_KNOCKBACK_UPLIFT       = 350;

// --- Pre-computed durations ---
const float HLGREN_DRAW_DURATION          = (HLGREN_DRAW_END - HLGREN_DRAW_START) * HLGREN_FRAME_INTERVAL;
const float HLGREN_PIN_DURATION           = (HLGREN_PIN_END - HLGREN_PIN_START) * HLGREN_FRAME_INTERVAL;
const float HLGREN_THROW1_DURATION        = (HLGREN_THROW1_END - HLGREN_THROW1_START) * HLGREN_THROW1_INTERVAL;
const float HLGREN_THROW2_DURATION        = (HLGREN_THROW2_END - HLGREN_THROW2_START) * HLGREN_THROW2_INTERVAL;
const float HLGREN_THROW3_DURATION        = (HLGREN_THROW3_END - HLGREN_THROW3_START) * HLGREN_THROW3_INTERVAL;

// Throw velocity thresholds for choosing animation
const float HLGREN_THROW1_MAX_VEL        = 166;    // ~0.83s hold
const float HLGREN_THROW2_MAX_VEL        = 333;    // ~1.66s hold

const string HLGREN_VIEWMODEL    = "models/weapons/wpn_hlgrenade/v_grenade.mdl";
const string HLGREN_WORLDMODEL   = "models/weapons/wpn_hlgrenade/w_grenade.mdl";
const string HLGREN_DEPLOY_SOUND = "";
const string HLGREN_DISPLAY_NAME = "GRENADE";

const string HLGREN_GRENADE_MODEL = "models/weapons/wpn_hlgrenade/w_grenade.mdl";

// ============================================================
//  SHARED — state machine (custom, not SH_SimpleTickState)
// ============================================================

// Returns: 1 = transitioned to idle, 0 = no change
float(float now) SH_HLGrenadeTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= HLGREN_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    // WS_SPECIAL (pin pull) doesn't auto-transition — ended by button release
    if (self.weaponstate == WS_SPECIAL)
        return 0;

    if (self.weaponstate == WS_FIRE)
    {
        // Determine throw duration based on throw velocity stored in attack_finished timing
        float throw_vel = min(HLGREN_MAX_THROW_SPEED, (self.wep_anim_start - self.altfire_finished) * HLGREN_THROW_CHARGE_RATE);
        float throw_dur;
        if (throw_vel <= HLGREN_THROW1_MAX_VEL)
            throw_dur = HLGREN_THROW1_DURATION;
        else if (throw_vel <= HLGREN_THROW2_MAX_VEL)
            throw_dur = HLGREN_THROW2_DURATION;
        else
            throw_dur = HLGREN_THROW3_DURATION;

        if (elapsed >= throw_dur)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// +attack pressed: pull pin (enter WS_SPECIAL)
// Returns: 1 = pin pulled, -1 = dry fire, 0 = blocked
float(float now) SH_HLGrenadeTryPinPull =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_hlgrenade <= 0)
    { self.attack_finished = now + HLGREN_DRYFIRE_DELAY; return -1; }

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    // Store pin pull start time in altfire_finished for throw velocity calculation
    self.altfire_finished = now;
    return 1;
};

// +attack released: throw grenade (enter WS_FIRE)
// Returns: throw velocity (>0), or 0 if not in pin-pull state
float(float now) SH_HLGrenadeThrow =
{
    float hold_time, throw_vel;

    if (self.weaponstate != WS_SPECIAL) return 0;

    hold_time = now - self.altfire_finished;
    throw_vel = max(200, min(HLGREN_MAX_THROW_SPEED, hold_time * HLGREN_THROW_CHARGE_RATE));

    self.ammo_hlgrenade  -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + 1.5;   // prevent re-pull while button held

    return throw_vel;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_HLGrenadePickupCopy =
{ player.ammo_hlgrenade = self.ammo_hlgrenade; };

// Hand grenade explosion — radius damage
void() W_HLGrenadeExplode =
{
    float dist, damage;
    entity e;

    // Explosion visual + sound
    te_explosion(self.origin + '0 0 8');
    float snd = random();
    if (snd < 0.333)
        sound(self, CHAN_VOICE, "sounds/weapons/wpn_hlgrenade/explode1.wav", 1, ATTN_NORM);
    else if (snd < 0.666)
        sound(self, CHAN_VOICE, "sounds/weapons/wpn_hlgrenade/explode2.wav", 1, ATTN_NORM);
    else
        sound(self, CHAN_VOICE, "sounds/weapons/wpn_hlgrenade/explode3.wav", 1, ATTN_NORM);

    // Radius damage + push-back
    e = findradius(self.origin, HLGREN_EXPLOSION_RADIUS);
    while (e)
    {
        if (W_CanDamageTarget(e))
        {
            dist = vlen(e.origin - self.origin);
            damage = W_LinearDamageFalloff(dist, HLGREN_EXPLOSION_DAMAGE, HLGREN_EXPLOSION_MIN_DAMAGE, HLGREN_EXPLOSION_RADIUS);
            W_ApplyDamage(self.owner, e, damage);
        }

        if (e.classname == "player" && e.health > 0)
        {
            dist = vlen(e.origin - self.origin);
            float push_scale = 1 - (dist / HLGREN_EXPLOSION_RADIUS);
            push_scale = max(0, push_scale);
            vector push_dir = normalize(e.origin - self.origin);
            e.velocity += push_dir * HLGREN_KNOCKBACK_PUSH * push_scale;
            e.velocity_z += HLGREN_KNOCKBACK_UPLIFT * push_scale;
        }

        e = e.chain;
    }

    remove(self);
};

void() W_HLGrenadeThink =
{
    W_HLGrenadeExplode();   // fuse expired
};

void() W_HLGrenadeBounce =
{
    // Bounce sound — only on world/bsp (not on players)
    if (other.classname != "player")
    {
        float snd = random();
        if (snd < 0.333)
            sound(self, CHAN_VOICE, "sounds/weapons/wpn_hlgrenade/hit1.wav", 1, ATTN_NORM);
        else if (snd < 0.666)
            sound(self, CHAN_VOICE, "sounds/weapons/wpn_hlgrenade/hit2.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_VOICE, "sounds/weapons/wpn_hlgrenade/hit3.wav", 1, ATTN_NORM);
    }
};

void() W_HLGrenadeFire =
{
    float r;

    r = SH_HLGrenadeTryPinPull(time);
    if (r == 1)
    {
        self.weaponframe = HLGREN_PIN_START;
        self.wep_nextframe = time + HLGREN_FRAME_INTERVAL;
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_HLGrenadeRelease =
{
    float throw_vel;
    entity gren;

    throw_vel = SH_HLGrenadeThrow(time);
    if (throw_vel <= 0) return;

    // Choose throw animation based on velocity
    if (throw_vel <= HLGREN_THROW1_MAX_VEL)
    {
        self.weaponframe = HLGREN_THROW1_START;
        self.wep_nextframe = time + HLGREN_THROW1_INTERVAL;
    }
    else if (throw_vel <= HLGREN_THROW2_MAX_VEL)
    {
        self.weaponframe = HLGREN_THROW2_START;
        self.wep_nextframe = time + HLGREN_THROW2_INTERVAL;
    }
    else
    {
        self.weaponframe = HLGREN_THROW3_START;
        self.wep_nextframe = time + HLGREN_THROW3_INTERVAL;
    }

    // Store throw velocity — grenade entity spawns after HLGREN_THROW_DELAY in W_HLGrenadeFrame
    self.hlgren_throw_vel = throw_vel;
    self.hlgren_spawn_time = time + HLGREN_THROW_DELAY;
};

void() W_HLGrenadeFrame =
{
    float result;

    if (self.weaponstate == WS_SPECIAL)
    {
        // Pin pull animation — advance frames, clamp at end but keep ticking
        self.weaponframe += 1;
        self.wep_nextframe += HLGREN_FRAME_INTERVAL;
        if (self.weaponframe >= HLGREN_PIN_END)
            self.weaponframe = HLGREN_PIN_END;

        // Check for primary fire release — throw the grenade
        if (!self.button0)
            W_HLGrenadeRelease();
        return;
    }

    if (self.weaponstate == WS_FIRE)
    {
        // Spawn grenade entity after the throw delay
        if (self.hlgren_throw_vel > 0 && time >= self.hlgren_spawn_time)
        {
            entity gren;
            float tv = self.hlgren_throw_vel;
            self.hlgren_throw_vel = 0;  // only spawn once

            makevectors(self.v_angle);
            gren = spawn();
            gren.owner = self;
            gren.classname = "proj_hlgrenade";
            gren.movetype = MOVETYPE_TOSS;
            gren.solid = SOLID_BBOX;
            setmodel(gren, HLGREN_GRENADE_MODEL);
            setsize(gren, '-2 -2 -2', '2 2 2');
            setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
            gren.velocity = self.velocity + v_forward * tv + v_up * (tv * 0.4);
            gren.avelocity = '180 360 120';
            gren.gravity = 0.5;
            gren.touch = W_HLGrenadeBounce;
            gren.think = W_HLGrenadeThink;
            gren.nextthink = time + HLGREN_FUSE_TIME;
            // No nodrawtoclient — grenade is fully server-driven, shooter sees server entity
        }

        // Throw animation frame advance
        float tv2 = self.hlgren_throw_vel > 0 ? self.hlgren_throw_vel : max(200, min(HLGREN_MAX_THROW_SPEED, (self.wep_anim_start - self.altfire_finished) * HLGREN_THROW_CHARGE_RATE));
        if (tv2 <= HLGREN_THROW1_MAX_VEL)
            self.wep_nextframe += HLGREN_THROW1_INTERVAL;
        else if (tv2 <= HLGREN_THROW2_MAX_VEL)
            self.wep_nextframe += HLGREN_THROW2_INTERVAL;
        else
            self.wep_nextframe += HLGREN_THROW3_INTERVAL;

        self.weaponframe += 1;
    }
    else
    {
        self.weaponframe += 1;
        self.wep_nextframe += HLGREN_FRAME_INTERVAL;
    }

    result = SH_HLGrenadeTickState(time);
    if (result & 1)
    {
        self.weaponframe   = HLGREN_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_HLGrenadeEquip =
{
    W_StandardEquipSetup(HLGREN_VIEWMODEL, HLGREN_DISPLAY_NAME, HLGREN_DRAW_START,
        HLGREN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire       = W_HLGrenadeFire;
    self.reload     = __NULL__;
    self.wepframe   = W_HLGrenadeFrame;
    self.hlgren_throw_vel = 0;
    self.hlgren_spawn_time = 0;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_HLGrenadeDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_hlgrenade = self.ammo_hlgrenade;
    self.ammo_hlgrenade = 0;

    setmodel(tgt, HLGREN_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_hlgrenade";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLGRENADE;
    tgt.weapon_slot  = SLOT_UTILITY;
    tgt.weap_draw    = W_HLGrenadeEquip;
    tgt.weap_drop_func = W_HLGrenadeDrop;
    tgt.pickupcopy   = W_HLGrenadePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlgrenade =
{
    setmodel(self, HLGREN_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_hlgrenade";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLGRENADE;
    self.weapon_slot   = SLOT_UTILITY;
    self.weap_draw     = W_HLGrenadeEquip;
    self.weap_drop_func = W_HLGrenadeDrop;
    self.pickupcopy    = W_HLGrenadePickupCopy;
    self.touch         = weapon_touch;
    self.ammo_hlgrenade = MAX_AMMO_HLGRENADE;
    W_RegisterMapWeapon(weapon_hlgrenade);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Grenade is fully server-driven — no client prediction for state or projectiles.
// The server handles pin pull, throw, and grenade entity spawning.
// Client only provides display frame and equip registration.

void() CSQC_PredictHLGrenadeCommand =
{
    // No client prediction — server handles everything
    SH_HLGrenadeTickState(csqc_pred_time);
};

float(float elapsed) CSQC_HLGrenadeDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = HLGREN_DRAW_START + elapsed / HLGREN_FRAME_INTERVAL;
        return bound(HLGREN_DRAW_START, frame, HLGREN_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // Pin pull animation — clamp at end
        frame = HLGREN_PIN_START + elapsed / HLGREN_FRAME_INTERVAL;
        return bound(HLGREN_PIN_START, frame, HLGREN_PIN_END);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Determine which throw animation based on hold time
        float hold_time = predicted_player.wep_anim_start - predicted_player.altfire_finished;
        float throw_vel = min(HLGREN_MAX_THROW_SPEED, hold_time * HLGREN_THROW_CHARGE_RATE);

        if (throw_vel <= HLGREN_THROW1_MAX_VEL)
        {
            frame = HLGREN_THROW1_START + elapsed / HLGREN_THROW1_INTERVAL;
            return bound(HLGREN_THROW1_START, frame, HLGREN_THROW1_END - 1);
        }
        else if (throw_vel <= HLGREN_THROW2_MAX_VEL)
        {
            frame = HLGREN_THROW2_START + elapsed / HLGREN_THROW2_INTERVAL;
            return bound(HLGREN_THROW2_START, frame, HLGREN_THROW2_END - 1);
        }
        else
        {
            frame = HLGREN_THROW3_START + elapsed / HLGREN_THROW3_INTERVAL;
            return bound(HLGREN_THROW3_START, frame, HLGREN_THROW3_END - 1);
        }
    }
    return HLGREN_IDLE_FRAME;
};

void() CSQC_HLGrenadeDropClear =
{
	self.ammo_hlgrenade = 0;
};

void() CSQC_HLGrenadeEquip =
{
	self.weapon_name         = HLGREN_DISPLAY_NAME;
	self.weapon_viewmodel    = HLGREN_VIEWMODEL;
	self.weapon_worldmodel   = HLGREN_WORLDMODEL;
	self.weapon_deploy_sound = HLGREN_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictHLGrenadeCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_HLGrenadeDisplayFrame;
	self.csqc_drop_clear     = CSQC_HLGrenadeDropClear;
};

#endif // CSQC
