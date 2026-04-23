// ============================================================
//  shared/weapons/sh_wpn_csusp.qc  -  CS 1.6 USP-45 (GoldSrc MDL)
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 12-round magazine, 24 reserve, semi-auto, .45 ACP
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : silencer toggle (WS_SPECIAL)
//
//  This is the first nettest weapon that uses a GoldSrc-format
//  .mdl viewmodel. GoldSrc viewmodels are SEQUENCE-driven, not
//  frame-driven: setting self.weaponframe = N tells FTE to play
//  sequence N as a whole, and the engine animates it internally.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo & state fields ---
.float mag_csusp;
.float ammo_csusp;
.float csusp_silenced;        // 0 = unsilenced, 1 = silenced (predicted, client-authoritative)

// --- Reload sound stage tracker (server-side, mirrored in CSQC by csqc_csusp_snd_stage) ---
.float csusp_snd_stage;

// --- v_usp.mdl sequence indices ---
//  Unsilenced
const float CSUSP_SEQ_IDLE_U      = 8;
const float CSUSP_SEQ_SHOOT1_U    = 9;
const float CSUSP_SEQ_SHOOT2_U    = 10;
const float CSUSP_SEQ_SHOOT3_U    = 11;
const float CSUSP_SEQ_SHOOTLAST_U = 12;
const float CSUSP_SEQ_RELOAD_U    = 13;
const float CSUSP_SEQ_DRAW_U      = 14;
//  Silenced
const float CSUSP_SEQ_IDLE_S      = 0;
const float CSUSP_SEQ_SHOOT1_S    = 1;
const float CSUSP_SEQ_SHOOT2_S    = 2;
const float CSUSP_SEQ_SHOOT3_S    = 3;
const float CSUSP_SEQ_SHOOTLAST_S = 4;
const float CSUSP_SEQ_RELOAD_S    = 5;
const float CSUSP_SEQ_DRAW_S      = 6;
//  Silencer toggle
const float CSUSP_SEQ_ATTACH_SIL  = 7;
const float CSUSP_SEQ_DETACH_SIL  = 15;

// --- State durations (seconds) ---
// Tuned to roughly match the v_usp.mdl sequence lengths from CS 1.6.
// Adjust these if the on-screen animation feels truncated or laggy.
const float CSUSP_DRAW_DURATION     = 1.02;
const float CSUSP_FIRE_DURATION     = 1.03;
const float CSUSP_RELOAD_DURATION   = 2.73;
const float CSUSP_RELOAD_APPLY_TIME = 2.0;
const float CSUSP_SILENCER_DURATION = 3.14;

const float CSUSP_FIRE_DELAY        = 0.15;
const float CSUSP_DRYFIRE_DELAY     = 0.2;

// How often W_CSUSPFrame runs while a non-idle state is active.
// Sequence-driven, so this only ticks the state machine (no frame stepping).
const float CSUSP_FRAME_INTERVAL    = 0.05;

// Reload sound timings (elapsed since reload start)
const float CSUSP_RELOAD_CLIPOUT_TIME = 0.50;
const float CSUSP_RELOAD_CLIPIN_TIME  = 1.40;
const float CSUSP_RELOAD_SLIDE_TIME   = 2.20;

// Draw sound timing (elapsed since draw start)
const float CSUSP_DRAW_SLIDE_TIME     = 0.85;

// Silencer toggle sound timing (elapsed since toggle start)
const float CSUSP_SILENCER_SWAP_TIME  = 1.0;

const float MAX_MAG_CSUSP             = 12;
const float MAX_AMMO_CSUSP            = 24;

// --- Balance ---
const float CSUSP_BASE_SPREAD              = 0.006;
const float CSUSP_MOVE_SPREAD              = 0.05;
const float CSUSP_FULL_SPREAD_SPEED        = 320;
const float CSUSP_CLOSE_DAMAGE             = 34;
const float CSUSP_MIN_DAMAGE               = 12;
const float CSUSP_SILENCED_CLOSE_DAMAGE    = 28;
const float CSUSP_SILENCED_MIN_DAMAGE      = 10;
const float CSUSP_DAMAGE_FALLOFF_RANGE     = 2048;

const string CSUSP_VIEWMODEL    = "models/weapons/wpn_csusp/v_usp.mdl";
const string CSUSP_WORLDMODEL   = "models/weapons/wpn_csusp/w_usp.mdl";
const string CSUSP_DEPLOY_SOUND = "";
const string CSUSP_DISPLAY_NAME = "USP-45";

// ============================================================
//  SHARED — sequence-pick helpers
// ============================================================

// Returns the silenced or unsilenced variant of a sequence based on csusp_silenced.
// Pass the unsilenced sequence as the base; the matching silenced index is base - 8.
float(float unsil_seq) SH_CSUSPSeq =
{
    if (self.csusp_silenced)
        return unsil_seq - 8;
    return unsil_seq;
};

// Pick a shoot sequence deterministically from wep_action_id so the
// client and server agree on which animation to play.
// Returns SHOOTLAST when this is the last round in the magazine — the
// sequence visually leaves the slide locked back, matching CS 1.6.
float(float mag_after) SH_CSUSPPickShootSeq =
{
    float r;
    if (mag_after <= 0)
        return SH_CSUSPSeq(CSUSP_SEQ_SHOOTLAST_U);

    r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return SH_CSUSPSeq(CSUSP_SEQ_SHOOT1_U);
    if (r < 0.67) return SH_CSUSPSeq(CSUSP_SEQ_SHOOT2_U);
    return SH_CSUSPSeq(CSUSP_SEQ_SHOOT3_U);
};

// Idle sequence — slide-locked-back when mag is empty, normal idle otherwise.
float() SH_CSUSPIdleSeq =
{
    if (self.mag_csusp <= 0)
        return SH_CSUSPSeq(CSUSP_SEQ_SHOOTLAST_U);
    return SH_CSUSPSeq(CSUSP_SEQ_IDLE_U);
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSUSPTickState =
{
    float elapsed;

    // WS_SPECIAL — silencer toggle. Flip the silenced flag mid-anim
    // so the post-toggle idle and the next fire use the new sequences.
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= CSUSP_SILENCER_DURATION)
        {
            self.csusp_silenced = !self.csusp_silenced;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return SH_StandardTickState(now, mag_csusp, ammo_csusp, MAX_MAG_CSUSP,
        CSUSP_DRAW_DURATION, CSUSP_FIRE_DURATION,
        CSUSP_RELOAD_DURATION, CSUSP_RELOAD_APPLY_TIME);
};

float(float now) SH_CSUSPTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_csusp, CSUSP_FIRE_DELAY, CSUSP_DRYFIRE_DELAY);
};

float(float now) SH_CSUSPTryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_csusp, ammo_csusp, MAX_MAG_CSUSP, CSUSP_RELOAD_DURATION);
};

float(float now) SH_CSUSPTryAltFire =
{
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + CSUSP_SILENCER_DURATION;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CSUSPPickupCopy =
{
    player.mag_csusp     = self.mag_csusp;
    player.ammo_csusp    = self.ammo_csusp;
    player.csusp_silenced = self.csusp_silenced;
};

void() W_CSUSPShoot =
{
    float close_dmg, min_dmg;
    if (self.csusp_silenced)
    {
        close_dmg = CSUSP_SILENCED_CLOSE_DAMAGE;
        min_dmg   = CSUSP_SILENCED_MIN_DAMAGE;
    }
    else
    {
        close_dmg = CSUSP_CLOSE_DAMAGE;
        min_dmg   = CSUSP_MIN_DAMAGE;
    }
    W_PenetratingHitscanShoot(CSUSP_BASE_SPREAD, CSUSP_MOVE_SPREAD, CSUSP_FULL_SPREAD_SPEED,
        close_dmg, min_dmg, CSUSP_DAMAGE_FALLOFF_RANGE, 16, 0.95);
};

void() W_CSUSPFire =
{
    float r = SH_CSUSPTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CSUSPPickShootSeq(self.mag_csusp);
        self.wep_nextframe = time + CSUSP_FRAME_INTERVAL;
        self.csusp_snd_stage = 0;

        W_CSUSPShoot();
        if (self.csusp_silenced)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csusp/sfire.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csusp/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSUSPReload =
{
    if (SH_CSUSPTryReload(time))
    {
        self.weaponframe   = SH_CSUSPSeq(CSUSP_SEQ_RELOAD_U);
        self.wep_nextframe = time + CSUSP_FRAME_INTERVAL;
        self.csusp_snd_stage = 0;
    }
};

void() W_CSUSPAltFire =
{
    if (SH_CSUSPTryAltFire(time))
    {
        // Sequence to play depends on the OLD silenced state — going from
        // unsilenced→silenced plays the attach animation; reverse plays detach.
        if (self.csusp_silenced)
            self.weaponframe = CSUSP_SEQ_DETACH_SIL;
        else
            self.weaponframe = CSUSP_SEQ_ATTACH_SIL;
        self.wep_nextframe = time + CSUSP_FRAME_INTERVAL;
        self.csusp_snd_stage = 0;
    }
};

void() W_CSUSPFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — we do NOT step weaponframe per tick.
    // We only fire timed sound events and run the tick state machine.
    self.wep_nextframe += CSUSP_FRAME_INTERVAL;

    // Server-side sound triggers — use CHAN_AUTO so the predicted-sound
    // dedup window matches CSQC_RecordPredictedAutoSound on the client.
    // Using CHAN_WEAPON here would collide with the fire-sound dedup window.
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CSUSP_DRAW_SLIDE_TIME && self.csusp_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csusp/slideback.wav", 1, ATTN_NORM);
            self.csusp_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CSUSP_RELOAD_CLIPOUT_TIME && self.csusp_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csusp/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.csusp_snd_stage = 1;
        }
        if (elapsed >= CSUSP_RELOAD_CLIPIN_TIME && self.csusp_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csusp/clipin.wav", 1, ATTN_NORM);
            self.csusp_snd_stage = 2;
        }
        if (elapsed >= CSUSP_RELOAD_SLIDE_TIME && self.csusp_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csusp/sliderelease.wav", 1, ATTN_NORM);
            self.csusp_snd_stage = 3;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= CSUSP_SILENCER_SWAP_TIME && self.csusp_snd_stage < 1)
        {
            // self.csusp_silenced is still the OLD value here (gets flipped in tick state)
            if (self.csusp_silenced)
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_csusp/silenceroff.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_csusp/silenceron.wav", 1, ATTN_NORM);
            self.csusp_snd_stage = 1;
        }
    }

    result = SH_CSUSPTickState(time);
    if (result & 1)
    {
        self.weaponframe   = SH_CSUSPIdleSeq();
        self.wep_nextframe = 0;
        self.csusp_snd_stage = 0;
    }
};

void() W_CSUSPEquip =
{
    W_StandardEquipSetup(CSUSP_VIEWMODEL, CSUSP_DISPLAY_NAME, SH_CSUSPSeq(CSUSP_SEQ_DRAW_U),
        CSUSP_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSUSPFire;
    self.reload   = W_CSUSPReload;
    self.altfire  = W_CSUSPAltFire;
    self.wepframe = W_CSUSPFrame;
    self.shoot    = W_CSUSPShoot;
    self.csusp_snd_stage = 0;
    W_SetCrosshairProfile(CSUSP_BASE_SPREAD, CSUSP_MOVE_SPREAD, CSUSP_FULL_SPREAD_SPEED, 1.5, TRUE);
};

// GoldSrc world models have their pivot at a hand/grip bone, not at the
// model's geometric center. setmodel here, then shift .origin so the
// model's natural center sits on the desired drop point, and compensate
// the touch hull via setsize so it stays anchored to the same world
// position. After this call the entity is ready: visible model is
// centered on the original .origin, touch hull spans the original
// drop point ± hull_mins/hull_maxs.
void(vector hull_mins, vector hull_maxs) W_CSUSPSetupWorldEntity =
{
    vector desired = self.origin;
    setmodel(self, CSUSP_WORLDMODEL);

    vector mdl_center = (self.mins + self.maxs) * 0.5;

    setorigin(self, desired - mdl_center);
    setsize(self, hull_mins + mdl_center, hull_maxs + mdl_center);
};

void() W_CSUSPDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_csusp      = self.mag_csusp;
    tgt.ammo_csusp     = self.ammo_csusp;
    tgt.csusp_silenced = self.csusp_silenced;

    self.mag_csusp      = 0;
    self.ammo_csusp     = 0;
    self.csusp_silenced = 0;

    entity old_self = self;
    self = tgt;
    W_CSUSPSetupWorldEntity('-12 -12 0', '12 12 24');
    self = old_self;

    tgt.classname    = "weapon_csusp";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_CSUSP;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_CSUSPEquip;
    tgt.weap_drop_func = W_CSUSPDrop;
    tgt.pickupcopy   = W_CSUSPPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_csusp =
{
    W_CSUSPSetupWorldEntity('-12 -12 0', '12 12 24');
    self.classname     = "weapon_csusp";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CSUSP;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_CSUSPEquip;
    self.weap_drop_func = W_CSUSPDrop;
    self.pickupcopy    = W_CSUSPPickupCopy;
    self.touch         = weapon_touch;
    self.mag_csusp     = MAX_MAG_CSUSP;
    self.ammo_csusp    = MAX_AMMO_CSUSP;
    self.csusp_silenced = 0;
    W_RegisterMapWeapon(weapon_csusp);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_csusp_snd_stage;
float csqc_csusp_snd_action;   // wep_action_id of the action this stage belongs to

void() CSQC_PredictCSUSPCommand =
{
    float r;
    float elapsed;

    // Reset the predicted-sound stage when we enter a new weapon action.
    // This is gated on wep_action_id (incremented by every state transition)
    // rather than equip, so snapshot reconciliation can re-call equip without
    // wiping mid-action sound state.
    if (predicted_player.wep_action_id != csqc_csusp_snd_action)
    {
        csqc_csusp_snd_action = predicted_player.wep_action_id;
        csqc_csusp_snd_stage  = 0;
    }

    // Try fire
    if (input_buttons & 1)
    {
        r = SH_CSUSPTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (self.csusp_silenced)
                    localsound("sounds/weapons/wpn_csusp/sfire.wav");
                else
                    localsound("sounds/weapons/wpn_csusp/fire.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(CSUSP_BASE_SPREAD, CSUSP_MOVE_SPREAD, CSUSP_FULL_SPREAD_SPEED,
                    self.csusp_silenced ? CSUSP_SILENCED_CLOSE_DAMAGE : CSUSP_CLOSE_DAMAGE,
                    self.csusp_silenced ? CSUSP_SILENCED_MIN_DAMAGE   : CSUSP_MIN_DAMAGE,
                    CSUSP_DAMAGE_FALLOFF_RANGE);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
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

    // Try alt-fire (silencer toggle)
    if (input_buttons & 4)
    {
        if (SH_CSUSPTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_csusp_snd_stage = 0;
        }
    }

    // Predicted draw / reload / silencer-toggle sounds
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_csusp_snd_stage < 1 && elapsed >= CSUSP_DRAW_SLIDE_TIME)
            {
                localsound("sounds/weapons/wpn_csusp/slideback.wav"); CSQC_RecordPredictedAutoSound();
                csqc_csusp_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_csusp_snd_stage < 1 && elapsed >= CSUSP_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_csusp/clipout.wav"); CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_csusp_snd_stage = 1;
            }
            if (csqc_csusp_snd_stage < 2 && elapsed >= CSUSP_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_csusp/clipin.wav"); CSQC_RecordPredictedAutoSound();
                csqc_csusp_snd_stage = 2;
            }
            if (csqc_csusp_snd_stage < 3 && elapsed >= CSUSP_RELOAD_SLIDE_TIME)
            {
                localsound("sounds/weapons/wpn_csusp/sliderelease.wav"); CSQC_RecordPredictedAutoSound();
                csqc_csusp_snd_stage = 3;
            }
        }
        else if (self.weaponstate == WS_SPECIAL)
        {
            if (csqc_csusp_snd_stage < 1 && elapsed >= CSUSP_SILENCER_SWAP_TIME)
            {
                if (self.csusp_silenced)
                    localsound("sounds/weapons/wpn_csusp/silenceroff.wav");
                else
                    localsound("sounds/weapons/wpn_csusp/silenceron.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_csusp_snd_stage = 1;
            }
        }
    }

    SH_CSUSPTickState(csqc_pred_time);
};

void() CSQC_PredictCSUSPReload =
{
    if (SH_CSUSPTryReload(csqc_pred_time))
    {
        csqc_csusp_snd_stage  = 0;
        csqc_csusp_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly, FTE animates the sequence.
// All branches read from predicted_player so the render path stays consistent.
float(float elapsed) CSQC_CSUSPDisplayFrame =
{
    float silenced = predicted_player.csusp_silenced;
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        if (silenced) return CSUSP_SEQ_DRAW_S;
        return CSUSP_SEQ_DRAW_U;
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Empty mag → shoot-last (slide locks back).
        if (predicted_player.mag_csusp <= 0)
        {
            if (silenced) return CSUSP_SEQ_SHOOTLAST_S;
            return CSUSP_SEQ_SHOOTLAST_U;
        }
        // Otherwise pick deterministically from wep_action_id so client and
        // server agree on which of shoot1/2/3 plays for this exact shot.
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (silenced)
        {
            if (r < 0.34) return CSUSP_SEQ_SHOOT1_S;
            if (r < 0.67) return CSUSP_SEQ_SHOOT2_S;
            return CSUSP_SEQ_SHOOT3_S;
        }
        if (r < 0.34) return CSUSP_SEQ_SHOOT1_U;
        if (r < 0.67) return CSUSP_SEQ_SHOOT2_U;
        return CSUSP_SEQ_SHOOT3_U;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        if (silenced) return CSUSP_SEQ_RELOAD_S;
        return CSUSP_SEQ_RELOAD_U;
    }
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // csusp_silenced is the OLD value during the toggle anim (flipped on completion).
        if (silenced) return CSUSP_SEQ_DETACH_SIL;
        return CSUSP_SEQ_ATTACH_SIL;
    }

    // Idle — slide-locked-back when empty.
    if (predicted_player.mag_csusp <= 0)
    {
        if (silenced) return CSUSP_SEQ_SHOOTLAST_S;
        return CSUSP_SEQ_SHOOTLAST_U;
    }
    if (silenced) return CSUSP_SEQ_IDLE_S;
    return CSUSP_SEQ_IDLE_U;
};

void() CSQC_CSUSPDropClear =
{
    self.mag_csusp      = 0;
    self.ammo_csusp     = 0;
    self.csusp_silenced = 0;
};

void() CSQC_CSUSPEquip =
{
    self.weapon_name         = CSUSP_DISPLAY_NAME;
    self.weapon_viewmodel    = CSUSP_VIEWMODEL;
    self.weapon_worldmodel   = CSUSP_WORLDMODEL;
    self.weapon_deploy_sound = CSUSP_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSUSPCommand;
    self.csqc_predict_reload = CSQC_PredictCSUSPReload;
    self.csqc_display_frame  = CSQC_CSUSPDisplayFrame;
    self.csqc_drop_clear     = CSQC_CSUSPDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
