// ============================================================
//  shared/weapons/sh_wpn_hlcrowbar.qc  -  HL Crowbar (melee)
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo, melee swing with random hit/miss anims
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Animation frames ---
const float CROWBAR_FRAME_INTERVAL    = 0.05;   // 20fps

const float CROWBAR_DRAW_START        = 1;
const float CROWBAR_DRAW_END          = 10;

const float CROWBAR_IDLE_START        = 106;
const float CROWBAR_IDLE_END          = 192;

// Miss animation variants
const float CROWBAR_MISS1_START       = 12;
const float CROWBAR_MISS1_END         = 19;
const float CROWBAR_MISS2_START       = 32;
const float CROWBAR_MISS2_END         = 42;
const float CROWBAR_MISS3_START       = 58;
const float CROWBAR_MISS3_END         = 72;

// Hit animation variants
const float CROWBAR_HIT1_START        = 45;
const float CROWBAR_HIT1_END          = 55;
const float CROWBAR_HIT2_START        = 75;
const float CROWBAR_HIT2_END          = 88;

const float CROWBAR_FIRE_DELAY        = 0.5;

// --- Balance ---
const float CROWBAR_DAMAGE            = 25;
const float CROWBAR_RANGE             = 64;

// --- Pre-computed state durations ---
const float CROWBAR_DRAW_DURATION     = (CROWBAR_DRAW_END - CROWBAR_DRAW_START) * CROWBAR_FRAME_INTERVAL;
// Fire duration is variable (depends on which anim plays), use longest
const float CROWBAR_FIRE_MAX_DURATION = (CROWBAR_HIT2_END - CROWBAR_HIT2_START) * CROWBAR_FRAME_INTERVAL;

const string CROWBAR_VIEWMODEL    = "models/weapons/wpn_hlcrowbar/v_crowbar.mdl";
const string CROWBAR_WORLDMODEL   = "models/weapons/wpn_hlcrowbar/w_crowbar.mdl";
const string CROWBAR_DEPLOY_SOUND = "";
const string CROWBAR_DISPLAY_NAME = "CROWBAR";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CrowbarTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CROWBAR_DRAW_DURATION)
        {
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= CROWBAR_FIRE_MAX_DURATION)
        {
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            return 1;
        }
        return 0;
    }

    return 0;
};

float(float now) SH_CrowbarTryFire =
{
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + CROWBAR_FIRE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CrowbarPickupCopy =
{
};

void() W_CrowbarSwing =
{
    vector src, end;
    float r;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * CROWBAR_RANGE;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, CROWBAR_DAMAGE, W_BoneToHitgroup(trace_bone_id));

        // Pick a hit animation
        if (random() < 0.5)
            self.weaponframe = CROWBAR_HIT1_START;
        else
            self.weaponframe = CROWBAR_HIT2_START;

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitwall1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitwall2.wav", 1, ATTN_NORM);

        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, CROWBAR_DAMAGE);
        else
            W_ImpactEffect(trace_endpos);
    }
    else
    {
        // Pick a miss animation
        r = random();
        if (r < 0.333)
            self.weaponframe = CROWBAR_MISS1_START;
        else if (r < 0.666)
            self.weaponframe = CROWBAR_MISS2_START;
        else
            self.weaponframe = CROWBAR_MISS3_START;

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/miss.wav", 1, ATTN_NORM);
    }
};

void() W_CrowbarFire =
{
    if (SH_CrowbarTryFire(time))
    {
        // Set initial miss frame; W_CrowbarSwing will override with hit/miss variant
        self.weaponframe = CROWBAR_MISS1_START;
        self.wep_nextframe = time + CROWBAR_FRAME_INTERVAL;
        W_CrowbarSwing();
    }
};

void() W_CrowbarFrame =
{
    float result;
    float max_frame;

    self.weaponframe += 1;
    self.wep_nextframe += CROWBAR_FRAME_INTERVAL;

    // Determine the end frame for the current animation range
    if (self.weaponstate == WS_FIRE)
    {
        max_frame = 0;
        if (self.weaponframe >= CROWBAR_MISS1_START && self.weaponframe <= CROWBAR_MISS1_END)
            max_frame = CROWBAR_MISS1_END;
        else if (self.weaponframe >= CROWBAR_MISS2_START && self.weaponframe <= CROWBAR_MISS2_END)
            max_frame = CROWBAR_MISS2_END;
        else if (self.weaponframe >= CROWBAR_MISS3_START && self.weaponframe <= CROWBAR_MISS3_END)
            max_frame = CROWBAR_MISS3_END;
        else if (self.weaponframe >= CROWBAR_HIT1_START && self.weaponframe <= CROWBAR_HIT1_END)
            max_frame = CROWBAR_HIT1_END;
        else if (self.weaponframe >= CROWBAR_HIT2_START && self.weaponframe <= CROWBAR_HIT2_END)
            max_frame = CROWBAR_HIT2_END;

        if (max_frame > 0 && self.weaponframe >= max_frame)
        {
            self.weaponframe = CROWBAR_IDLE_START;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
            return;
        }
    }

    result = SH_CrowbarTickState(time);
    if (result & 1)
    {
        self.weaponframe = CROWBAR_IDLE_START;
        self.wep_nextframe = 0;
    }
};

void() W_CrowbarEquip =
{
    self.weaponmodel = CROWBAR_VIEWMODEL;
    self.weapon_name = CROWBAR_DISPLAY_NAME;
    self.weapon_draw_start_frame = CROWBAR_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_MELEE;
    self.fire = W_CrowbarFire;
    self.reload = __NULL__;
    self.wepframe = W_CrowbarFrame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = W_CrowbarSwing; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = CROWBAR_DRAW_START;
    self.wep_nextframe = time + CROWBAR_FRAME_INTERVAL;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_CrowbarDrop =
{
    entity tgt = weapon_drop_target;
    setmodel(tgt, "models/weapons/wpn_hlcrowbar/w_crowbar.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_hlcrowbar"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_HLCROWBAR; tgt.weapon_slot = SLOT_MELEE;
    tgt.weap_draw = W_CrowbarEquip; tgt.weap_drop_func = W_CrowbarDrop;
    tgt.pickupcopy = W_CrowbarPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_hlcrowbar =
{
    setmodel(self, "models/weapons/wpn_hlcrowbar/w_crowbar.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_hlcrowbar"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_HLCROWBAR; self.weapon_slot = SLOT_MELEE;
    self.weap_draw = W_CrowbarEquip; self.weap_drop_func = W_CrowbarDrop;
    self.pickupcopy = W_CrowbarPickupCopy; self.touch = weapon_touch;
    W_RegisterMapWeapon(weapon_hlcrowbar);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Track which animation variant the client predicted
float csqc_crowbar_predicted_hit;       // TRUE if predicted trace hit something
float csqc_crowbar_anim_start;          // animation start frame chosen by prediction
float csqc_crowbar_anim_end;            // animation end frame

void() CSQC_PredictCrowbarCommand =
{
    float did_hit;

    // Skip fire during replay — no ammo to deplete, would cause infinite re-fires
    if (!pm_suppress_sounds && (input_buttons & 1))
    {
        if (SH_CrowbarTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            did_hit = CSQC_PredictedMeleeTrace(CROWBAR_RANGE, CROWBAR_DAMAGE,
                "sounds/weapons/wpn_hlcrowbar/hitwall1.wav",
                "sounds/weapons/wpn_hlcrowbar/hitwall2.wav",
                "sounds/weapons/wpn_hlcrowbar/miss.wav");
            CSQC_RecordPredictedWeaponSound();

            csqc_crowbar_predicted_hit = did_hit;
            if (did_hit)
            {
                if (random() < 0.5)
                { csqc_crowbar_anim_start = CROWBAR_HIT1_START; csqc_crowbar_anim_end = CROWBAR_HIT1_END; }
                else
                { csqc_crowbar_anim_start = CROWBAR_HIT2_START; csqc_crowbar_anim_end = CROWBAR_HIT2_END; }
            }
            else
            {
                float r = random();
                if (r < 0.333)
                { csqc_crowbar_anim_start = CROWBAR_MISS1_START; csqc_crowbar_anim_end = CROWBAR_MISS1_END; }
                else if (r < 0.666)
                { csqc_crowbar_anim_start = CROWBAR_MISS2_START; csqc_crowbar_anim_end = CROWBAR_MISS2_END; }
                else
                { csqc_crowbar_anim_start = CROWBAR_MISS3_START; csqc_crowbar_anim_end = CROWBAR_MISS3_END; }
            }
        }
    }
    SH_CrowbarTickState(csqc_pred_time);
};

float(float elapsed) CSQC_CrowbarDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = CROWBAR_DRAW_START + elapsed / CROWBAR_FRAME_INTERVAL;
        return bound(CROWBAR_DRAW_START, frame, CROWBAR_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = csqc_crowbar_anim_start + elapsed / CROWBAR_FRAME_INTERVAL;
        return bound(csqc_crowbar_anim_start, frame, csqc_crowbar_anim_end - 1);
    }
    return CROWBAR_IDLE_START;
};

void() CSQC_CrowbarDropClear =
{
};

void() CSQC_CrowbarEquip =
{
	self.weapon_name         = CROWBAR_DISPLAY_NAME;
	self.weapon_viewmodel    = CROWBAR_VIEWMODEL;
	self.weapon_worldmodel   = CROWBAR_WORLDMODEL;
	self.weapon_deploy_sound = CROWBAR_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictCrowbarCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_CrowbarDisplayFrame;
	self.csqc_drop_clear     = CSQC_CrowbarDropClear;
};

#endif // CSQC
