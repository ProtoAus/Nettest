// ============================================================
//  shared/weapons/sh_wpn_csawp.qc  -  CS AWP
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 10-round magazine, 20 reserve, bolt-action
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_awp;
.float ammo_awp;

// --- Animation frames ---
const float AWP_FRAME_INTERVAL        = 0.0333334;   // 1/30

const float AWP_DRAW_START            = 1;
const float AWP_DRAW_END              = 21;
const float AWP_DRAW_DEPLOY_FRAME     = 2;

const float fire_START            = 22;
const float fire_END              = 49;
const float fire_DELAY            = 1.2;
const float fire_BOLTUP_FRAME     = 33;
const float fire_BOLTPULL_FRAME   = 37;
const float fire_BOLTDOWN_FRAME   = 41;

const float AWP_RELOAD_START          = 110;
const float AWP_RELOAD_END            = 163;
const float AWP_RELOAD_CLIPOUT_FRAME  = 123;
const float AWP_RELOAD_CLIPIN_FRAME   = 139;

const float AWP_IDLE_FRAME            = 165;

const float MAX_MAG_AWP               = 10;
const float MAX_AMMO_AWP              = 20;

// --- Balance ---
const float AWP_BASE_SPREAD           = 0.03;
const float AWP_MOVE_SPREAD           = 0.10;
const float AWP_FULL_SPREAD_SPEED     = 320;
const float AWP_CLOSE_DAMAGE          = 120;
const float AWP_MIN_DAMAGE            = 90;
const float AWP_DAMAGE_FALLOFF_RANGE  = 4096;
const float AWP_DRYFIRE_DELAY         = 0.2;

// --- Pre-computed state durations ---
const float AWP_DRAW_DURATION         = (AWP_DRAW_END - AWP_DRAW_START) * AWP_FRAME_INTERVAL;
const float fire_DURATION         = (fire_END - fire_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_DURATION       = (AWP_RELOAD_END - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_APPLY_TIME     = (AWP_RELOAD_CLIPIN_FRAME - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_AWPTickState =
{
    float elapsed, result, needed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    result = 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= AWP_DRAW_DURATION)
        { SH_WeaponEnterIdle(); result = result | 1; }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= fire_DURATION)
        { SH_WeaponEnterIdle(); result = result | 1; }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= AWP_RELOAD_APPLY_TIME)
        {
            needed = MAX_MAG_AWP - self.mag_awp;
            if (needed > 0)
            {
                if (self.ammo_awp >= needed)
                { self.mag_awp += needed; self.ammo_awp -= needed; }
                else
                { self.mag_awp += self.ammo_awp; self.ammo_awp = 0; }
                result = result | 2;
            }
        }
        if (elapsed >= AWP_RELOAD_DURATION)
        { SH_WeaponEnterIdle(); result = result | 1; }
        return result;
    }

    return 0;
};

float(float now) SH_AWPTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_awp <= 0)
    { self.attack_finished = now + AWP_DRYFIRE_DELAY; return -1; }

    self.mag_awp         -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + fire_DELAY;
    self.zoomstage        = 0;
    return 1;
};

float(float now) SH_AWPTryReload =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.mag_awp >= MAX_MAG_AWP || self.ammo_awp <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.zoomstage       = 0;
    return 1;
};

float(float now) SH_AWPTryAltFire =
{
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.zoomstage >= 2)
        self.zoomstage = 0;
    else
        self.zoomstage = self.zoomstage + 1;

    self.attack_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_AWPPickupCopy =
{
    player.mag_awp  = self.mag_awp;
    player.ammo_awp = self.ammo_awp;
};

void() W_AWPShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    flat_vel = self.velocity; flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    if (self.zoomstage > 0)
        spread = 0;
    else
    {
        spread = AWP_BASE_SPREAD + (move_speed / AWP_FULL_SPREAD_SPEED) * AWP_MOVE_SPREAD;
        spread = min(spread, AWP_BASE_SPREAD + AWP_MOVE_SPREAD);
    }

    sx = (random() * 2 - 1) * spread;
    sy = (random() * 2 - 1) * spread;
    dir = normalize(v_forward + v_right * sx + v_up * sy);
    end = src + dir * 8192;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);
        if (W_CanDamageTarget(trace_ent))
        {
            damage = W_LinearDamageFalloff(dist, AWP_CLOSE_DAMAGE, AWP_MIN_DAMAGE, AWP_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
            W_ImpactEffect(trace_endpos);
    }
};

void() W_AWPFire =
{
    float r = SH_AWPTryFire(time);
    if (r == 1)
    {
        self.weaponframe = fire_START;
        self.wep_nextframe = time + AWP_FRAME_INTERVAL;
        W_AWPShoot();
        self.sv_zoomstage = 0;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_AWPAltFire =
{
    if (SH_AWPTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_AWPReload =
{
    if (SH_AWPTryReload(time))
    {
        self.weaponframe = AWP_RELOAD_START;
        self.wep_nextframe = time + AWP_FRAME_INTERVAL;
        self.sv_zoomstage = 0;
    }
};

void() W_AWPFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += AWP_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == fire_BOLTUP_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltup.wav", 1, ATTN_NORM);
        if (self.weaponframe == fire_BOLTPULL_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltpull.wav", 1, ATTN_NORM);
        if (self.weaponframe == fire_BOLTDOWN_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/boltdown.wav", 1, ATTN_NORM);
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == AWP_RELOAD_CLIPOUT_FRAME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == AWP_RELOAD_CLIPIN_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csawp/clipin.wav", 1, ATTN_NORM);
    }

    result = SH_AWPTickState(time);
    if (result & 1)
    { self.weaponframe = AWP_IDLE_FRAME; self.wep_nextframe = 0; }
};

void() W_AWPEquip =
{
    self.weaponmodel = SH_WeaponViewModel(WEP_CSAWP);
    self.weapon_name = "AWP";
    self.weapon_draw_start_frame = AWP_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_AWPFire;
    self.reload = W_AWPReload;
    self.wepframe = W_AWPFrame;
    self.altfire = W_AWPAltFire;
    self.altrelease = __NULL__;
    self.shoot = W_AWPShoot;
    self.special = __NULL__;
    self.weaponstate = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe = AWP_DRAW_START;
    self.wep_nextframe = time + AWP_FRAME_INTERVAL;
    W_ClearZoom();
    W_SetCrosshairProfile(AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_AWPDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_awp = self.mag_awp; tgt.ammo_awp = self.ammo_awp;
    self.mag_awp = 0; self.ammo_awp = 0;

    setmodel(tgt, "models/weapons/wpn_csawp/w_awp.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_csawp"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSAWP; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_AWPEquip; tgt.weap_drop_func = W_AWPDrop;
    tgt.pickupcopy = W_AWPPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csawp =
{
    setmodel(self, "models/weapons/wpn_csawp/w_awp.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_csawp"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSAWP; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_AWPEquip; self.weap_drop_func = W_AWPDrop;
    self.pickupcopy = W_AWPPickupCopy; self.touch = weapon_touch;
    self.mag_awp = MAX_MAG_AWP; self.ammo_awp = MAX_AMMO_AWP;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float AWP_FIRE_BOLTUP_TIME = (fire_BOLTUP_FRAME - fire_START) * AWP_FRAME_INTERVAL;
const float AWP_FIRE_BOLTPULL_TIME = (fire_BOLTPULL_FRAME - fire_START) * AWP_FRAME_INTERVAL;
const float AWP_FIRE_BOLTDOWN_TIME = (fire_BOLTDOWN_FRAME - fire_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_CLIPOUT_TIME = (AWP_RELOAD_CLIPOUT_FRAME - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;
const float AWP_RELOAD_CLIPIN_TIME = (AWP_RELOAD_CLIPIN_FRAME - AWP_RELOAD_START) * AWP_FRAME_INTERVAL;

float csqc_awp_fire_snd_stage;
float csqc_awp_reload_snd_stage;

void() CSQC_PredictAWPCommand =
{
    float r;

    if (input_buttons & 4)
    {
        if (SH_AWPTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_AWPTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_awp_fire_snd_stage = 0;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(AWP_BASE_SPREAD, AWP_MOVE_SPREAD, AWP_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted fire bolt sounds
    if (self.weaponstate == WS_FIRE && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float fire_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_awp_fire_snd_stage < 1 && fire_elapsed >= AWP_FIRE_BOLTUP_TIME)
        { localsound("sounds/weapons/wpn_csawp/boltup.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_fire_snd_stage = 1; }
        if (csqc_awp_fire_snd_stage < 2 && fire_elapsed >= AWP_FIRE_BOLTPULL_TIME)
        { localsound("sounds/weapons/wpn_csawp/boltpull.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_fire_snd_stage = 2; }
        if (csqc_awp_fire_snd_stage < 3 && fire_elapsed >= AWP_FIRE_BOLTDOWN_TIME)
        { localsound("sounds/weapons/wpn_csawp/boltdown.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_fire_snd_stage = 3; }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_awp_reload_snd_stage < 1 && reload_elapsed >= AWP_RELOAD_CLIPOUT_TIME)
        {
            localsound("sounds/weapons/wpn_csawp/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_awp_reload_snd_stage = 1;
        }
        if (csqc_awp_reload_snd_stage < 2 && reload_elapsed >= AWP_RELOAD_CLIPIN_TIME)
        { localsound("sounds/weapons/wpn_csawp/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_awp_reload_snd_stage = 2; }
    }

    SH_AWPTickState(csqc_pred_time);
};

void() CSQC_PredictAWPReload =
{
    if (SH_AWPTryReload(csqc_pred_time))
    { csqc_awp_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_AWPDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = AWP_DRAW_START + elapsed / AWP_FRAME_INTERVAL; return bound(AWP_DRAW_START, frame, AWP_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = fire_START + elapsed / AWP_FRAME_INTERVAL; return bound(fire_START, frame, fire_END - 1); }
    if (predicted_player.weaponstate == WS_RELOAD)
    { frame = AWP_RELOAD_START + elapsed / AWP_FRAME_INTERVAL; return bound(AWP_RELOAD_START, frame, AWP_RELOAD_END - 1); }
    return AWP_IDLE_FRAME;
};

#endif // CSQC
