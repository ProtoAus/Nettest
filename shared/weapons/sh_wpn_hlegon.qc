// ============================================================
//  shared/weapons/sh_wpn_hlegon.qc  -  HL Egon Gun
//
//  Slot  : SLOT_PRIMARY
//  Stats : ammo_hlegon (no magazine, direct ammo pool)
//  Fire  : Hold +attack for continuous beam weapon
//          Press → windup sound, damage + drain start immediately
//          After 3s → run sound replaces windup
//          Release → off sound, return to idle
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float ammo_hlegon;
.float egon_fire_state;       // 0=off, 1=winding up, 2=firing (run sound)
.float egon_next_drain;       // next time to drain 1 ammo
.float egon_next_damage;      // next time to deal damage pulse
.float egon_windup_end;       // time when windup ends and run sound should play

// --- Animation frames ---
const float EGON_FRAME_INTERVAL       = 0.05;   // 1/20

const float EGON_DRAW_START           = 0;
const float EGON_DRAW_END             = 10;

const float EGON_FIRE1_START          = 11;
const float EGON_FIRE1_END            = 21;
const float EGON_FIRE4_END            = 51;

const float EGON_IDLE_FRAME           = 52;

const float MAX_AMMO_HLEGON           = 100;

// --- Balance ---
const float EGON_DAMAGE_PER_PULSE     = 20;
const float EGON_DAMAGE_PULSE_RATE    = 0.1;
const float EGON_AMMO_DRAIN_RATE      = 0.2;
const float EGON_BEAM_RANGE           = 2048;
const float EGON_WINDUP_TIME          = 3.0;
const float EGON_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed durations ---
const float EGON_DRAW_DURATION        = (EGON_DRAW_END - EGON_DRAW_START) * EGON_FRAME_INTERVAL;

const string EGON_VIEWMODEL    = "models/weapons/wpn_hlegon/v_egon.mdl";
const string EGON_WORLDMODEL   = "models/weapons/wpn_hlegon/w_egon.mdl";
const string EGON_DEPLOY_SOUND = "";
const string EGON_DISPLAY_NAME = "EGON";

const string EGON_SND_WINDUP   = "sounds/weapons/wpn_hlegon/windup.wav";
const string EGON_SND_RUN      = "sounds/weapons/wpn_hlegon/run.wav";
const string EGON_SND_OFF      = "sounds/weapons/wpn_hlegon/off.wav";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_EgonTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;
    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= EGON_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
    }
    return 0;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_EgonPickupCopy =
{ player.ammo_hlegon = self.ammo_hlegon; };

void() W_EgonBeamDamage =
{
    vector src, dir, end, beam_end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    dir = v_forward;
    end = src + dir * EGON_BEAM_RANGE;
    W_WeaponTraceLine(src, end);
    beam_end = (trace_fraction < 1.0) ? trace_endpos : end;
    te_beam(self, src, beam_end);
    if (trace_fraction < 1.0)
    {
        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, EGON_DAMAGE_PER_PULSE);
        else
            W_ImpactEffect(trace_endpos);
        W_DebugImpact(trace_endpos, EGON_DAMAGE_PER_PULSE, W_BoneToHitgroup(trace_bone_id));
    }
};

// Called by W_WeaponFrame when button0 is pressed
void() W_EgonFire =
{
    if (self.weaponstate == WS_FIRE) return;  // already firing
    if (self.weaponstate == WS_DRAW) return;
    if (self.ammo_hlegon <= 0)
    {
        self.attack_finished = time + EGON_DRYFIRE_DELAY;
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
        return;
    }

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = time;
    self.egon_fire_state = 1;
    self.egon_next_drain = time + EGON_AMMO_DRAIN_RATE;
    self.egon_next_damage = time + EGON_DAMAGE_PULSE_RATE;
    self.egon_windup_end = time + EGON_WINDUP_TIME;
    self.weaponframe     = EGON_FIRE1_START;
    self.wep_nextframe   = time + EGON_FRAME_INTERVAL;
    sound(self, CHAN_WEAPON, EGON_SND_WINDUP, 1, ATTN_NORM);
};

void() W_EgonFrame =
{
    self.wep_nextframe = time + EGON_FRAME_INTERVAL;

    if (self.weaponstate == WS_IDLE)
    { self.weaponframe = EGON_IDLE_FRAME; return; }

    if (self.weaponstate == WS_DRAW)
    {
        self.weaponframe += 1;
        if (self.weaponframe >= EGON_DRAW_END)
        { self.weaponframe = EGON_IDLE_FRAME; self.weaponstate = WS_IDLE; self.wep_anim_start = 0; }
        return;
    }

    if (self.weaponstate == WS_FIRE)
    {
        // Released +attack or out of ammo → stop
        if (!self.button0 || self.ammo_hlegon <= 0)
        {
            self.egon_fire_state = 0;
            self.weaponstate     = WS_IDLE;
            self.wep_action_id  += 1;
            self.wep_anim_start  = 0;
            self.weaponframe     = EGON_IDLE_FRAME;
            sound(self, CHAN_WEAPON, EGON_SND_OFF, 1, ATTN_NORM);
            return;
        }

        // Windup → run sound transition
        if (self.egon_fire_state == 1 && time >= self.egon_windup_end)
        {
            self.egon_fire_state = 2;
            sound(self, CHAN_WEAPON, EGON_SND_RUN, 1, ATTN_NORM);
        }

        // Drain ammo
        if (time >= self.egon_next_drain)
        {
            self.ammo_hlegon -= 1;
            if (self.ammo_hlegon < 0) self.ammo_hlegon = 0;
            self.egon_next_drain = time + EGON_AMMO_DRAIN_RATE;
        }

        // Damage pulse + beam
        if (time >= self.egon_next_damage)
        {
            W_EgonBeamDamage();
            self.egon_next_damage = time + EGON_DAMAGE_PULSE_RATE;
        }
        else
        {
            // Beam visual between pulses
            vector src, end, beam_end;
            makevectors(self.v_angle);
            src = self.origin + self.view_ofs;
            end = src + v_forward * EGON_BEAM_RANGE;
            W_WeaponTraceLine(src, end);
            beam_end = (trace_fraction < 1.0) ? trace_endpos : end;
            te_beam(self, src, beam_end);
        }

        // Cycle fire animation
        self.weaponframe += 1;
        if (self.weaponframe >= EGON_FIRE4_END)
            self.weaponframe = EGON_FIRE1_START;
        return;
    }

    self.weaponframe = EGON_IDLE_FRAME;
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
};

void() W_EgonEquip =
{
    self.weaponmodel = EGON_VIEWMODEL;
    self.weapon_name = EGON_DISPLAY_NAME;
    self.weapon_draw_start_frame = EGON_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_EgonFire; self.reload = __NULL__; self.wepframe = W_EgonFrame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = EGON_DRAW_START;
    self.wep_nextframe = time + EGON_FRAME_INTERVAL;
    self.egon_fire_state = 0; self.egon_next_drain = 0; self.egon_next_damage = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, TRUE);
};

void() W_EgonDrop =
{
    entity tgt = weapon_drop_target;
    tgt.ammo_hlegon = self.ammo_hlegon;
    self.ammo_hlegon = 0;
    setmodel(tgt, EGON_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_hlegon"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_HLEGON; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_EgonEquip; tgt.weap_drop_func = W_EgonDrop;
    tgt.pickupcopy = W_EgonPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_hlegon =
{
    setmodel(self, EGON_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_hlegon"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_HLEGON; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_EgonEquip; self.weap_drop_func = W_EgonDrop;
    self.pickupcopy = W_EgonPickupCopy; self.touch = weapon_touch;
    self.ammo_hlegon = MAX_AMMO_HLEGON;
    W_RegisterMapWeapon(weapon_hlegon);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictEgonCommand =
{
    // Egon is continuous hold-to-fire — skip entirely during replay.
    // Server reconciliation handles the authoritative state.
    if (pm_suppress_sounds)
        return;

    float firing = (input_buttons & 1);

    if (firing && self.weaponstate != WS_FIRE)
    {
        if (self.weaponstate == WS_DRAW) return;
        if (self.ammo_hlegon <= 0)
        {
            self.attack_finished = csqc_pred_time + EGON_DRYFIRE_DELAY;
            localsound("sounds/weapons/dryfire1.wav");
            CSQC_RecordPredictedWeaponSound();
            CSQC_MarkPendingWeaponAck();
            return;
        }

        // Start fire
        self.weaponstate     = WS_FIRE;
        self.wep_action_id  += 1;
        self.wep_anim_start  = csqc_pred_time;
        self.egon_fire_state = 1;
        self.egon_next_drain = csqc_pred_time + EGON_AMMO_DRAIN_RATE;
        self.egon_windup_end = csqc_pred_time + EGON_WINDUP_TIME;
        sound(self, CHAN_WEAPON, EGON_SND_WINDUP, 1, ATTN_NONE);
        CSQC_RecordPredictedWeaponSound();
        CSQC_MarkPendingWeaponAck();
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (!firing || self.ammo_hlegon <= 0)
        {
            // Stop
            self.egon_fire_state = 0;
            self.weaponstate     = WS_IDLE;
            self.wep_action_id  += 1;
            self.wep_anim_start  = 0;
            sound(self, CHAN_WEAPON, EGON_SND_OFF, 1, ATTN_NONE);
            CSQC_RecordPredictedWeaponSound();
            CSQC_MarkPendingWeaponAck();
            return;
        }

        // Windup → run sound
        if (self.egon_fire_state == 1 && csqc_pred_time >= self.egon_windup_end)
        {
            self.egon_fire_state = 2;
            sound(self, CHAN_WEAPON, EGON_SND_RUN, 1, ATTN_NONE);
            CSQC_RecordPredictedWeaponSound();
        }

        // Drain ammo
        if (csqc_pred_time >= self.egon_next_drain)
        {
            self.ammo_hlegon -= 1;
            if (self.ammo_hlegon < 0) self.ammo_hlegon = 0;
            self.egon_next_drain = csqc_pred_time + EGON_AMMO_DRAIN_RATE;
        }

        // Beam visual
        makevectors(input_angles);
        vector src = self.origin + self.view_ofs;
        vector end = src + v_forward * EGON_BEAM_RANGE;
        traceline(src, end, MOVE_NORMAL, self);
        te_beam(self, src, trace_endpos);
    }

    SH_EgonTickState(csqc_pred_time);
};

float(float elapsed) CSQC_EgonDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = EGON_DRAW_START + elapsed / EGON_FRAME_INTERVAL; return bound(EGON_DRAW_START, frame, EGON_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        float fire_total = (EGON_FIRE4_END - EGON_FIRE1_START) * EGON_FRAME_INTERVAL;
        float loop_elapsed = elapsed - floor(elapsed / fire_total) * fire_total;
        frame = EGON_FIRE1_START + loop_elapsed / EGON_FRAME_INTERVAL;
        return bound(EGON_FIRE1_START, frame, EGON_FIRE4_END - 1);
    }
    return EGON_IDLE_FRAME;
};

void() CSQC_EgonDropClear =
{
	self.ammo_hlegon = 0;
};

void() CSQC_EgonEquip =
{
	self.weapon_name         = EGON_DISPLAY_NAME;
	self.weapon_viewmodel    = EGON_VIEWMODEL;
	self.weapon_worldmodel   = EGON_WORLDMODEL;
	self.weapon_deploy_sound = EGON_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictEgonCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_EgonDisplayFrame;
	self.csqc_drop_clear     = CSQC_EgonDropClear;
};

#endif // CSQC
