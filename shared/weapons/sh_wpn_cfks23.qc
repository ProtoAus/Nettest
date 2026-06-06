// ============================================================
//  shared/weapons/sh_wpn_cfks23.qc  -  CF KS-23 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 3-shell tube, 12 reserve, pump-action 23mm shotgun.
//  Fire  : 10-pellet hitscan, big-bore — high close damage, slow pump.
//          Shell-by-shell reload (reload_0 -> reload_1 per shell -> reload_2).
//
//  Sequence layout (v_ks23.mdl):
//      0  idle_0    30 fps
//      1  prefire1  30 fps  (blowback/pump @ 12)
//      2  prefire2  30 fps
//      3  reload_1  30 fps  (shell insert @ 2)
//      4  reload_2  30 fps  (pump close @ 1)
//      5  reload_0  30 fps  (idle between)
//      6  select    30 fps
//
//  Sounds in sounds/weapons/wpn_cfks23/: fire/draw/clipin/blowback/reload.
// ============================================================

.float mag_cfks23;
.float ammo_cfks23;

.float cfks23_draw_snd_played;
.float cfks23_reload_snd_stage;
.float cfks23_post_fire_blow_played;
.float cfks23_reload_shells_at_start;
.float cfks23_reload_shells_done;
.float cfks23_reload_phase;

const float CFKS23_SEQ_IDLE     = 0;
const float CFKS23_SEQ_SHOOT1   = 1;
const float CFKS23_SEQ_SHOOT2   = 2;
const float CFKS23_SEQ_RELOAD_1 = 3;
const float CFKS23_SEQ_RELOAD_2 = 4;
const float CFKS23_SEQ_RELOAD_0 = 5;
const float CFKS23_SEQ_DRAW     = 6;

const float CFKS23_RELOAD_SHELLIN_TIME = 0.067;   // reload_1 shell-in @ 2/30
const float CFKS23_RELOAD_PUMP_TIME    = 0.033;   // reload_2 pump close @ 1/30
const float CFKS23_DRAW_CLACK_TIME     = 0.050;   // select draw clack
const float CFKS23_POST_FIRE_BLOW_TIME = 0.400;   // prefire blowback @ 12/30
const float CFKS23_RELOAD_APPLY_TIME   = 0.10;

const float CFKS23_FIRE_DELAY        = 0.90;   // heavy pump cycle
const float CFKS23_DRYFIRE_DELAY     = 0.20;
const float CFKS23_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFKS23           = 3;
const float MAX_AMMO_CFKS23          = 12;

const float CFKS23_PELLETS              = 10;
const float CFKS23_SPREAD               = 0.135;
const float CFKS23_PELLET_CLOSE_DAMAGE  = 30;    // 23mm big bore — heavy
const float CFKS23_PELLET_MIN_DAMAGE    = 7;
const float CFKS23_DAMAGE_FALLOFF_RANGE = 1024;
const float CFKS23_KICK_PITCH    = 3.2;
const float CFKS23_KICK_VARIANCE = 0.7;
const float CFKS23_KICK_STRENGTH = 1.9;

// Muzzle attachment — from v_ks23.mdl's $attachment 0:
//     $attachment 0 "Box001" 0.0 0.0 24.0
const string CFKS23_MUZZLE_BONE   = "Box001";
#define CFKS23_MUZZLE_OFFSET ('0.0 0.0 24.0')

const string CFKS23_VIEWMODEL    = "models/weapons/wpn_cfks23/v_ks23.mdl";
const string CFKS23_WORLDMODEL   = "models/weapons/wpn_cfks23/w_ks23.mdl";
const string CFKS23_DEPLOY_SOUND = "";
const string CFKS23_DISPLAY_NAME = "KS-23";

// ============================================================
//  SHARED — sequence pick + shell-by-shell state machine
// ============================================================

float() SH_CFKs23PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFKS23_SEQ_SHOOT1;
    return CFKS23_SEQ_SHOOT2;
};

float(float now) SH_CFKs23TickState =
{
    if (self.weaponstate == WS_RELOAD)
        return 0;
    return SH_StandardTickState(now, mag_cfks23, ammo_cfks23, MAX_MAG_CFKS23,
        SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_DRAW,     1.0),
        SH_SeqDuration(CFKS23_VIEWMODEL, self.weaponframe,    0.9),
        SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_RELOAD_1, 1.0),
        CFKS23_RELOAD_APPLY_TIME);
};

float(float now) SH_CFKs23ReloadTick =
{
    if (self.weaponstate != WS_RELOAD)
        return 0;

    float elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    float shells_needed = self.cfks23_reload_shells_at_start;
    float result = 0;

    if (shells_needed <= 0)
    {
        if (self.cfks23_reload_phase != 2)
        {
            self.cfks23_reload_phase = 2;
            self.weaponframe         = CFKS23_SEQ_RELOAD_2;
            self.wep_anim_start      = now;
            elapsed                  = 0;
        }
        float dur_2 = SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2)
        {
            self.weaponstate               = WS_IDLE;
            self.weaponframe               = CFKS23_SEQ_IDLE;
            self.wep_nextframe             = 0;
            self.wep_anim_start            = 0;
            self.cfks23_reload_phase       = 0;
            self.cfks23_reload_shells_done = 0;
            self.cfks23_reload_snd_stage   = 0;
            return 1;
        }
        return 0;
    }

    if (self.cfks23_reload_phase == 0)
    {
        float dur_0 = SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_RELOAD_0, 0.4);
        if (elapsed >= dur_0)
        {
            self.cfks23_reload_phase     = 1;
            self.weaponframe             = CFKS23_SEQ_RELOAD_1;
            self.wep_anim_start          = now;
            self.cfks23_reload_snd_stage = 0;
        }
        return 0;
    }

    if (self.cfks23_reload_phase == 1)
    {
        float dur_1 = SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_RELOAD_1, 1.0);
        if (elapsed >= dur_1)
        {
            self.cfks23_reload_shells_done += 1;
            self.mag_cfks23  += 1;
            self.ammo_cfks23 -= 1;
            result = result | 2;

            if (self.cfks23_reload_shells_done < shells_needed)
            {
                self.wep_anim_start          = now;
                self.cfks23_reload_snd_stage = 0;
            }
            else
            {
                self.cfks23_reload_phase     = 2;
                self.weaponframe             = CFKS23_SEQ_RELOAD_2;
                self.wep_anim_start          = now;
                self.cfks23_reload_snd_stage = 0;
            }
        }
        return result;
    }

    if (self.cfks23_reload_phase == 2)
    {
        float dur_2_close = SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2_close)
        {
            self.weaponstate               = WS_IDLE;
            self.weaponframe               = CFKS23_SEQ_IDLE;
            self.wep_nextframe             = 0;
            self.wep_anim_start            = 0;
            self.cfks23_reload_phase       = 0;
            self.cfks23_reload_shells_done = 0;
            self.cfks23_reload_snd_stage   = 0;
            result = result | 1;
        }
    }
    return result;
};

float(float now) SH_CFKs23TryFire =
{
    return SH_StandardTryFire(now, mag_cfks23, CFKS23_FIRE_DELAY, CFKS23_DRYFIRE_DELAY);
};

float(float now) SH_CFKs23TryReload =
{
    float dur_hint = SH_SeqDuration(CFKS23_VIEWMODEL, CFKS23_SEQ_RELOAD_1, 1.0);
    float r = SH_StandardTryReload(now, mag_cfks23, ammo_cfks23, MAX_MAG_CFKS23, dur_hint);
    if (r)
    {
        float shells = MAX_MAG_CFKS23 - self.mag_cfks23;
        if (shells > self.ammo_cfks23) shells = self.ammo_cfks23;
        self.cfks23_reload_shells_at_start = shells;
        self.cfks23_reload_shells_done     = 0;
        self.cfks23_reload_phase           = 0;
        self.weaponframe                   = CFKS23_SEQ_RELOAD_0;
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFKs23PickupCopy =
{
    player.mag_cfks23  = self.mag_cfks23;
    player.ammo_cfks23 = self.ammo_cfks23;
};

void() W_CFKs23Shoot =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    SH_ApplyViewKick(CFKS23_KICK_PITCH, CFKS23_KICK_VARIANCE, CFKS23_KICK_STRENGTH);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    for (i = 0; i < CFKS23_PELLETS; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * CFKS23_SPREAD;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * CFKS23_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist,
                CFKS23_PELLET_CLOSE_DAMAGE, CFKS23_PELLET_MIN_DAMAGE,
                CFKS23_DAMAGE_FALLOFF_RANGE);
            if (W_CanDamageTarget(trace_ent))
            {
                if (trace_ent.classname == "player")
                    trace_ent.death_hitgroup = W_BoneToHitgroup(trace_bone_id);
                W_ApplyDamage(self, trace_ent, damage);
                if (trace_ent.classname == "player")
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
                else
                {
                    float bmat = W_ClassifyImpactMaterial(trace_ent);
                    if (bmat == IMPACT_MAT_FLESH && trace_ent.health <= 0)
                        bmat = IMPACT_MAT_FLESH_LETHAL;
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, bmat);
                }
            }
            else
            {
                PhysProp_TryPushFromTrace(dir, damage);
                W_ImpactEffect(trace_endpos);
            }
            W_DebugImpact(trace_endpos, damage, W_BoneToHitgroup(trace_bone_id));
        }
    }
};

void() W_CFKs23Fire =
{
    float r = SH_CFKs23TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFKs23PickShootSeq();
        self.wep_nextframe = time + CFKS23_FRAME_INTERVAL;
        self.cfks23_post_fire_blow_played = 0;

        W_CFKs23Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfks23/fire.WAV", 2, ATTN_NORM);
        W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFKs23Reload =
{
    if (SH_CFKs23TryReload(time))
    {
        self.wep_nextframe = time + CFKS23_FRAME_INTERVAL;
        self.cfks23_reload_snd_stage = 0;
    }
};

void() W_CFKs23Frame =
{
    float result = 0;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFKS23_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFKS23_DRAW_CLACK_TIME && !self.cfks23_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfks23/draw.WAV", 1, ATTN_NORM);
            self.cfks23_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // Post-fire pump rack (prefire blowback event @ 12/30).
        if (elapsed >= CFKS23_POST_FIRE_BLOW_TIME && !self.cfks23_post_fire_blow_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfks23/blowback.WAV", 1, ATTN_NORM);
            self.cfks23_post_fire_blow_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (self.cfks23_reload_phase == 1
            && self.cfks23_reload_snd_stage < 1
            && elapsed >= CFKS23_RELOAD_SHELLIN_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfks23/clipin.WAV", 1, ATTN_NORM);
            self.cfks23_reload_snd_stage = 1;
        }
        else if (self.cfks23_reload_phase == 2
            && self.cfks23_reload_snd_stage < 1
            && elapsed >= CFKS23_RELOAD_PUMP_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfks23/reload.WAV", 1, ATTN_NORM);
            self.cfks23_reload_snd_stage = 1;
        }
    }

    if (self.weaponstate == WS_RELOAD)
        result = SH_CFKs23ReloadTick(time);
    else
        result = SH_CFKs23TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFKS23_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfks23_reload_snd_stage = 0;
    }
};

void() W_CFKs23Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ks23", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFKS23_VIEWMODEL, CFKS23_DISPLAY_NAME, CFKS23_SEQ_DRAW,
        CFKS23_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFKs23Fire;
    self.reload   = W_CFKs23Reload;
    self.wepframe = W_CFKs23Frame;
    self.shoot    = W_CFKs23Shoot;
    self.cfks23_draw_snd_played        = 0;
    self.cfks23_reload_snd_stage       = 0;
    self.cfks23_reload_shells_at_start = 0;
    self.cfks23_reload_shells_done     = 0;
    self.cfks23_reload_phase           = 0;
    W_SetCrosshairProfile(CFKS23_SPREAD, 0, 320, 3, TRUE);
};

void() W_CFKs23Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfks23  = self.mag_cfks23;
    tgt.ammo_cfks23 = self.ammo_cfks23;

    self.mag_cfks23  = 0;
    self.ammo_cfks23 = 0;

    setmodel(tgt, CFKS23_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfks23";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFKS23;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFKs23Equip;
    tgt.weap_drop_func = W_CFKs23Drop;
    tgt.pickupcopy    = W_CFKs23PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfks23 =
{
    setmodel(self, CFKS23_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_cfks23";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFKS23;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFKs23Equip;
    self.weap_drop_func = W_CFKs23Drop;
    self.pickupcopy    = W_CFKs23PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfks23    = MAX_MAG_CFKS23;
    self.ammo_cfks23   = MAX_AMMO_CFKS23;
    W_RegisterMapWeapon(weapon_cfks23);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfks23_draw_snd_played;
float csqc_cfks23_reload_snd_stage;
float csqc_cfks23_post_fire_blow_played;
float csqc_cfks23_snd_action;

void() CSQC_PredictCFKs23Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfks23_snd_action)
    {
        csqc_cfks23_snd_action       = predicted_player.wep_action_id;
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfks23_draw_snd_played  = 0;
        csqc_cfks23_reload_snd_stage = 0;
        csqc_cfks23_post_fire_blow_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFKs23TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfks23/fire.WAV", 2, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(CFKS23_PELLETS, CFKS23_SPREAD,
                    CFKS23_PELLET_CLOSE_DAMAGE, CFKS23_PELLET_MIN_DAMAGE,
                    CFKS23_DAMAGE_FALLOFF_RANGE,
                    CFKS23_KICK_PITCH, CFKS23_KICK_VARIANCE, CFKS23_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFKS23_MUZZLE_BONE, CFKS23_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, CFKS23_PELLETS);
                CSQC_EndFireActionEffects();
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

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfks23_draw_snd_played && elapsed >= CFKS23_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfks23/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfks23_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            if (!csqc_cfks23_post_fire_blow_played && elapsed >= CFKS23_POST_FIRE_BLOW_TIME)
            {
                localsound("sounds/weapons/wpn_cfks23/blowback.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfks23_post_fire_blow_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (self.cfks23_reload_phase == 1
                && self.cfks23_reload_snd_stage < 1
                && elapsed >= CFKS23_RELOAD_SHELLIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfks23/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfks23_reload_snd_stage = 1;
            }
            else if (self.cfks23_reload_phase == 2
                && self.cfks23_reload_snd_stage < 1
                && elapsed >= CFKS23_RELOAD_PUMP_TIME)
            {
                localsound("sounds/weapons/wpn_cfks23/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfks23_reload_snd_stage = 1;
            }
        }
    }

    if (self.weaponstate == WS_RELOAD)
        SH_CFKs23ReloadTick(csqc_pred_time);
    SH_CFKs23TickState(csqc_pred_time);
};

void() CSQC_PredictCFKs23Reload =
{
    if (SH_CFKs23TryReload(csqc_pred_time))
    {
        csqc_cfks23_reload_snd_stage = 0;
        csqc_cfks23_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFKs23DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFKS23_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFKS23_SEQ_SHOOT1;
        return CFKS23_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        if (predicted_player.cfks23_reload_phase == 0)
            return CFKS23_SEQ_RELOAD_0;
        if (predicted_player.cfks23_reload_phase == 1)
            return CFKS23_SEQ_RELOAD_1;
        return CFKS23_SEQ_RELOAD_2;
    }

    return CFKS23_SEQ_IDLE;
};

void() CSQC_CFKs23DropClear =
{
    self.mag_cfks23  = 0;
    self.ammo_cfks23 = 0;
};

void() CSQC_CFKs23Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_ks23", SCOPE_CLASS_NONE);
    self.weapon_name         = CFKS23_DISPLAY_NAME;
    self.weapon_viewmodel    = CFKS23_VIEWMODEL;
    self.weapon_worldmodel   = CFKS23_WORLDMODEL;
    self.weapon_deploy_sound = CFKS23_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFKs23Command;
    self.csqc_predict_reload = CSQC_PredictCFKs23Reload;
    self.csqc_display_frame  = CSQC_CFKs23DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFKs23DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFKS23_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFKS23_MUZZLE_OFFSET;

    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfks23_draw_snd_played = 1;
        csqc_cfks23_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
