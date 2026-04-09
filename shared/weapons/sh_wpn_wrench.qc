// ============================================================
//  shared/weapons/sh_wpn_wrench.qc  -  Wrench (melee)
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo, melee swing
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Animation frames ---
const float WRENCH_FRAME_INTERVAL     = 0.05;

const float WRENCH_DRAW_START         = 1;
const float WRENCH_DRAW_END           = 10;

const float WRENCH_FIRE_START         = 11;
const float WRENCH_FIRE_END           = 30;
const float WRENCH_SWING_FRAME        = 15;
const float WRENCH_FIRE_DELAY         = 0.6;

const float WRENCH_IDLE_FRAME         = 0;

// --- Balance ---
const float WRENCH_DAMAGE             = 25;
const float WRENCH_RANGE              = 64;

// --- Pre-computed state durations ---
const float WRENCH_DRAW_DURATION     = (WRENCH_DRAW_END - WRENCH_DRAW_START) * WRENCH_FRAME_INTERVAL;
const float WRENCH_FIRE_DURATION     = (WRENCH_FIRE_END - WRENCH_FIRE_START) * WRENCH_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_WrenchTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= WRENCH_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= WRENCH_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

float(float now) SH_WrenchTryFire =
{
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + WRENCH_FIRE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_WrenchPickupCopy =
{
};

void() W_WrenchSwing =
{
    vector src, end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * WRENCH_RANGE;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_wrench/wrenchclank1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_wrench/wrenchclank2.wav", 1, ATTN_NORM);

        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, WRENCH_DAMAGE);
        else
            W_ImpactEffect(trace_endpos);
    }
    else
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_wrench/wrenchswing.wav", 1, ATTN_NORM);
    }
};

void() W_WrenchFire =
{
    SH_WrenchTryFire(time);

    if (self.weaponstate == WS_FIRE)
    {
        self.weaponframe   = WRENCH_FIRE_START;
        self.wep_nextframe = time + WRENCH_FRAME_INTERVAL;
    }
};

void() W_WrenchFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += WRENCH_FRAME_INTERVAL;

    // Perform swing trace at the hit frame
    if (self.weaponstate == WS_FIRE && self.weaponframe == WRENCH_SWING_FRAME)
        W_WrenchSwing();

    result = SH_WrenchTickState(time);
    if (result & 1)
    {
        self.weaponframe   = WRENCH_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_WrenchEquip =
{
    self.weaponmodel    = SH_WeaponViewModel(WEP_WRENCH);
    self.weapon_name    = "WRENCH";
    self.weapon_draw_start_frame = WRENCH_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_MELEE;
    self.fire           = W_WrenchFire;
    self.reload         = __NULL__;
    self.wepframe       = W_WrenchFrame;
    self.altfire         = __NULL__;
    self.altrelease      = __NULL__;
    self.shoot           = W_WrenchSwing;
    self.special         = __NULL__;
    self.weaponstate    = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = WRENCH_DRAW_START;
    self.wep_nextframe  = time + WRENCH_FRAME_INTERVAL;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_WrenchDrop =
{
    entity tgt = weapon_drop_target;

    setmodel(tgt, "models/weapons/wpn_wrench/g_wrench.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname    = "weapon_wrench";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_WRENCH;
    tgt.weapon_slot  = SLOT_MELEE;
    tgt.weap_draw    = W_WrenchEquip;
    tgt.weap_drop_func = W_WrenchDrop;
    tgt.pickupcopy   = W_WrenchPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_wrench =
{
    setmodel(self, "models/weapons/wpn_wrench/g_wrench.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname     = "weapon_wrench";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_WRENCH;
    self.weapon_slot   = SLOT_MELEE;
    self.weap_draw     = W_WrenchEquip;
    self.weap_drop_func = W_WrenchDrop;
    self.pickupcopy    = W_WrenchPickupCopy;
    self.touch         = weapon_touch;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictWrenchCommand =
{
    // Skip fire during replay — no ammo to deplete, would cause infinite re-fires
    if (!pm_suppress_sounds && (input_buttons & 1))
    {
        if (SH_WrenchTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            CSQC_PredictedMeleeTrace(WRENCH_RANGE,
                "sounds/weapons/wpn_wrench/wrenchclank1.wav",
                "sounds/weapons/wpn_wrench/wrenchclank2.wav",
                "sounds/weapons/wpn_wrench/wrenchswing.wav");
            CSQC_RecordPredictedWeaponSound();
        }
    }

    SH_WrenchTickState(csqc_pred_time);
};

float(float elapsed) CSQC_WrenchDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = WRENCH_DRAW_START + elapsed / WRENCH_FRAME_INTERVAL;
        return bound(WRENCH_DRAW_START, frame, WRENCH_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = WRENCH_FIRE_START + elapsed / WRENCH_FRAME_INTERVAL;
        return bound(WRENCH_FIRE_START, frame, WRENCH_FIRE_END - 1);
    }
    return WRENCH_IDLE_FRAME;
};

#endif // CSQC
