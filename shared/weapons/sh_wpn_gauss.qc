// ============================================================
//  shared/weapons/sh_wpn_gauss.qc  -  HL Gauss Gun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : ammo_gauss (no magazine, direct ammo pool)
//  Fire  : primary = instant hitscan beam (2 ammo), alt = hold to charge
//  Alt   : Hold alt-fire to charge, release to fire charged beam
//         Charge drains 1 ammo every 0.3s, auto-fires if ammo depletes
//         Charged shot pushes player backward
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float ammo_gauss;
.float gauss_charge_state;        // 0=none, 1=winding up, 2=looping
.float gauss_charge_started;      // time when charge began
.float gauss_charge_next_ammo;    // next time to drain 1 ammo during charge

// --- Animation frames ---
const float GAUSS_FRAME_INTERVAL      = 0.05;   // 1/20

const float GAUSS_DRAW_START          = 1;
const float GAUSS_DRAW_END            = 12;

const float GAUSS_FIRE_START          = 13;
const float GAUSS_FIRE_END            = 40;

const float GAUSS_CHARGE_START        = 41;
const float GAUSS_CHARGE_START_END    = 61;
const float GAUSS_CHARGE_LOOP_START   = 62;
const float GAUSS_CHARGE_LOOP_END     = 72;

const float GAUSS_IDLE_FRAME          = 73;

const float MAX_AMMO_GAUSS            = 120;

// --- Balance ---
const float GAUSS_PRIMARY_DAMAGE      = 20;
const float GAUSS_PRIMARY_AMMO_COST   = 2;
const float GAUSS_PRIMARY_DELAY       = 0.2;
const float GAUSS_CHARGE_START_DELAY  = 0.1;
const float GAUSS_CHARGED_DELAY       = 0.5;
const float GAUSS_MAX_CHARGE_TIME     = 4.0;
const float GAUSS_CHARGE_AMMO_INTERVAL = 0.3;
const float GAUSS_MIN_CHARGE_DAMAGE   = 40;
const float GAUSS_MAX_CHARGE_DAMAGE   = 200;
const float GAUSS_DRYFIRE_DELAY       = 0.2;
const float GAUSS_OVERCHARGE_TIME     = 10.0;   // hold charge this long = self-damage
const float GAUSS_OVERCHARGE_DAMAGE   = 50;     // damage dealt to self on overcharge
const float GAUSS_CHARGE_BLAST_RADIUS = 120;    // charged shot explosion radius
const float GAUSS_CHARGE_BLAST_PUSH   = 600;    // knockback force
const float GAUSS_CHARGE_BLAST_UPLIFT = 250;    // vertical knockback bonus

// --- Pre-computed durations ---
const float GAUSS_DRAW_DURATION       = (GAUSS_DRAW_END - GAUSS_DRAW_START) * GAUSS_FRAME_INTERVAL;
const float GAUSS_FIRE_DURATION       = (GAUSS_FIRE_END - GAUSS_FIRE_START) * GAUSS_FRAME_INTERVAL;

const string GAUSS_VIEWMODEL    = "models/weapons/wpn_hlgauss/v_gauss.mdl";
const string GAUSS_WORLDMODEL   = "models/weapons/wpn_hlgauss/w_gauss.mdl";
const string GAUSS_DEPLOY_SOUND = "";
const string GAUSS_DISPLAY_NAME = "GAUSS";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_GaussTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= GAUSS_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= GAUSS_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    // WS_SPECIAL (charging) doesn't auto-transition — it's ended by release or ammo depletion
    return 0;
};

float(float now) SH_GaussTryPrimaryFire =
{
#ifdef CSQC
    if (cltime < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_gauss < GAUSS_PRIMARY_AMMO_COST)
    {
        self.attack_finished = now + GAUSS_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = cltime + GAUSS_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.ammo_gauss      -= GAUSS_PRIMARY_AMMO_COST;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + GAUSS_PRIMARY_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = cltime + GAUSS_PRIMARY_DELAY;
#endif
    return 1;
};

float(float now) SH_GaussTryAltFire =
{
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_gauss <= 0)
    { self.attack_finished = now + GAUSS_DRYFIRE_DELAY; return -1; }

    self.ammo_gauss          -= 1;
    self.weaponstate          = WS_SPECIAL;
    self.wep_action_id       += 1;
    self.wep_anim_start       = now;
    self.attack_finished      = now + GAUSS_CHARGE_START_DELAY;
    self.gauss_charge_state   = 1;
    self.gauss_charge_started = now;
    self.gauss_charge_next_ammo = now + GAUSS_CHARGE_AMMO_INTERVAL;
    return 1;
};

// Returns damage based on charge time. Clears charge state.
float(float now) SH_GaussCalcChargeDamage =
{
    float charge_elapsed, charge_ratio, damage;

    if (self.gauss_charge_state <= 0)
        return 0;

    charge_elapsed = now - self.gauss_charge_started;
    if (charge_elapsed < 0) charge_elapsed = 0;

    charge_ratio = bound(0, charge_elapsed / GAUSS_MAX_CHARGE_TIME, 1);
    damage = GAUSS_MIN_CHARGE_DAMAGE + (GAUSS_MAX_CHARGE_DAMAGE - GAUSS_MIN_CHARGE_DAMAGE) * charge_ratio;

    self.gauss_charge_state = 0;
    self.gauss_charge_started = 0;
    self.gauss_charge_next_ammo = 0;
    self.weaponstate = WS_FIRE;
    self.wep_action_id += 1;
    self.wep_anim_start = now;
    self.attack_finished = now + GAUSS_CHARGED_DELAY;

    // Pushback — applied in shared code so both server and client handle it
    #ifdef SSQC
    makevectors(self.v_angle);
    #else
    makevectors(input_angles);
    #endif
    self.velocity = self.velocity - v_forward * bound(100, damage * 3, 600);

    return damage;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_GaussPickupCopy =
{ player.ammo_gauss = self.ammo_gauss; };

void(float damage, float is_primary) W_GaussBeamFire =
{
    vector src, dir, end, beam_end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    dir = v_forward;
    end = src + dir * 8192;

    W_WeaponTraceLine(src, end);

    beam_end = (trace_fraction < 1.0) ? trace_endpos : end;
    te_beam(self, src, beam_end);

    if (trace_fraction < 1.0)
    {
        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, damage);
        else
            W_ImpactEffect(trace_endpos);

        W_DebugImpact(trace_endpos, damage, W_BoneToHitgroup(trace_bone_id));

        // Charged shot: explosion at impact point
        if (!is_primary)
        {
            te_explosion(trace_endpos);

            // Radius damage + knockback
            entity e = findradius(trace_endpos, GAUSS_CHARGE_BLAST_RADIUS);
            while (e)
            {
                float bdist = vlen(e.origin - trace_endpos);

                if (W_CanDamageTarget(e))
                {
                    float blast_dmg = W_LinearDamageFalloff(bdist, damage * 0.5, damage * 0.1, GAUSS_CHARGE_BLAST_RADIUS);
                    W_ApplyDamage(self, e, blast_dmg);
                }

                if (e.classname == "player" && e.health > 0)
                {
                    float push_scale = 1 - (bdist / GAUSS_CHARGE_BLAST_RADIUS);
                    push_scale = max(0, push_scale);
                    vector push_dir = normalize(e.origin - trace_endpos);
                    e.velocity += push_dir * GAUSS_CHARGE_BLAST_PUSH * push_scale;
                    e.velocity_z += GAUSS_CHARGE_BLAST_UPLIFT * push_scale;
                }

                e = e.chain;
            }
        }
    }
};

void() W_GaussPrimaryFire =
{
    float r = SH_GaussTryPrimaryFire(time);
    if (r == 1)
    {
        self.weaponframe = GAUSS_FIRE_START;
        self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
        W_GaussBeamFire(GAUSS_PRIMARY_DAMAGE, TRUE);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GaussAltFire =
{
    float r = SH_GaussTryAltFire(time);
    if (r == 1)
    {
        self.weaponframe = GAUSS_CHARGE_START;
        self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/charge.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GaussAltRelease =
{
    float damage;

    if (self.weaponstate != WS_SPECIAL) return;

    damage = SH_GaussCalcChargeDamage(time);
    if (damage > 0)
    {
        self.weaponframe = GAUSS_FIRE_START;
        self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
        W_GaussBeamFire(damage, FALSE);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
    }
};

void() W_GaussFrame =
{
    self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;

    if (self.weaponstate == WS_IDLE)
    {
        self.weaponframe = GAUSS_IDLE_FRAME;
        return;
    }

    self.weaponframe += 1;

    if (self.weaponstate == WS_DRAW)
    {
        if (self.weaponframe >= GAUSS_DRAW_END)
        { self.weaponframe = GAUSS_IDLE_FRAME; self.weaponstate = WS_IDLE; self.wep_anim_start = 0; }
        return;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe >= GAUSS_FIRE_END)
        { self.weaponframe = GAUSS_IDLE_FRAME; self.weaponstate = WS_IDLE; self.wep_anim_start = 0; }
        return;
    }

    if (self.weaponstate == WS_SPECIAL)
    {
        // Charge animation: wind-up then loop
        if (self.gauss_charge_state == 1 && self.weaponframe >= GAUSS_CHARGE_START_END)
        {
            self.weaponframe = GAUSS_CHARGE_LOOP_START;
            self.gauss_charge_state = 2;
        }
        else if (self.gauss_charge_state >= 2 && self.weaponframe > GAUSS_CHARGE_LOOP_END)
            self.weaponframe = GAUSS_CHARGE_LOOP_START;

        // Overcharge: held too long — hurts self, plays fire animation
        if ((time - self.gauss_charge_started) >= GAUSS_OVERCHARGE_TIME)
        {
            SH_GaussCalcChargeDamage(time);   // clears charge state, sets WS_FIRE
            self.weaponframe = GAUSS_FIRE_START;
            W_ApplyDamage(self, self, GAUSS_OVERCHARGE_DAMAGE);
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
            return;
        }

        // Auto-fire if ammo depleted during charge
        if (self.ammo_gauss <= 0)
        {
            float damage = SH_GaussCalcChargeDamage(time);
            if (damage > 0)
            {
                self.weaponframe = GAUSS_FIRE_START;
                W_GaussBeamFire(damage, FALSE);
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
            }
            return;
        }

        // Drain ammo periodically during charge
        if (self.gauss_charge_next_ammo > 0 && time >= self.gauss_charge_next_ammo)
        {
            if ((time - self.gauss_charge_started) < GAUSS_MAX_CHARGE_TIME)
            {
                self.ammo_gauss -= 1;
                if (self.ammo_gauss < 0) self.ammo_gauss = 0;
                self.gauss_charge_next_ammo = time + GAUSS_CHARGE_AMMO_INTERVAL;
            }
            else
                self.gauss_charge_next_ammo = 0;
        }
        return;
    }

    self.weaponframe = GAUSS_IDLE_FRAME;
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
};

void() W_GaussEquip =
{
    self.weaponmodel = GAUSS_VIEWMODEL;
    self.weapon_name = GAUSS_DISPLAY_NAME;
    self.weapon_draw_start_frame = GAUSS_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_GaussPrimaryFire; self.reload = __NULL__; self.wepframe = W_GaussFrame;
    self.altfire = W_GaussAltFire; self.altrelease = W_GaussAltRelease;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = GAUSS_DRAW_START;
    self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
    self.gauss_charge_state = 0; self.gauss_charge_started = 0; self.gauss_charge_next_ammo = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, TRUE);
};

void() W_GaussDrop =
{
    entity tgt = weapon_drop_target;
    tgt.ammo_gauss = self.ammo_gauss;
    self.ammo_gauss = 0;
    setmodel(tgt, "models/weapons/wpn_hlgauss/w_gauss.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_gauss"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_GAUSS; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_GaussEquip; tgt.weap_drop_func = W_GaussDrop;
    tgt.pickupcopy = W_GaussPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_gauss =
{
    setmodel(self, "models/weapons/wpn_hlgauss/w_gauss.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_gauss"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_GAUSS; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_GaussEquip; self.weap_drop_func = W_GaussDrop;
    self.pickupcopy = W_GaussPickupCopy; self.touch = weapon_touch;
    self.ammo_gauss = MAX_AMMO_GAUSS;
    W_RegisterMapWeapon(weapon_gauss);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictGaussCommand =
{
    float r;

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_GaussTryPrimaryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();
                // Gauss is perfectly accurate — direct trace, no spread system
                {
                    makevectors(input_angles);
                    vector gsrc = self.origin + self.view_ofs;
                    traceline(gsrc, gsrc + v_forward * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        CSQC_BulletImpact(trace_endpos, trace_plane_normal, GAUSS_PRIMARY_DAMAGE);
                        if (cvar("cl_debug_impacts"))
                            CSQC_AddDebugImpact(trace_endpos, gsrc, '0 1 0', 0, 0);
                    }
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

    // Alt-fire: start charge — state change runs during replay (costs ammo, won't infinite-loop)
    // sounds only play during live prediction
    if (input_buttons & 4)
    {
        r = SH_GaussTryAltFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/charge.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Overcharge: held too long — hurts self, play fire animation
    if (self.weaponstate == WS_SPECIAL && self.gauss_charge_state > 0
        && (csqc_pred_time - self.gauss_charge_started) >= GAUSS_OVERCHARGE_TIME)
    {
        SH_GaussCalcChargeDamage(csqc_pred_time);
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NONE);
            CSQC_RecordPredictedWeaponSound();
        }
    }

    // Alt-fire release: fire charged shot — runs during replay for velocity push
    if (self.weaponstate == WS_SPECIAL
        && self.gauss_charge_state > 0 && !(input_buttons & 4))
    {
        float damage = SH_GaussCalcChargeDamage(csqc_pred_time);
        if (damage > 0)
        {
            CSQC_MarkPendingWeaponAck();

            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();
                // Gauss is perfectly accurate — direct trace, no spread system
                {
                    makevectors(input_angles);
                    gsrc = self.origin + self.view_ofs;
                    traceline(gsrc, gsrc + v_forward * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage);
                        if (cvar("cl_debug_impacts"))
                            CSQC_AddDebugImpact(trace_endpos, gsrc, '0 1 0', 0, 0);
                    }
                }
            }
        }
    }

    SH_GaussTickState(csqc_pred_time);
};

float(float elapsed) CSQC_GaussDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    { frame = GAUSS_DRAW_START + elapsed / GAUSS_FRAME_INTERVAL; return bound(GAUSS_DRAW_START, frame, GAUSS_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = GAUSS_FIRE_START + elapsed / GAUSS_FRAME_INTERVAL; return bound(GAUSS_FIRE_START, frame, GAUSS_FIRE_END - 1); }
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // Charge: wind-up then loop
        float charge_end_time = (GAUSS_CHARGE_START_END - GAUSS_CHARGE_START) * GAUSS_FRAME_INTERVAL;
        float loop_dur = (GAUSS_CHARGE_LOOP_END - GAUSS_CHARGE_LOOP_START) * GAUSS_FRAME_INTERVAL;

        if (elapsed < charge_end_time)
        { frame = GAUSS_CHARGE_START + elapsed / GAUSS_FRAME_INTERVAL; return bound(GAUSS_CHARGE_START, frame, GAUSS_CHARGE_START_END - 1); }

        float loop_elapsed = elapsed - charge_end_time;
        loop_elapsed = loop_elapsed - floor(loop_elapsed / loop_dur) * loop_dur;
        frame = GAUSS_CHARGE_LOOP_START + loop_elapsed / GAUSS_FRAME_INTERVAL;
        return bound(GAUSS_CHARGE_LOOP_START, frame, GAUSS_CHARGE_LOOP_END - 1);
    }
    return GAUSS_IDLE_FRAME;
};

void() CSQC_GaussDropClear =
{
	self.ammo_gauss = 0;
};

void() CSQC_GaussEquip =
{
	self.weapon_name         = GAUSS_DISPLAY_NAME;
	self.weapon_viewmodel    = GAUSS_VIEWMODEL;
	self.weapon_worldmodel   = GAUSS_WORLDMODEL;
	self.weapon_deploy_sound = GAUSS_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictGaussCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_GaussDisplayFrame;
	self.csqc_drop_clear     = CSQC_GaussDropClear;
};

#endif // CSQC
