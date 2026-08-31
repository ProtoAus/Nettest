// ============================================================
//  shared/weapons/sh_wpn_cfm4.qc  -  CF M4 Super 90 (GoldSrc MDL)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 7-shell tube, 32 reserve, semi-auto shotgun.
//  Fire  : 8-pellet hitscan, linear damage falloff.  Shell-by-shell
//          reload (reload_0 -> reload_1 per shell -> reload_2).
//
//  Sequence layout (v_m4.mdl):
//      0  idle_0    30 fps
//      1  prefire1  30 fps
//      2  prefire2  30 fps
//      3  reload_1  30 fps  (shell insert @ 1)
//      4  reload_2  30 fps  (pump close)
//      5  reload_0   6 fps  (idle between)
//      6  select    30 fps  (deploy @ 6)
//
//  Sounds in sounds/weapons/wpn_cfm4/: fire / reload / shellin only.
//  NO draw.WAV — deploy reuses reload.WAV (model uses G_RELOAD_XM1014).
// ============================================================

.float mag_cfm4;
.float ammo_cfm4;

.float cfm4_draw_snd_played;
.float cfm4_reload_snd_stage;
.float cfm4_reload_shells_at_start;
.float cfm4_reload_shells_done;
.float cfm4_reload_phase;

const float CFM4_SEQ_IDLE     = 0;
const float CFM4_SEQ_SHOOT1   = 1;
const float CFM4_SEQ_SHOOT2   = 2;
const float CFM4_SEQ_RELOAD_1 = 3;
const float CFM4_SEQ_RELOAD_2 = 4;
const float CFM4_SEQ_RELOAD_0 = 5;
const float CFM4_SEQ_DRAW     = 6;

const float CFM4_RELOAD_SHELLIN_TIME = 0.033;   // reload_1 shell-in @ 1/30
const float CFM4_RELOAD_PUMP_TIME    = 0.050;   // reload_2 pump close
const float CFM4_DRAW_CLACK_TIME     = 0.200;   // select @ 6/30
const float CFM4_RELOAD_APPLY_TIME   = 0.10;

const float CFM4_FIRE_DELAY        = 0.30;   // semi-auto cadence
const float CFM4_DRYFIRE_DELAY     = 0.20;
const float CFM4_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFM4           = 7;
const float MAX_AMMO_CFM4          = 32;

const float CFM4_PELLETS              = 8;
const float CFM4_SPREAD               = 0.115;
const float CFM4_PELLET_CLOSE_DAMAGE  = 24;
const float CFM4_PELLET_MIN_DAMAGE    = 5;
const float CFM4_DAMAGE_FALLOFF_RANGE = 1100;
const float CFM4_KICK_PITCH    = 2.4;
const float CFM4_KICK_VARIANCE = 0.6;
const float CFM4_KICK_STRENGTH = 1.5;

// Muzzle attachment — from v_m4.mdl's $attachment 0:
//     $attachment 0 "Bone01" 42.0 0.0 0.6
const string CFM4_MUZZLE_BONE   = "Bone01";
#define CFM4_MUZZLE_OFFSET ('42.0 0.0 0.6')

const string CFM4_VIEWMODEL    = "models/weapons/wpn_cfm4/v_m4.mdl";
const string CFM4_WORLDMODEL   = "models/weapons/wpn_cfm4/w_m4.mdl";
const string CFM4_DEPLOY_SOUND = "";
const string CFM4_DISPLAY_NAME = "M4 Super 90";

// ============================================================
//  SHARED — sequence pick + shell-by-shell state machine
// ============================================================

float() SH_CFM4PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFM4_SEQ_SHOOT1;
    return CFM4_SEQ_SHOOT2;
};

float(float now) SH_CFM4TickState =
{
    if (self.weaponstate == WS_RELOAD)
        return 0;
    return SH_StandardTickState(now, mag_cfm4, ammo_cfm4, MAX_MAG_CFM4,
        SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_DRAW,     1.0),
        SH_SeqDuration(CFM4_VIEWMODEL, self.weaponframe,  0.9),
        SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_RELOAD_1, 1.0),
        CFM4_RELOAD_APPLY_TIME);
};

float(float now) SH_CFM4ReloadTick =
{
    if (self.weaponstate != WS_RELOAD)
        return 0;

    float elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    float shells_needed = self.cfm4_reload_shells_at_start;
    float result = 0;

    if (shells_needed <= 0)
    {
        if (self.cfm4_reload_phase != 2)
        {
            self.cfm4_reload_phase = 2;
            self.weaponframe       = CFM4_SEQ_RELOAD_2;
            self.wep_anim_start    = now;
            elapsed                = 0;
        }
        float dur_2 = SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2)
        {
            self.weaponstate               = WS_IDLE;
            self.weaponframe               = CFM4_SEQ_IDLE;
            self.wep_nextframe             = 0;
            self.wep_anim_start            = 0;
            self.cfm4_reload_phase         = 0;
            self.cfm4_reload_shells_done   = 0;
            self.cfm4_reload_snd_stage     = 0;
            return 1;
        }
        return 0;
    }

    if (self.cfm4_reload_phase == 0)
    {
        float dur_0 = SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_RELOAD_0, 0.4);
        if (elapsed >= dur_0)
        {
            self.cfm4_reload_phase     = 1;
            self.weaponframe           = CFM4_SEQ_RELOAD_1;
            self.wep_anim_start        = now;
            self.cfm4_reload_snd_stage = 0;
        }
        return 0;
    }

    if (self.cfm4_reload_phase == 1)
    {
        float dur_1 = SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_RELOAD_1, 1.0);
        if (elapsed >= dur_1)
        {
            self.cfm4_reload_shells_done += 1;
            self.mag_cfm4  += 1;
            self.ammo_cfm4 -= 1;
            result = result | 2;

            if (self.cfm4_reload_shells_done < shells_needed)
            {
                self.wep_anim_start        = now;
                self.cfm4_reload_snd_stage = 0;
            }
            else
            {
                self.cfm4_reload_phase     = 2;
                self.weaponframe           = CFM4_SEQ_RELOAD_2;
                self.wep_anim_start        = now;
                self.cfm4_reload_snd_stage = 0;
            }
        }
        return result;
    }

    if (self.cfm4_reload_phase == 2)
    {
        float dur_2_close = SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2_close)
        {
            self.weaponstate               = WS_IDLE;
            self.weaponframe               = CFM4_SEQ_IDLE;
            self.wep_nextframe             = 0;
            self.wep_anim_start            = 0;
            self.cfm4_reload_phase         = 0;
            self.cfm4_reload_shells_done   = 0;
            self.cfm4_reload_snd_stage     = 0;
            result = result | 1;
        }
    }
    return result;
};

float(float now) SH_CFM4TryFire =
{
    return SH_StandardTryFire(now, mag_cfm4, CFM4_FIRE_DELAY, CFM4_DRYFIRE_DELAY);
};

float(float now) SH_CFM4TryReload =
{
    float dur_hint = SH_SeqDuration(CFM4_VIEWMODEL, CFM4_SEQ_RELOAD_1, 1.0);
    float r = SH_StandardTryReload(now, mag_cfm4, ammo_cfm4, MAX_MAG_CFM4, dur_hint);
    if (r)
    {
        float shells = MAX_MAG_CFM4 - self.mag_cfm4;
        if (shells > self.ammo_cfm4) shells = self.ammo_cfm4;
        self.cfm4_reload_shells_at_start = shells;
        self.cfm4_reload_shells_done     = 0;
        self.cfm4_reload_phase           = 0;
        self.weaponframe                 = CFM4_SEQ_RELOAD_0;
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFM4PickupCopy =
{
    player.mag_cfm4  = self.mag_cfm4;
    player.ammo_cfm4 = self.ammo_cfm4;
};

void() W_CFM4Shoot =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    SH_ApplyViewKick(CFM4_KICK_PITCH, CFM4_KICK_VARIANCE, CFM4_KICK_STRENGTH);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    // Tag every impact this loop emits as one pellet of a single blast, so
    // remote viewers bypass their per-shot decal/effect caps (all pellets
    // share one wep_action_id).  See sv_impact_is_blast in sv_weapons.qc.
    sv_impact_is_blast = 1;
    for (i = 0; i < CFM4_PELLETS; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * CFM4_SPREAD;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * CFM4_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist,
                CFM4_PELLET_CLOSE_DAMAGE, CFM4_PELLET_MIN_DAMAGE,
                CFM4_DAMAGE_FALLOFF_RANGE);
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
    sv_impact_is_blast = 0;
};

void() W_CFM4Fire =
{
    float r = SH_CFM4TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFM4PickShootSeq();
        self.wep_nextframe = time + CFM4_FRAME_INTERVAL;

        W_CFM4Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm4/fire.WAV", 2, ATTN_NORM);
        W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFM4Reload =
{
    if (SH_CFM4TryReload(time))
    {
        self.wep_nextframe = time + CFM4_FRAME_INTERVAL;
        self.cfm4_reload_snd_stage = 0;
    }
};

void() W_CFM4Frame =
{
    float result = 0;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFM4_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        // No draw.WAV — deploy clack reuses reload.WAV.
        if (elapsed >= CFM4_DRAW_CLACK_TIME && !self.cfm4_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm4/reload.WAV", 1, ATTN_NORM);
            self.cfm4_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (self.cfm4_reload_phase == 1
            && self.cfm4_reload_snd_stage < 1
            && elapsed >= CFM4_RELOAD_SHELLIN_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm4/shellin.WAV", 1, ATTN_NORM);
            self.cfm4_reload_snd_stage = 1;
        }
        else if (self.cfm4_reload_phase == 2
            && self.cfm4_reload_snd_stage < 1
            && elapsed >= CFM4_RELOAD_PUMP_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm4/reload.WAV", 1, ATTN_NORM);
            self.cfm4_reload_snd_stage = 1;
        }
    }

    if (self.weaponstate == WS_RELOAD)
        result = SH_CFM4ReloadTick(time);
    else
        result = SH_CFM4TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFM4_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfm4_reload_snd_stage = 0;
    }
};

void() W_CFM4Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_m4", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFM4_VIEWMODEL, CFM4_DISPLAY_NAME, CFM4_SEQ_DRAW,
        CFM4_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFM4Fire;
    self.reload   = W_CFM4Reload;
    self.wepframe = W_CFM4Frame;
    self.shoot    = W_CFM4Shoot;
    self.cfm4_draw_snd_played        = 0;
    self.cfm4_reload_snd_stage       = 0;
    self.cfm4_reload_shells_at_start = 0;
    self.cfm4_reload_shells_done     = 0;
    self.cfm4_reload_phase           = 0;
    W_SetCrosshairProfile(CFM4_SPREAD, 0, 320, 3, TRUE);
};

void() W_CFM4Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfm4  = self.mag_cfm4;
    tgt.ammo_cfm4 = self.ammo_cfm4;

    self.mag_cfm4  = 0;
    self.ammo_cfm4 = 0;

    setmodel(tgt, CFM4_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfm4";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFM4;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFM4Equip;
    tgt.weap_drop_func = W_CFM4Drop;
    tgt.pickupcopy    = W_CFM4PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfm4 =
{
    setmodel(self, CFM4_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_cfm4";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFM4;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFM4Equip;
    self.weap_drop_func = W_CFM4Drop;
    self.pickupcopy    = W_CFM4PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfm4      = MAX_MAG_CFM4;
    self.ammo_cfm4     = MAX_AMMO_CFM4;
    W_RegisterMapWeapon(weapon_cfm4);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfm4_draw_snd_played;
float csqc_cfm4_reload_snd_stage;
float csqc_cfm4_snd_action;

void() CSQC_PredictCFM4Command =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfm4_snd_action)
    {
        csqc_cfm4_snd_action       = predicted_player.wep_action_id;
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfm4_draw_snd_played  = 0;
        csqc_cfm4_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFM4TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm4/fire.WAV", 2, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(CFM4_PELLETS, CFM4_SPREAD,
                    CFM4_PELLET_CLOSE_DAMAGE, CFM4_PELLET_MIN_DAMAGE,
                    CFM4_DAMAGE_FALLOFF_RANGE,
                    CFM4_KICK_PITCH, CFM4_KICK_VARIANCE, CFM4_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFM4_MUZZLE_BONE, CFM4_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, CFM4_PELLETS);
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
            if (!csqc_cfm4_draw_snd_played && elapsed >= CFM4_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfm4/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm4_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (self.cfm4_reload_phase == 1
                && self.cfm4_reload_snd_stage < 1
                && elapsed >= CFM4_RELOAD_SHELLIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfm4/shellin.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfm4_reload_snd_stage = 1;
            }
            else if (self.cfm4_reload_phase == 2
                && self.cfm4_reload_snd_stage < 1
                && elapsed >= CFM4_RELOAD_PUMP_TIME)
            {
                localsound("sounds/weapons/wpn_cfm4/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfm4_reload_snd_stage = 1;
            }
        }
    }

    if (self.weaponstate == WS_RELOAD)
        SH_CFM4ReloadTick(csqc_pred_time);
    SH_CFM4TickState(csqc_pred_time);
};

void() CSQC_PredictCFM4Reload =
{
    if (SH_CFM4TryReload(csqc_pred_time))
    {
        csqc_cfm4_reload_snd_stage = 0;
        csqc_cfm4_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFM4DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFM4_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFM4_SEQ_SHOOT1;
        return CFM4_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        if (predicted_player.cfm4_reload_phase == 0)
            return CFM4_SEQ_RELOAD_0;
        if (predicted_player.cfm4_reload_phase == 1)
            return CFM4_SEQ_RELOAD_1;
        return CFM4_SEQ_RELOAD_2;
    }

    return CFM4_SEQ_IDLE;
};

void() CSQC_CFM4DropClear =
{
    self.mag_cfm4  = 0;
    self.ammo_cfm4 = 0;
};

void() CSQC_CFM4Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_m4", SCOPE_CLASS_NONE);
    self.weapon_name         = CFM4_DISPLAY_NAME;
    self.weapon_viewmodel    = CFM4_VIEWMODEL;
    self.weapon_worldmodel   = CFM4_WORLDMODEL;
    self.weapon_deploy_sound = CFM4_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFM4Command;
    self.csqc_predict_reload = CSQC_PredictCFM4Reload;
    self.csqc_display_frame  = CSQC_CFM4DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFM4DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFM4_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFM4_MUZZLE_OFFSET;

    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfm4_draw_snd_played = 1;
        csqc_cfm4_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
