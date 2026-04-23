// ============================================================
//  shared/weapons/sh_wpn_hlsmg.qc  -  HL MP5/SMG
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 50-round magazine, 250 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : Contact grenade launcher (WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_hlsmg;
.float ammo_hlsmg;
.float ammo_hlsmg_grenades;

// --- Animation frames ---
const float HLSMG_FRAME_INTERVAL         = 0.05;    // 20fps

const float HLSMG_DRAW_START             = 0;
const float HLSMG_DRAW_END               = 8;

const float HLSMG_FIRE1_START            = 9;
const float HLSMG_FIRE1_END              = 15;
const float HLSMG_FIRE2_START            = 16;
const float HLSMG_FIRE2_END              = 22;
const float HLSMG_FIRE3_START            = 23;
const float HLSMG_FIRE3_END              = 29;
const float HLSMG_FIRE_DELAY             = 0.1;

const float HLSMG_GRENADE_START          = 30;
const float HLSMG_GRENADE_END            = 52;
const float HLSMG_GRENADE_DELAY          = 1.0;

const float HLSMG_RELOAD_START           = 53;
const float HLSMG_RELOAD_END             = 84;
const float HLSMG_RELOAD_SND1_FRAME     = 60;   // reload1.wav (clip out)
const float HLSMG_RELOAD_SND2_FRAME     = 73;   // reload2.wav (clip in)

const float HLSMG_IDLE_FRAME             = 85;

const float MAX_MAG_HLSMG                = 50;
const float MAX_AMMO_HLSMG               = 250;
const float MAX_AMMO_HLSMG_GRENADES      = 2;

// --- Balance ---
const float HLSMG_BASE_SPREAD            = 0.05;
const float HLSMG_MOVE_SPREAD            = 0.08;
const float HLSMG_FULL_SPREAD_SPEED      = 320;
const float HLSMG_CLOSE_DAMAGE           = 10;
const float HLSMG_MIN_DAMAGE             = 5;
const float HLSMG_DAMAGE_FALLOFF_RANGE   = 2048;
const float HLSMG_DRYFIRE_DELAY          = 0.2;

// --- Grenade balance ---
const float HLSMG_GRENADE_SPEED          = 1000;
const float HLSMG_GRENADE_DAMAGE         = 100;
const float HLSMG_GRENADE_MIN_DAMAGE     = 10;
const float HLSMG_GRENADE_RADIUS         = 250;

// --- Pre-computed state durations ---
const float HLSMG_DRAW_DURATION          = (HLSMG_DRAW_END - HLSMG_DRAW_START) * HLSMG_FRAME_INTERVAL;
const float HLSMG_FIRE_DURATION          = (HLSMG_FIRE1_END - HLSMG_FIRE1_START) * HLSMG_FRAME_INTERVAL;
const float HLSMG_GRENADE_DURATION       = (HLSMG_GRENADE_END - HLSMG_GRENADE_START) * HLSMG_FRAME_INTERVAL;
const float HLSMG_RELOAD_DURATION        = (HLSMG_RELOAD_END - HLSMG_RELOAD_START) * HLSMG_FRAME_INTERVAL;
const float HLSMG_RELOAD_APPLY_TIME      = HLSMG_RELOAD_DURATION;  // apply at end

const string HLSMG_VIEWMODEL    = "models/weapons/wpn_hlsmg/v_smg.mdl";
const string HLSMG_WORLDMODEL   = "models/weapons/wpn_hlsmg/w_smg.mdl";
const string HLSMG_DEPLOY_SOUND = "";
const string HLSMG_DISPLAY_NAME = "SMG";

// ============================================================
//  SHARED — state machine
//  Manual tick (like M3) to handle WS_FIRE + WS_SPECIAL + WS_RELOAD
// ============================================================

float(float now) SH_HLSMGTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= HLSMG_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= HLSMG_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= HLSMG_GRENADE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= HLSMG_RELOAD_DURATION)
        {
            // Apply reload ammo
            float need = MAX_MAG_HLSMG - self.mag_hlsmg;
            float give = min(need, self.ammo_hlsmg);
            self.mag_hlsmg  += give;
            self.ammo_hlsmg -= give;
            SH_WeaponEnterIdle();
            return 1 | 2;
        }
        return 0;
    }
    return 0;
};

float(float now) SH_HLSMGTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_hlsmg, HLSMG_FIRE_DELAY, HLSMG_DRYFIRE_DELAY);
};

float(float now) SH_HLSMGTryGrenade =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_hlsmg_grenades <= 0)
    { self.attack_finished = now + HLSMG_DRYFIRE_DELAY; return -1; }

    self.ammo_hlsmg_grenades -= 1;
    self.weaponstate          = WS_SPECIAL;
    self.wep_action_id       += 1;
    self.wep_anim_start       = now;
    self.attack_finished      = now + HLSMG_GRENADE_DELAY;
    return 1;
};

float(float now) SH_HLSMGTryReload =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_hlsmg >= MAX_MAG_HLSMG || self.ammo_hlsmg <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_HLSMGPickupCopy =
{
    player.mag_hlsmg           = self.mag_hlsmg;
    player.ammo_hlsmg          = self.ammo_hlsmg;
    player.ammo_hlsmg_grenades = self.ammo_hlsmg_grenades;
};

void() W_HLSMGShoot =
{
    W_PenetratingHitscanShoot(HLSMG_BASE_SPREAD, HLSMG_MOVE_SPREAD, HLSMG_FULL_SPREAD_SPEED,
        HLSMG_CLOSE_DAMAGE, HLSMG_MIN_DAMAGE, HLSMG_DAMAGE_FALLOFF_RANGE, 24, 0.95);
};

// Grenade explosion — radius damage
void() W_HLSMGGrenadeExplode =
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
    e = findradius(self.origin, HLSMG_GRENADE_RADIUS);
    while (e)
    {
        if (W_CanDamageTarget(e))
        {
            dist = vlen(e.origin - self.origin);
            damage = W_LinearDamageFalloff(dist, HLSMG_GRENADE_DAMAGE, HLSMG_GRENADE_MIN_DAMAGE, HLSMG_GRENADE_RADIUS);
            W_ApplyDamage(self.owner, e, damage);
        }

        // Push players away from explosion
        if (e.classname == "player" && e.health > 0)
        {
            dist = vlen(e.origin - self.origin);
            float push_scale = 1 - (dist / HLSMG_GRENADE_RADIUS);
            vector push_dir = normalize(e.origin - self.origin);
            e.velocity += push_dir * 800 * push_scale;
            e.velocity_z += 350 * push_scale;
        }

        e = e.chain;
    }

    remove(self);
};

void() W_HLSMGGrenadeTouch =
{
    if (other == self.owner)
        return;
    W_HLSMGGrenadeExplode();
};

void() W_HLSMGFire =
{
    float r = SH_HLSMGTryFire(time);

    if (r == 1)
    {
        // Random fire animation variant
        float anim = random();
        if (anim < 0.333)
            self.weaponframe = HLSMG_FIRE1_START;
        else if (anim < 0.666)
            self.weaponframe = HLSMG_FIRE2_START;
        else
            self.weaponframe = HLSMG_FIRE3_START;

        self.wep_nextframe = time + HLSMG_FRAME_INTERVAL;

        W_HLSMGShoot();

        float snd = random();
        if (snd < 0.333)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire1.wav", 1, ATTN_NORM);
        else if (snd < 0.666)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire2.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire3.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_HLSMGAltFire =
{
    float r;
    entity gren;

    r = SH_HLSMGTryGrenade(time);
    if (r == 1)
    {
        self.weaponframe   = HLSMG_GRENADE_START;
        self.wep_nextframe = time + HLSMG_FRAME_INTERVAL;

        // Spawn grenade projectile
        makevectors(self.v_angle);
        gren = spawn();
        gren.owner     = self;
        gren.classname = "proj_smg_grenade";
        gren.movetype  = MOVETYPE_TOSS;
        gren.solid     = SOLID_BBOX;
        setmodel(gren, "models/weapons/wpn_grenadelauncher/grenade.mdl");
        setsize(gren, '-2 -2 -2', '2 2 2');
        setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
        gren.velocity  = self.velocity + v_forward * HLSMG_GRENADE_SPEED + v_up * 120;
        gren.avelocity = '180 360 120';
        gren.gravity   = 1;
        gren.touch     = W_HLSMGGrenadeTouch;
        gren.think     = W_HLSMGGrenadeExplode;
        gren.nextthink = time + 5;
        gren.nodrawtoclient = self;   // shooter sees client-predicted grenade instead

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher2.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_HLSMGReload =
{
    if (SH_HLSMGTryReload(time))
    {
        self.weaponframe   = HLSMG_RELOAD_START;
        self.wep_nextframe = time + HLSMG_FRAME_INTERVAL;
    }
};

void() W_HLSMGFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += HLSMG_FRAME_INTERVAL;

    // Reload sounds at specific frames
    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == HLSMG_RELOAD_SND1_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlsmg/reload1.wav", 1, ATTN_NORM);
        if (self.weaponframe == HLSMG_RELOAD_SND2_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlsmg/reload2.wav", 1, ATTN_NORM);
    }

    result = SH_HLSMGTickState(time);
    if (result & 1)
    {
        self.weaponframe   = HLSMG_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_HLSMGEquip =
{
    W_StandardEquipSetup(HLSMG_VIEWMODEL, HLSMG_DISPLAY_NAME, HLSMG_DRAW_START,
        HLSMG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_HLSMGFire;
    self.reload   = W_HLSMGReload;
    self.wepframe = W_HLSMGFrame;
    self.shoot    = W_HLSMGShoot;
    self.altfire  = W_HLSMGAltFire;
    W_SetCrosshairProfile(HLSMG_BASE_SPREAD, HLSMG_MOVE_SPREAD, HLSMG_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_HLSMGDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_hlsmg           = self.mag_hlsmg;
    tgt.ammo_hlsmg          = self.ammo_hlsmg;
    tgt.ammo_hlsmg_grenades = self.ammo_hlsmg_grenades;

    self.mag_hlsmg           = 0;
    self.ammo_hlsmg          = 0;
    self.ammo_hlsmg_grenades = 0;

    setmodel(tgt, "models/weapons/wpn_hlsmg/w_smg.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_hlsmg";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLSMG;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_HLSMGEquip;
    tgt.weap_drop_func = W_HLSMGDrop;
    tgt.pickupcopy   = W_HLSMGPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlsmg =
{
    setmodel(self, "models/weapons/wpn_hlsmg/w_smg.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_hlsmg";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLSMG;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_HLSMGEquip;
    self.weap_drop_func = W_HLSMGDrop;
    self.pickupcopy    = W_HLSMGPickupCopy;
    self.touch         = weapon_touch;
    self.mag_hlsmg           = MAX_MAG_HLSMG;
    self.ammo_hlsmg          = MAX_AMMO_HLSMG;
    self.ammo_hlsmg_grenades = MAX_AMMO_HLSMG_GRENADES;
    W_RegisterMapWeapon(weapon_hlsmg);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_hlsmg_reload_snd_stage;

void() CSQC_FakeHLSMGGrenadeExplode =
{
    pointsound(self.origin, "sounds/weapons/explode1.wav", 1, ATTN_NORM);
    te_explosion(self.origin + '0 0 8');
    remove(self);
};

void() CSQC_FakeHLSMGGrenadeTouch =
{
    if (other == self.owner)
        return;
    CSQC_FakeHLSMGGrenadeExplode();
};

void() CSQC_PredictHLSMGCommand =
{
    float r;

    // Alt-fire: grenade launcher
    if (input_buttons & 4)
    {
        r = SH_HLSMGTryGrenade(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();

                // Spawn fake grenade projectile for instant visual
                {
                    entity gren = spawn();
                    makevectors(input_angles);
                    setmodel(gren, "models/weapons/wpn_grenadelauncher/grenade.mdl");
                    setsize(gren, '-2 -2 -2', '2 2 2');
                    setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
                    gren.owner     = self;
                    gren.velocity  = self.velocity + v_forward * HLSMG_GRENADE_SPEED + v_up * 120;
                    gren.avelocity = '180 360 120';
                    gren.movetype  = MOVETYPE_TOSS;
                    gren.solid     = SOLID_BBOX;
                    gren.gravity   = 1;
                    gren.drawmask  = MASK_ENGINE;
                    gren.touch     = CSQC_FakeHLSMGGrenadeTouch;
                    gren.think     = CSQC_FakeHLSMGGrenadeExplode;
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

    // Primary fire: auto hitscan
    if (input_buttons & 1)
    {
        r = SH_HLSMGTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                float snd = random();
                if (snd < 0.333)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire1.wav", 1, ATTN_NONE);
                else if (snd < 0.666)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire2.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire3.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(HLSMG_BASE_SPREAD, HLSMG_MOVE_SPREAD, HLSMG_FULL_SPREAD_SPEED,
                    HLSMG_CLOSE_DAMAGE, HLSMG_MIN_DAMAGE, HLSMG_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
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

    // Predicted reload sounds at frame-matched timings
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float snd1_time = (HLSMG_RELOAD_SND1_FRAME - HLSMG_RELOAD_START) * HLSMG_FRAME_INTERVAL;
        float snd2_time = (HLSMG_RELOAD_SND2_FRAME - HLSMG_RELOAD_START) * HLSMG_FRAME_INTERVAL;

        if (csqc_hlsmg_reload_snd_stage < 1 && reload_elapsed >= snd1_time)
        { localsound("sounds/weapons/wpn_hlsmg/reload1.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsmg_reload_snd_stage = 1; }
        if (csqc_hlsmg_reload_snd_stage < 2 && reload_elapsed >= snd2_time)
        { localsound("sounds/weapons/wpn_hlsmg/reload2.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsmg_reload_snd_stage = 2; }
    }

    SH_HLSMGTickState(csqc_pred_time);
};

void() CSQC_PredictHLSMGReload =
{
    if (SH_HLSMGTryReload(csqc_pred_time))
    { csqc_hlsmg_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_HLSMGDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = HLSMG_DRAW_START + elapsed / HLSMG_FRAME_INTERVAL; return bound(HLSMG_DRAW_START, frame, HLSMG_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = HLSMG_FIRE1_START + elapsed / HLSMG_FRAME_INTERVAL; return bound(HLSMG_FIRE1_START, frame, HLSMG_FIRE3_END - 1); }
    if (predicted_player.weaponstate == WS_SPECIAL)
    { frame = HLSMG_GRENADE_START + elapsed / HLSMG_FRAME_INTERVAL; return bound(HLSMG_GRENADE_START, frame, HLSMG_GRENADE_END - 1); }
    if (predicted_player.weaponstate == WS_RELOAD)
    { frame = HLSMG_RELOAD_START + elapsed / HLSMG_FRAME_INTERVAL; return bound(HLSMG_RELOAD_START, frame, HLSMG_RELOAD_END - 1); }
    return HLSMG_IDLE_FRAME;
};

void() CSQC_HLSMGDropClear =
{
	self.mag_hlsmg = 0;
	self.ammo_hlsmg = 0;
	self.ammo_hlsmg_grenades = 0;
};

void() CSQC_HLSMGEquip =
{
	self.weapon_name         = HLSMG_DISPLAY_NAME;
	self.weapon_viewmodel    = HLSMG_VIEWMODEL;
	self.weapon_worldmodel   = HLSMG_WORLDMODEL;
	self.weapon_deploy_sound = HLSMG_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictHLSMGCommand;
	self.csqc_predict_reload = CSQC_PredictHLSMGReload;
	self.csqc_display_frame  = CSQC_HLSMGDisplayFrame;
	self.csqc_drop_clear     = CSQC_HLSMGDropClear;
};

#endif // CSQC
