// ============================================================
//  shared/weapons/sh_wpn_rebar.qc  -  Rebar Gun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 12-bolt magazine, no reserve, hitscan
//  Fire  : lag-compensated hitscan, linear damage falloff
//         Spawns a stuck rebar model at the hit point (server only)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_rebar;

// --- Animation frames ---
const float REBAR_FRAME_INTERVAL      = 0.05;   // 1/20

const float REBAR_DRAW_START          = 1;
const float REBAR_DRAW_END            = 10;

const float REBAR_FIRE_START          = 11;
const float REBAR_FIRE_END            = 31;
const float REBAR_FIRE_DELAY          = 0.6;

const float REBAR_EMPTY_FIRE_END      = 17;
const float REBAR_EMPTY_IDLE_FRAME    = 17;
const float REBAR_IDLE_FRAME          = 0;

const float MAX_MAG_REBAR             = 12;

// --- Balance ---
const float REBAR_CLOSE_DAMAGE        = 75;
const float REBAR_MIN_DAMAGE          = 60;
const float REBAR_DAMAGE_FALLOFF_RANGE = 4096;
const float REBAR_DRYFIRE_DELAY       = 0.2;

// --- Pre-computed durations ---
const float REBAR_DRAW_DURATION       = (REBAR_DRAW_END - REBAR_DRAW_START) * REBAR_FRAME_INTERVAL;
const float REBAR_FIRE_DURATION       = (REBAR_FIRE_END - REBAR_FIRE_START) * REBAR_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_RebarTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;
    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= REBAR_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= REBAR_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_RebarTryFire =
{
    if (self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;
    if (self.weaponstate != WS_IDLE) return 0;

    if (self.mag_rebar <= 0)
    { self.attack_finished = now + REBAR_DRYFIRE_DELAY; return -1; }

    self.mag_rebar       -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + REBAR_FIRE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_RebarPickupCopy =
{ player.mag_rebar = self.mag_rebar; };

void() W_RebarStuckThink =
{ remove(self); };

void() W_RebarShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;
    entity stuck;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    dir = v_forward;
    end = src + dir * 8192;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);

        if (W_CanDamageTarget(trace_ent))
        {
            damage = W_LinearDamageFalloff(dist, REBAR_CLOSE_DAMAGE, REBAR_MIN_DAMAGE, REBAR_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);

            // Spawn stuck rebar visual — offset out of the wall along surface normal
            stuck = spawn();
            setmodel(stuck, "models/weapons/wpn_rebar/rebar.mdl");
            setorigin(stuck, trace_endpos + trace_plane_normal * 2);
            stuck.angles = vectoangles(dir);
            stuck.solid = SOLID_NOT;
            stuck.movetype = MOVETYPE_NONE;
            stuck.think = W_RebarStuckThink;
            stuck.nextthink = time + 30;
        }

        sound(self, CHAN_AUTO, "sounds/weapons/wpn_rebar/stick.wav", 1, ATTN_NORM);
    }
};

void() W_RebarFire =
{
    float r = SH_RebarTryFire(time);
    if (r == 1)
    {
        self.weaponframe = REBAR_FIRE_START;
        self.wep_nextframe = time + REBAR_FRAME_INTERVAL;
        W_RebarShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_rebar/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_RebarFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += REBAR_FRAME_INTERVAL;

    result = SH_RebarTickState(time);
    if (result & 1)
    {
        if (self.mag_rebar <= 0)
            self.weaponframe = REBAR_EMPTY_IDLE_FRAME;
        else
            self.weaponframe = REBAR_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_RebarEquip =
{
    self.weaponmodel = SH_WeaponViewModel(WEP_REBAR);
    self.weapon_name = "REBAR";
    self.weapon_draw_start_frame = REBAR_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_RebarFire; self.reload = __NULL__; self.wepframe = W_RebarFrame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = W_RebarShoot; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = REBAR_DRAW_START;
    self.wep_nextframe = time + REBAR_FRAME_INTERVAL;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_RebarDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_rebar = self.mag_rebar;
    self.mag_rebar = 0;
    setmodel(tgt, "models/weapons/wpn_rebar/w_rebar.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_rebar"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_REBAR; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_RebarEquip; tgt.weap_drop_func = W_RebarDrop;
    tgt.pickupcopy = W_RebarPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_rebar =
{
    setmodel(self, "models/weapons/wpn_rebar/w_rebar.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_rebar"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_REBAR; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_RebarEquip; self.weap_drop_func = W_RebarDrop;
    self.pickupcopy = W_RebarPickupCopy; self.touch = weapon_touch;
    self.mag_rebar = MAX_MAG_REBAR;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictRebarCommand =
{
    float r;
    if (input_buttons & 1)
    {
        r = SH_RebarTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_rebar/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(0, 0, 320);
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }
    SH_RebarTickState(csqc_pred_time);
};

float(float elapsed) CSQC_RebarDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = REBAR_DRAW_START + elapsed / REBAR_FRAME_INTERVAL; return bound(REBAR_DRAW_START, frame, REBAR_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = REBAR_FIRE_START + elapsed / REBAR_FRAME_INTERVAL; return bound(REBAR_FIRE_START, frame, REBAR_FIRE_END - 1); }
    if (predicted_player.mag_rebar <= 0)
        return REBAR_EMPTY_IDLE_FRAME;
    return REBAR_IDLE_FRAME;
};

#endif // CSQC
