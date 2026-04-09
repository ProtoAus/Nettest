// ============================================================
//  shared/weapons/sh_wpn_csknife.qc  -  CS Knife
//
//  Slot  : SLOT_MELEE
//  Fire  : slash (primary) / stab (alt-fire)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
//  Shared logic runs on both sides; #ifdef gates server-only
//  and client-only sections.
// ============================================================

// --- Balance ---
const float KNIFE_SLASH_RANGE  = 64;
const float KNIFE_STAB_RANGE   = 72;
const float KNIFE_SLASH_DAMAGE = 20;
const float KNIFE_STAB_DAMAGE  = 50;

// --- Animation frames ---
const float KNIFE_DRAW_START        = 1;
const float KNIFE_DRAW_END          = 20;
const float KNIFE_DRAW_SOUND_FRAME  = 3;

const float KNIFE_FIRE1_START       = 21;
const float KNIFE_FIRE1_END         = 35;
const float KNIFE_FIRE1_HIT_FRAME   = 24;

const float KNIFE_FIRE2_START       = 36;
const float KNIFE_FIRE2_END         = 51;
const float KNIFE_FIRE2_HIT_FRAME   = 39;

const float KNIFE_STAB_HIT_START    = 52;
const float KNIFE_STAB_HIT_END      = 76;
const float KNIFE_STAB_HIT_FRAME    = 56;

const float KNIFE_STAB_MISS_START   = 77;
const float KNIFE_STAB_MISS_END     = 93;
const float KNIFE_STAB_MISS_FRAME   = 87;

const float KNIFE_IDLE_START        = 94;
const float KNIFE_IDLE_END          = 113;

// --- Timing ---
const float KNIFE_SLASH_DELAY       = 0.35;
const float KNIFE_STAB_DELAY        = 0.6;
const float KNIFE_FRAME_INTERVAL    = 0.05;
const float KNIFE_IDLEFRAME_INTERVAL = 0.1;

// --- Pre-computed state durations ---
const float KNIFE_DRAW_DURATION       = (KNIFE_DRAW_END - KNIFE_DRAW_START) * KNIFE_FRAME_INTERVAL;
// Fire/stab durations match their attack delays so the weapon returns
// to idle exactly when the next attack is allowed.
const float KNIFE_FIRE_DURATION       = KNIFE_SLASH_DELAY;
const float KNIFE_SPECIAL_DURATION    = KNIFE_STAB_DELAY;

const string KNIFE_VIEWMODEL    = "models/weapons/wpn_csknife/v_knife.mdl";
const string KNIFE_WORLDMODEL   = "models/weapons/wpn_csknife/w_knife.mdl";
const string KNIFE_DEPLOY_SOUND = "sounds/weapons/wpn_csknife/deploy.wav";
const string KNIFE_DISPLAY_NAME = "KNIFE";

// ============================================================
//  SHARED — state machine (server & client identical)
// ============================================================

// Returns: 1 = transitioned to idle, 0 = no change
float(float now) SH_KnifeTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= KNIFE_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= KNIFE_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= KNIFE_SPECIAL_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

// Returns: 1 = slash started, 0 = blocked
float(float now) SH_KnifeTrySlash =
{
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + KNIFE_SLASH_DELAY;
    return 1;
};

// Returns: 1 = stab started, 0 = blocked
float(float now) SH_KnifeTryStab =
{
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + KNIFE_STAB_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY — authoritative fire, frame, equip, world entity
// ============================================================

#ifdef SSQC

void() weapon_touch;
void(vector pos) SpawnImpactLight;
void() PlayerModelPlayPrimaryAttack;

void() W_KnifeEnterIdle;
void() W_KnifeSlashStrike;
void() W_KnifeStabStrike;
void() W_KnifeFire;
void() W_KnifeAltFire;
void() W_KnifeFrame;
float() W_KnifeAltFireWouldHit;
float(float attack_range, float damage) W_KnifeTraceAttack;

void(entity receiver) W_KnifePickupCopy =
{
};

void() W_KnifeDrop =
{
};

void() W_KnifeEnterIdle =
{
    self.weaponframe    = 0;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe  = 0;
};

// Equip — called by W_ChangeWeapon (self = player)
void() W_KnifeEquip =
{
    self.weaponmodel             = KNIFE_VIEWMODEL;
    self.weapon_name             = KNIFE_DISPLAY_NAME;
    self.weapon_draw_start_frame = KNIFE_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_MELEE;
    self.altfire                 = W_KnifeAltFire;
    self.altrelease              = __NULL__;
    self.shoot                   = W_KnifeSlashStrike;
    self.fire                    = W_KnifeFire;
    self.reload                  = __NULL__;
    self.special                 = __NULL__;
    self.wepframe                = W_KnifeFrame;
    self.weaponstate             = WS_DRAW;
    self.wep_action_id          += 1;
    self.wep_anim_start          = time;
    self.weaponframe             = KNIFE_DRAW_START;
    self.wep_nextframe           = time + KNIFE_FRAME_INTERVAL;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

float() W_KnifeAltFireWouldHit =
{
    vector src;
    vector end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + (v_forward * KNIFE_STAB_RANGE);
    W_WeaponTraceLine(src, end);

    return trace_fraction < 1.0;
};

float(float attack_range, float damage) W_KnifeTraceAttack =
{
    vector src;
    vector end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + (v_forward * attack_range);
    W_WeaponTraceLine(src, end);

    if (trace_fraction >= 1.0)
        return FALSE;

    // Debug: send server hit position to shooter only
    {
        float saved_dim = dimension_send;
        dimension_send = self.dimension_seen;
        WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
        WriteByte(MSG_MULTICAST, CSQC_EVENT_DEBUG_IMPACT);
        WriteCoord(MSG_MULTICAST, trace_endpos_x);
        WriteCoord(MSG_MULTICAST, trace_endpos_y);
        WriteCoord(MSG_MULTICAST, trace_endpos_z);
        multicast(trace_endpos, MULTICAST_PVS);
        dimension_send = saved_dim;
    }

    if (W_CanDamageTarget(trace_ent))
    {
        if (random() < 0.5)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csknife/hit1.wav", 1.0, ATTN_NORM);
        else
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csknife/hit2.wav", 1.0, ATTN_NORM);

        W_ApplyDamage(self, trace_ent, damage);
        return TRUE;
    }

    sound(self, CHAN_AUTO, "sounds/weapons/wpn_csknife/hitwall.wav", 1.0, ATTN_NORM);

    if (trace_ent == world || trace_ent.solid == SOLID_BSP)
    {
        W_ImpactEffect(trace_endpos);
        SpawnImpactLight(trace_endpos);
    }

    return TRUE;
};

void() W_KnifeSlashStrike =
{
    W_KnifeTraceAttack(KNIFE_SLASH_RANGE, KNIFE_SLASH_DAMAGE);
};

void() W_KnifeStabStrike =
{
    W_KnifeTraceAttack(KNIFE_STAB_RANGE, KNIFE_STAB_DAMAGE);
};

// Fire — slash attack (self = player)
void() W_KnifeFire =
{
    if (!SH_KnifeTrySlash(time))
        return;

    if (random() < 0.5)
        self.weaponframe = KNIFE_FIRE2_START;
    else
        self.weaponframe = KNIFE_FIRE1_START;

    self.wep_nextframe = time + KNIFE_FRAME_INTERVAL;
    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/slash.wav", 1.0, ATTN_NORM);
};

// Alt-fire — stab attack (self = player)
void() W_KnifeAltFire =
{
    if (!SH_KnifeTryStab(time))
        return;

    if (W_KnifeAltFireWouldHit())
        self.weaponframe = KNIFE_STAB_HIT_START;
    else
        self.weaponframe = KNIFE_STAB_MISS_START;

    self.wep_nextframe = time + KNIFE_FRAME_INTERVAL;
    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/stab.wav", 1.0, ATTN_NORM);
    PlayerModelPlayPrimaryAttack();
};

// Frame — advances animation, triggers hit detection (self = player)
void() W_KnifeFrame =
{
    self.weaponframe   = self.weaponframe + 1;
    self.wep_nextframe += KNIFE_FRAME_INTERVAL;

    // Server-only: play deploy sound at specific frame
    if (self.weaponstate == WS_DRAW && self.weaponframe == KNIFE_DRAW_SOUND_FRAME)
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/deploy.wav", 1.0, ATTN_NORM);

    // Server-only: hit detection at specific frames
    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == KNIFE_FIRE1_HIT_FRAME || self.weaponframe == KNIFE_FIRE2_HIT_FRAME)
            W_KnifeSlashStrike();
    }
    if (self.weaponstate == WS_SPECIAL)
    {
        if (self.weaponframe == KNIFE_STAB_HIT_FRAME || self.weaponframe == KNIFE_STAB_MISS_FRAME)
            W_KnifeStabStrike();
    }

    // Shared state transitions — handles all → idle
    if (SH_KnifeTickState(time) & 1)
    {
        self.weaponframe   = 0;
        self.wep_nextframe = 0;
    }
};

// World entity — spawned from map (classname "weapon_knife")
void() weapon_knife =
{
    setmodel(self, "models/weapons/wpn_csknife/w_knife.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname   = "weapon_knife";
    self.solid       = SOLID_TRIGGER;
    self.movetype    = MOVETYPE_TOSS;
    self.weapon      = WEP_KNIFE;
    self.weapon_slot = SLOT_MELEE;
    self.weap_draw   = W_KnifeEquip;
    self.weap_drop_func = W_KnifeDrop;
    self.pickupcopy  = W_KnifePickupCopy;
    self.touch       = weapon_touch;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

// Predict knife actions for this input command.
// Called from CSQC_PredictWeaponCommand dispatcher.
void() CSQC_PredictKnifeCommand =
{
    // Knife has no ammo — replay would cause infinite re-fires since
    // there's nothing to deplete.  Skip everything during replay;
    // only live prediction drives knife state.  Server reconciliation
    // corrects via the normal proxy snapshot.
    if (pm_suppress_sounds)
        return;

    if ((input_buttons & 1) && SH_KnifeTrySlash(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        localsound("sounds/weapons/wpn_csknife/slash.wav");
        CSQC_RecordPredictedWeaponSound();
    }
    else if ((input_buttons & 4) && SH_KnifeTryStab(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        localsound("sounds/weapons/wpn_csknife/stab.wav");
        CSQC_RecordPredictedWeaponSound();
    }

    SH_KnifeTickState(csqc_pred_time);
};

// Returns fractional display frame for viewmodel interpolation.
// Called from CSQC_GetWeaponDisplayFrame dispatcher.
float(float elapsed) CSQC_KnifeDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = KNIFE_DRAW_START + elapsed / KNIFE_FRAME_INTERVAL;
        return bound(KNIFE_DRAW_START, frame, KNIFE_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Use wep_anim_start to deterministically pick fire1 or fire2
        // (same start time = same variant for the whole animation)
        if (floor(predicted_player.wep_anim_start * 100) & 1)
        {
            frame = KNIFE_FIRE1_START + elapsed / KNIFE_FRAME_INTERVAL;
            return bound(KNIFE_FIRE1_START, frame, KNIFE_FIRE1_END - 1);
        }
        else
        {
            frame = KNIFE_FIRE2_START + elapsed / KNIFE_FRAME_INTERVAL;
            return bound(KNIFE_FIRE2_START, frame, KNIFE_FIRE2_END - 1);
        }
    }
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        frame = KNIFE_STAB_HIT_START + elapsed / KNIFE_FRAME_INTERVAL;
        return bound(KNIFE_STAB_HIT_START, frame, KNIFE_STAB_MISS_END - 1);
    }
    return 0;
};

void() CSQC_KnifeDropClear =
{
};

void() CSQC_KnifeEquip =
{
	self.weapon_name         = KNIFE_DISPLAY_NAME;
	self.weapon_viewmodel    = KNIFE_VIEWMODEL;
	self.weapon_worldmodel   = KNIFE_WORLDMODEL;
	self.weapon_deploy_sound = KNIFE_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictKnifeCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_KnifeDisplayFrame;
	self.csqc_drop_clear     = CSQC_KnifeDropClear;
};

#endif // CSQC
