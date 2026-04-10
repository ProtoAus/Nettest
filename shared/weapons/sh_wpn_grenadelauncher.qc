// ============================================================
//  shared/weapons/sh_wpn_grenadelauncher.qc  -  Grenade Launcher
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 6-grenade magazine, no reserve
//  Fire  : spawns a grenade projectile (MOVETYPE_TOSS)
//         Explodes on contact or after 5 seconds
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_grenadelauncher;

// --- Animation frames ---
const float GL_FRAME_INTERVAL         = 0.05;   // 1/20

const float GL_DRAW_START             = 1;
const float GL_DRAW_END               = 10;

const float GL_FIRE_START             = 11;
const float GL_FIRE_END               = 31;
const float GL_FIRE_DELAY             = 0.8;

const float GL_IDLE_FRAME             = 0;

const float MAX_MAG_GRENADELAUNCHER   = 6;

// --- Balance ---
const float GL_PROJECTILE_SPEED       = 900;
const float GL_PROJECTILE_UPSPEED     = 120;
const float GL_EXPLOSION_RADIUS       = 180;
const float GL_EXPLOSION_DAMAGE       = 110;
const float GL_EXPLOSION_MIN_DAMAGE   = 20;
const float GL_DRYFIRE_DELAY          = 0.2;

// --- Pre-computed durations ---
const float GL_DRAW_DURATION          = (GL_DRAW_END - GL_DRAW_START) * GL_FRAME_INTERVAL;
const float GL_FIRE_DURATION          = (GL_FIRE_END - GL_FIRE_START) * GL_FRAME_INTERVAL;

const string GL_VIEWMODEL    = "models/weapons/wpn_grenadelauncher/v_grenlauncher.mdl";
const string GL_WORLDMODEL   = "models/weapons/wpn_grenadelauncher/w_grenlauncher.mdl";
const string GL_DEPLOY_SOUND = "";
const string GL_DISPLAY_NAME = "GL";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_GLTickState =
{
    return SH_SimpleTickState(now, GL_DRAW_DURATION, GL_FIRE_DURATION);
};

// GL_FIRE_DELAY (0.8) < GL_FIRE_DURATION (1.0), so we must block
// re-fire during WS_FIRE.  SH_StandardTryFire only blocks RELOAD/DRAW,
// so add an explicit idle gate before delegating.
float(float now) SH_GLTryFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    return SH_StandardTryFire(now, mag_grenadelauncher, GL_FIRE_DELAY, GL_DRYFIRE_DELAY);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_GLPickupCopy =
{ player.mag_grenadelauncher = self.mag_grenadelauncher; };

// Grenade explosion — radius damage
void() W_GrenadeExplode =
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
    e = findradius(self.origin, GL_EXPLOSION_RADIUS);
    while (e)
    {
        if (W_CanDamageTarget(e))
        {
            dist = vlen(e.origin - self.origin);
            damage = W_LinearDamageFalloff(dist, GL_EXPLOSION_DAMAGE, GL_EXPLOSION_MIN_DAMAGE, GL_EXPLOSION_RADIUS);
            W_ApplyDamage(self.owner, e, damage);
        }

        // Push players away from explosion
        if (e.classname == "player" && e.health > 0)
        {
            dist = vlen(e.origin - self.origin);
            float push_scale = 1 - (dist / GL_EXPLOSION_RADIUS);
            vector push_dir = normalize(e.origin - self.origin);
            e.velocity += push_dir * 800 * push_scale;
            e.velocity_z += 350 * push_scale;
        }

        e = e.chain;
    }

    remove(self);
};

void() W_GrenadeTouch =
{
    if (other == self.owner)
        return;   // don't explode on shooter
    W_GrenadeExplode();
};

void() W_GrenadeThink =
{
    W_GrenadeExplode();   // timer expired
};

void() W_GLFire =
{
    float r;
    entity gren;

    r = SH_GLTryFire(time);
    if (r == 1)
    {
        self.weaponframe = GL_FIRE_START;
        self.wep_nextframe = time + GL_FRAME_INTERVAL;

        // Spawn grenade projectile
        makevectors(self.v_angle);
        gren = spawn();
        gren.owner = self;
        gren.classname = "proj_grenade";
        gren.movetype = MOVETYPE_TOSS;
        gren.solid = SOLID_BBOX;
        setmodel(gren, "models/weapons/wpn_grenadelauncher/grenade.mdl");
        setsize(gren, '-2 -2 -2', '2 2 2');
        setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
        gren.velocity = self.velocity + v_forward * GL_PROJECTILE_SPEED + v_up * GL_PROJECTILE_UPSPEED;
        gren.avelocity = '180 360 120';
        gren.gravity = 1;
        gren.touch = W_GrenadeTouch;
        gren.think = W_GrenadeThink;
        gren.nextthink = time + 5;
        gren.nodrawtoclient = self;   // shooter sees client-predicted grenade instead

        // Random fire sound
        float snd = random();
        if (snd < 0.333)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_grenadelauncher/fire1.wav", 1, ATTN_NORM);
        else if (snd < 0.666)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_grenadelauncher/fire2.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_grenadelauncher/fire3.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GLFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += GL_FRAME_INTERVAL;

    result = SH_GLTickState(time);
    if (result & 1)
    { self.weaponframe = GL_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_GLEquip =
{
    W_StandardEquipSetup(GL_VIEWMODEL, GL_DISPLAY_NAME, GL_DRAW_START, GL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire = W_GLFire; self.reload = __NULL__; self.wepframe = W_GLFrame;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_GLDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_grenadelauncher = self.mag_grenadelauncher;
    self.mag_grenadelauncher = 0;
    setmodel(tgt, "models/weapons/wpn_grenadelauncher/w_grenlauncher.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_grenadelauncher"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_GRENADELAUNCHER; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_GLEquip; tgt.weap_drop_func = W_GLDrop;
    tgt.pickupcopy = W_GLPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_grenadelauncher =
{
    setmodel(self, "models/weapons/wpn_grenadelauncher/w_grenlauncher.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_grenadelauncher"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_GRENADELAUNCHER; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_GLEquip; self.weap_drop_func = W_GLDrop;
    self.pickupcopy = W_GLPickupCopy; self.touch = weapon_touch;
    self.mag_grenadelauncher = MAX_MAG_GRENADELAUNCHER;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_FakeGrenadeExplode =
{
    pointsound(self.origin, "sounds/weapons/explode1.wav", 1, ATTN_NORM);
    te_explosion(self.origin + '0 0 8');
    remove(self);
};

void() CSQC_FakeGrenadeTouch =
{
    if (other == self.owner)
        return;
    CSQC_FakeGrenadeExplode();
};

void() CSQC_PredictGLCommand =
{
    float r;
    if (input_buttons & 1)
    {
        r = SH_GLTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                float snd = random();
                if (snd < 0.333)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_grenadelauncher/fire1.wav", 1, ATTN_NONE);
                else if (snd < 0.666)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_grenadelauncher/fire2.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_grenadelauncher/fire3.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();

                // Spawn fake grenade projectile for instant visual
                {
                    entity gren = spawn();
                    makevectors(input_angles);
                    setmodel(gren, "models/weapons/wpn_grenadelauncher/grenade.mdl");
                    setsize(gren, '-2 -2 -2', '2 2 2');
                    setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
                    gren.owner = self;
                    gren.velocity = self.velocity + v_forward * GL_PROJECTILE_SPEED + v_up * GL_PROJECTILE_UPSPEED;
                    gren.avelocity = '180 360 120';
                    gren.movetype = MOVETYPE_TOSS;
                    gren.solid = SOLID_BBOX;
                    gren.gravity = 1;
                    gren.drawmask = MASK_ENGINE;
                    gren.touch = CSQC_FakeGrenadeTouch;
                    gren.think = CSQC_FakeGrenadeExplode;
                    gren.nextthink = time + 5;
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
    SH_GLTickState(csqc_pred_time);
};

float(float elapsed) CSQC_GLDisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, GL_FRAME_INTERVAL,
        GL_DRAW_START, GL_DRAW_END,
        GL_FIRE_START, GL_FIRE_END,
        0, 0,
        GL_IDLE_FRAME);
};

void() CSQC_GLDropClear =
{
	self.mag_grenadelauncher = 0;
};

void() CSQC_GLEquip =
{
	self.weapon_name         = GL_DISPLAY_NAME;
	self.weapon_viewmodel    = GL_VIEWMODEL;
	self.weapon_worldmodel   = GL_WORLDMODEL;
	self.weapon_deploy_sound = GL_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictGLCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_GLDisplayFrame;
	self.csqc_drop_clear     = CSQC_GLDropClear;
};

#endif // CSQC
