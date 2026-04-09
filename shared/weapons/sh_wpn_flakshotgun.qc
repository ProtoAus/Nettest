// ============================================================
//  shared/weapons/sh_wpn_flakshotgun.qc  -  Flak Shotgun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell magazine, no reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_flakshotgun;

// --- Animation frames ---
const float FLAKSHOTGUN_FRAME_INTERVAL = 0.05;

const float FLAKSHOTGUN_DRAW_START     = 1;
const float FLAKSHOTGUN_DRAW_END       = 10;

const float FLAKSHOTGUN_FIRE_START     = 11;
const float FLAKSHOTGUN_FIRE_END       = 33;
const float FLAKSHOTGUN_FIRE_DELAY     = 1;
const float FLAKSHOTGUN_PUMP_FRAME     = 16;
const float FLAKSHOTGUN_CASING_FRAME   = 22;

const float FLAKSHOTGUN_IDLE_FRAME     = 0;

const float MAX_MAG_FLAKSHOTGUN        = 24;
const float FLAKSHOTGUN_DRYFIRE_DELAY  = 0.5;

// --- Balance ---
const float FLAKSHOTGUN_PELLETS              = 8;
const float FLAKSHOTGUN_SPREAD               = 0.04;
const float FLAKSHOTGUN_PELLET_CLOSE_DAMAGE  = 6;
const float FLAKSHOTGUN_PELLET_MIN_DAMAGE    = 3;
const float FLAKSHOTGUN_DAMAGE_FALLOFF_RANGE = 1024;

// --- Pre-computed state durations ---
const float FLAKSHOTGUN_DRAW_DURATION  = (FLAKSHOTGUN_DRAW_END - FLAKSHOTGUN_DRAW_START) * FLAKSHOTGUN_FRAME_INTERVAL;
const float FLAKSHOTGUN_FIRE_DURATION  = (FLAKSHOTGUN_FIRE_END - FLAKSHOTGUN_FIRE_START) * FLAKSHOTGUN_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_FlakShotgunTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= FLAKSHOTGUN_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= FLAKSHOTGUN_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

float(float now) SH_FlakShotgunTryFire =
{
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.mag_flakshotgun <= 0)
    {
        self.attack_finished = now + FLAKSHOTGUN_DRYFIRE_DELAY;
        return -1;
    }

    self.mag_flakshotgun -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + FLAKSHOTGUN_FIRE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_FlakShotgunPickupCopy =
{
    player.mag_flakshotgun = self.mag_flakshotgun;
};

void() W_FlakShotgunShoot =
{
    vector src, dir, end;
    float  pellet, sx, sy, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    pellet = 0;
    while (pellet < FLAKSHOTGUN_PELLETS)
    {
        sx  = (random() * 2 - 1) * FLAKSHOTGUN_SPREAD;
        sy  = (random() * 2 - 1) * FLAKSHOTGUN_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        traceline(src, end, MOVE_NORMAL | MOVE_LAGGED, self);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);

            if (W_CanDamageTarget(trace_ent))
            {
                damage = W_LinearDamageFalloff(dist,
                    FLAKSHOTGUN_PELLET_CLOSE_DAMAGE, FLAKSHOTGUN_PELLET_MIN_DAMAGE,
                    FLAKSHOTGUN_DAMAGE_FALLOFF_RANGE);
                W_ApplyDamage(self, trace_ent, damage);
            }
            else
            {
                W_ImpactEffect(trace_endpos);
            }
        }

        pellet += 1;
    }
};

void() W_FlakShotgunFire =
{
    float r = SH_FlakShotgunTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = FLAKSHOTGUN_FIRE_START;
        self.wep_nextframe = time + FLAKSHOTGUN_FRAME_INTERVAL;

        W_FlakShotgunShoot();

        r = random();
        if (r < 0.25)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_flakshotgun/fire1.wav", 1, ATTN_NORM);
        else if (r < 0.50)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_flakshotgun/fire2.wav", 1, ATTN_NORM);
        else if (r < 0.75)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_flakshotgun/fire3.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_flakshotgun/fire4.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_FlakShotgunFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += FLAKSHOTGUN_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == FLAKSHOTGUN_PUMP_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_flakshotgun/reload.wav", 1, ATTN_NORM);
        if (self.weaponframe == FLAKSHOTGUN_CASING_FRAME)
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 46 36', '240 720 120');
    }

    result = SH_FlakShotgunTickState(time);
    if (result & 1)
    {
        self.weaponframe   = FLAKSHOTGUN_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_FlakShotgunEquip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_FLAKSHOTGUN);
    self.weapon_name    = "FLAK SHOTGUN";
    self.weapon_draw_start_frame = FLAKSHOTGUN_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire           = W_FlakShotgunFire;
    self.reload         = __NULL__;
    self.wepframe       = W_FlakShotgunFrame;
    self.altfire         = __NULL__;
    self.altrelease      = __NULL__;
    self.shoot           = W_FlakShotgunShoot;
    self.special         = __NULL__;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = FLAKSHOTGUN_DRAW_START;
    self.wep_nextframe  = time + FLAKSHOTGUN_FRAME_INTERVAL;
    W_SetCrosshairProfile(FLAKSHOTGUN_SPREAD, 0, 0, 7, TRUE);
};

void() W_FlakShotgunDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_flakshotgun = self.mag_flakshotgun;
    self.mag_flakshotgun = 0;

    setmodel(tgt, "models/weapons/wpn_flakshotgun/w_flakshotgun.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_flakshotgun";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_FLAKSHOTGUN;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_FlakShotgunEquip;
    tgt.weap_drop_func = W_FlakShotgunDrop;
    tgt.pickupcopy   = W_FlakShotgunPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_flakshotgun =
{
    setmodel(self, "models/weapons/wpn_flakshotgun/w_flakshotgun.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_flakshotgun";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_FLAKSHOTGUN;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_FlakShotgunEquip;
    self.weap_drop_func = W_FlakShotgunDrop;
    self.pickupcopy    = W_FlakShotgunPickupCopy;
    self.touch         = weapon_touch;
    self.mag_flakshotgun = MAX_MAG_FLAKSHOTGUN;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float FLAKSHOTGUN_PUMP_TIME = (FLAKSHOTGUN_PUMP_FRAME - FLAKSHOTGUN_FIRE_START) * FLAKSHOTGUN_FRAME_INTERVAL;
const float FLAKSHOTGUN_CASING_TIME = (FLAKSHOTGUN_CASING_FRAME - FLAKSHOTGUN_FIRE_START) * FLAKSHOTGUN_FRAME_INTERVAL;
float csqc_flaksg_pump_played;
float csqc_flaksg_casing_spawned;

void() CSQC_PredictFlakShotgunCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_FlakShotgunTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_flaksg_pump_played = FALSE;
            csqc_flaksg_casing_spawned = FALSE;
            if (!pm_suppress_sounds)
            {
                r = random();
                if (r < 0.25)
                    localsound("sounds/weapons/wpn_flakshotgun/fire1.wav");
                else if (r < 0.50)
                    localsound("sounds/weapons/wpn_flakshotgun/fire2.wav");
                else if (r < 0.75)
                    localsound("sounds/weapons/wpn_flakshotgun/fire3.wav");
                else
                    localsound("sounds/weapons/wpn_flakshotgun/fire4.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(FLAKSHOTGUN_PELLETS, FLAKSHOTGUN_SPREAD);
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/dryfire1.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Predicted pump sound and shell casing during fire
    if (self.weaponstate == WS_FIRE && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float fire_elapsed = csqc_pred_time - self.wep_anim_start;
        if (!csqc_flaksg_pump_played && fire_elapsed >= FLAKSHOTGUN_PUMP_TIME)
        { localsound("sounds/weapons/wpn_flakshotgun/reload.wav"); CSQC_RecordPredictedAutoSound(); csqc_flaksg_pump_played = TRUE; }
        if (!csqc_flaksg_casing_spawned && fire_elapsed >= FLAKSHOTGUN_CASING_TIME)
        {
            CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            csqc_flaksg_casing_spawned = TRUE;
        }
    }

    SH_FlakShotgunTickState(csqc_pred_time);
};

float(float elapsed) CSQC_FlakShotgunDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = FLAKSHOTGUN_DRAW_START + elapsed / FLAKSHOTGUN_FRAME_INTERVAL;
        return bound(FLAKSHOTGUN_DRAW_START, frame, FLAKSHOTGUN_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = FLAKSHOTGUN_FIRE_START + elapsed / FLAKSHOTGUN_FRAME_INTERVAL;
        return bound(FLAKSHOTGUN_FIRE_START, frame, FLAKSHOTGUN_FIRE_END - 1);
    }
    return FLAKSHOTGUN_IDLE_FRAME;
};

#endif // CSQC
