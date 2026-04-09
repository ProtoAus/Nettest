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

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_GLTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;
    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= GL_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= GL_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_GLTryFire =
{
    if (self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;
    if (self.weaponstate != WS_IDLE) return 0;

    if (self.mag_grenadelauncher <= 0)
    { self.attack_finished = now + GL_DRYFIRE_DELAY; return -1; }

    self.mag_grenadelauncher -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + GL_FIRE_DELAY;
    return 1;
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
    entity e;

    // Explosion sound + visual (offset 8 units up off the ground)
    sound(self, CHAN_WEAPON, "sounds/weapons/explode1.wav", 1, ATTN_NORM);
    te_explosion(self.origin + '0 0 8');

    // Radius damage
    e = findradius(self.origin, GL_EXPLOSION_RADIUS);
    while (e)
    {
        if (W_CanDamageTarget(e))
        {
            dist = vlen(e.origin - self.origin);
            damage = W_LinearDamageFalloff(dist, GL_EXPLOSION_DAMAGE, GL_EXPLOSION_MIN_DAMAGE, GL_EXPLOSION_RADIUS);
            W_ApplyDamage(self.owner, e, damage);
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
    self.weaponmodel = SH_WeaponViewModel(WEP_GRENADELAUNCHER);
    self.weapon_name = "GL";
    self.weapon_draw_start_frame = GL_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_GLFire; self.reload = __NULL__; self.wepframe = W_GLFrame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = GL_DRAW_START;
    self.wep_nextframe = time + GL_FRAME_INTERVAL;
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
                    setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
                    gren.velocity = self.velocity + v_forward * GL_PROJECTILE_SPEED + v_up * GL_PROJECTILE_UPSPEED;
                    gren.avelocity = '180 360 120';
                    gren.movetype = MOVETYPE_TOSS;
                    gren.solid = SOLID_NOT;
                    gren.gravity = 1;
                    gren.drawmask = MASK_ENGINE;
                    gren.think = CSQC_FakeProjectileExpire;
                    // Expire based on ping so it disappears when server grenade arrives
                    float ping_est = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
                    gren.nextthink = time + bound(0.1, ping_est, 1.0) + 0.2;
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
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = GL_DRAW_START + elapsed / GL_FRAME_INTERVAL; return bound(GL_DRAW_START, frame, GL_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = GL_FIRE_START + elapsed / GL_FRAME_INTERVAL; return bound(GL_FIRE_START, frame, GL_FIRE_END - 1); }
    return GL_IDLE_FRAME;
};

#endif // CSQC
