// ============================================================
//  shared/weapons/sh_wpn_cfawm.qc  -  AWM (CF series)
//
//  Slot  : SLOT_PRIMARY
//  Stats : 10-round magazine, 30 reserve, bolt-action .338 sniper.
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff.
//  Scope : CoD-style toggle scope owned by cl_codscope.qc when
//          sv_codscopes is set.  No altfire/zoom code here.
//
//  Sequence layout (v_awm.mdl):
//     0  idle_0    30 fps
//     1  prefire1  45 fps  (bolt rack @ 38)
//     2  prefire2  45 fps
//     3  prefire3  45 fps
//     4  reload    30 fps  (clipout @ 8, clipin @ 31, reload-tail @ 53)
//     5  select    30 fps  (deploy clack @ 12)
//
//  Sounds in sounds/weapons/wpn_cfawm/.  NO draw.WAV — deploy + bolt
//  cycle reuse reload.WAV (same trick cfbarrett's bolt cycle uses).
// ============================================================

.float mag_cfawm;
.float ammo_cfawm;

.float cfawm_draw_snd_played;
.float cfawm_reload_snd_stage;
.float cfawm_post_fire_bolt_played;

const float CFAWM_SEQ_IDLE    = 0;
const float CFAWM_SEQ_SHOOT1  = 1;
const float CFAWM_SEQ_SHOOT2  = 2;
const float CFAWM_SEQ_SHOOT3  = 3;
const float CFAWM_SEQ_RELOAD  = 4;
const float CFAWM_SEQ_DRAW    = 5;

// --- Sound event timings (elapsed from wep_anim_start) ---
// Reload @ 30 fps: clipout 8/30=0.267, clipin 31/30=1.033, reload 53/30=1.767
// Select @ 30 fps: clack 12/30=0.400
// Prefire bolt rack @ 45 fps: 38/45=0.844
const float CFAWM_RELOAD_CLIPOUT_TIME  = 0.267;
const float CFAWM_RELOAD_CLIPIN_TIME   = 1.033;
const float CFAWM_RELOAD_RELOAD_TIME   = 1.767;
const float CFAWM_DRAW_CLACK_TIME      = 0.400;
const float CFAWM_POST_FIRE_BOLT_TIME  = 0.844;

const float CFAWM_RELOAD_APPLY_TIME    = 1.80;

const float CFAWM_FIRE_DELAY        = 1.4;    // bolt-action
const float CFAWM_DRYFIRE_DELAY     = 0.2;
const float CFAWM_FRAME_INTERVAL    = 0.05;

const float MAX_MAG_CFAWM           = 10;
const float MAX_AMMO_CFAWM          = 30;

// --- Balance --- (.338 Lapua — slightly lighter than the Barrett)
const float CFAWM_BASE_SPREAD          = 0.008;
const float CFAWM_MOVE_SPREAD          = 0.12;
const float CFAWM_FULL_SPREAD_SPEED    = 320;
const float CFAWM_CLOSE_DAMAGE         = 130;
const float CFAWM_MIN_DAMAGE           = 75;
const float CFAWM_DAMAGE_FALLOFF_RANGE = 4096;
const float CFAWM_KICK_PITCH    = 2.2;
const float CFAWM_KICK_VARIANCE = 0.6;
const float CFAWM_KICK_STRENGTH = 1.8;

// Muzzle attachment — from v_awm.mdl's $attachment 0:
//     $attachment 0 "Bone01" 30.0 0.0 0.0
const string CFAWM_MUZZLE_BONE   = "Bone01";
#define CFAWM_MUZZLE_OFFSET ('30.0 0.0 0.0')

const string CFAWM_VIEWMODEL    = "models/weapons/wpn_cfawm/v_awm.mdl";
const string CFAWM_WORLDMODEL   = "models/weapons/wpn_cfawm/w_awm.mdl";
const string CFAWM_DEPLOY_SOUND = "";
const string CFAWM_DISPLAY_NAME = "AWM";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

float() SH_CFAwmPickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.34) return CFAWM_SEQ_SHOOT1;
    if (r < 0.67) return CFAWM_SEQ_SHOOT2;
    return CFAWM_SEQ_SHOOT3;
};

float(float now) SH_CFAwmTickState =
{
    return SH_StandardTickState(now, mag_cfawm, ammo_cfawm, MAX_MAG_CFAWM,
        SH_SeqDuration(CFAWM_VIEWMODEL, CFAWM_SEQ_DRAW,   1.0),
        SH_SeqDuration(CFAWM_VIEWMODEL, self.weaponframe, 0.5),
        SH_SeqDuration(CFAWM_VIEWMODEL, CFAWM_SEQ_RELOAD, 2.0),
        CFAWM_RELOAD_APPLY_TIME);
};

float(float now) SH_CFAwmTryFire =
{
    return SH_StandardTryFire(now, mag_cfawm, CFAWM_FIRE_DELAY, CFAWM_DRYFIRE_DELAY);
};

float(float now) SH_CFAwmTryReload =
{
    return SH_StandardTryReload(now, mag_cfawm, ammo_cfawm, MAX_MAG_CFAWM,
        SH_SeqDuration(CFAWM_VIEWMODEL, CFAWM_SEQ_RELOAD, 2.0));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFAwmPickupCopy =
{
    player.mag_cfawm  = self.mag_cfawm;
    player.ammo_cfawm = self.ammo_cfawm;
};

void() W_CFAwmShoot =
{
    W_PenetratingHitscanShoot(CFAWM_BASE_SPREAD, CFAWM_MOVE_SPREAD, CFAWM_FULL_SPREAD_SPEED,
        CFAWM_CLOSE_DAMAGE, CFAWM_MIN_DAMAGE, CFAWM_DAMAGE_FALLOFF_RANGE, 64, 0.985,
        CFAWM_KICK_PITCH, CFAWM_KICK_VARIANCE, CFAWM_KICK_STRENGTH);
};

void() W_CFAwmFire =
{
    float r = SH_CFAwmTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFAwmPickShootSeq();
        self.wep_nextframe = time + CFAWM_FRAME_INTERVAL;
        self.cfawm_post_fire_bolt_played = 0;

        // Bolt-action scope-rescope: hold the suppress for the full bolt
        // cycle so the CoD scope can't re-engage until back in battery.
        self.pm_fire_suppress_until = time + CFAWM_FIRE_DELAY;

        W_CFAwmShoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfawm/fire.WAV", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFAwmReload =
{
    if (SH_CFAwmTryReload(time))
    {
        self.weaponframe   = CFAWM_SEQ_RELOAD;
        self.wep_nextframe = time + CFAWM_FRAME_INTERVAL;
        self.cfawm_reload_snd_stage = 0;
    }
};

void() W_CFAwmFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFAWM_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        // No draw.WAV ships — deploy clack reuses reload.WAV.
        if (elapsed >= CFAWM_DRAW_CLACK_TIME && !self.cfawm_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfawm/reload.WAV", 1, ATTN_NORM);
            self.cfawm_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= CFAWM_POST_FIRE_BOLT_TIME && !self.cfawm_post_fire_bolt_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfawm/reload.WAV", 1, ATTN_NORM);
            self.cfawm_post_fire_bolt_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= CFAWM_RELOAD_CLIPOUT_TIME && self.cfawm_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfawm/clipout.WAV", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.cfawm_reload_snd_stage = 1;
        }
        if (elapsed >= CFAWM_RELOAD_CLIPIN_TIME && self.cfawm_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfawm/clipin.WAV", 1, ATTN_NORM);
            self.cfawm_reload_snd_stage = 2;
        }
        if (elapsed >= CFAWM_RELOAD_RELOAD_TIME && self.cfawm_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfawm/reload.WAV", 1, ATTN_NORM);
            self.cfawm_reload_snd_stage = 3;
        }
    }

    result = SH_CFAwmTickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFAWM_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfawm_reload_snd_stage = 0;
    }
};

void() W_CFAwmEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_awm", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(CFAWM_VIEWMODEL, CFAWM_DISPLAY_NAME, CFAWM_SEQ_DRAW,
        CFAWM_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFAwmFire;
    self.reload   = W_CFAwmReload;
    self.wepframe = W_CFAwmFrame;
    self.shoot    = W_CFAwmShoot;
    self.cfawm_draw_snd_played  = 0;
    self.cfawm_reload_snd_stage = 0;
    W_SetCrosshairProfile(CFAWM_BASE_SPREAD, CFAWM_MOVE_SPREAD, CFAWM_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_CFAwmDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfawm  = self.mag_cfawm;
    tgt.ammo_cfawm = self.ammo_cfawm;

    self.mag_cfawm  = 0;
    self.ammo_cfawm = 0;

    setmodel(tgt, CFAWM_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfawm";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFAWM;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFAwmEquip;
    tgt.weap_drop_func = W_CFAwmDrop;
    tgt.pickupcopy    = W_CFAwmPickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfawm =
{
    setmodel(self, CFAWM_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_cfawm";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFAWM;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFAwmEquip;
    self.weap_drop_func = W_CFAwmDrop;
    self.pickupcopy    = W_CFAwmPickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfawm     = MAX_MAG_CFAWM;
    self.ammo_cfawm    = MAX_AMMO_CFAWM;
    W_RegisterMapWeapon(weapon_cfawm);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfawm_draw_snd_played;
float csqc_cfawm_reload_snd_stage;
float csqc_cfawm_post_fire_bolt_played;
float csqc_cfawm_snd_action;

void() CSQC_PredictCFAwmCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfawm_snd_action)
    {
        csqc_cfawm_snd_action            = predicted_player.wep_action_id;
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfawm_draw_snd_played   = 0;
        csqc_cfawm_reload_snd_stage      = 0;
        csqc_cfawm_post_fire_bolt_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFAwmTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            self.pm_fire_suppress_until = time + CFAWM_FIRE_DELAY;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfawm/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFAWM_BASE_SPREAD, CFAWM_MOVE_SPREAD, CFAWM_FULL_SPREAD_SPEED,
                    CFAWM_CLOSE_DAMAGE, CFAWM_MIN_DAMAGE, CFAWM_DAMAGE_FALLOFF_RANGE, 64, 0.985,
                    CFAWM_KICK_PITCH, CFAWM_KICK_VARIANCE, CFAWM_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFAWM_MUZZLE_BONE, CFAWM_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorldAnimated(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, 4);
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
            if (!csqc_cfawm_draw_snd_played && elapsed >= CFAWM_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfawm/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfawm_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            if (!csqc_cfawm_post_fire_bolt_played && elapsed >= CFAWM_POST_FIRE_BOLT_TIME)
            {
                localsound("sounds/weapons/wpn_cfawm/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfawm_post_fire_bolt_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_cfawm_reload_snd_stage < 1 && elapsed >= CFAWM_RELOAD_CLIPOUT_TIME)
            {
                localsound("sounds/weapons/wpn_cfawm/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_cfawm_reload_snd_stage = 1;
            }
            if (csqc_cfawm_reload_snd_stage < 2 && elapsed >= CFAWM_RELOAD_CLIPIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfawm/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfawm_reload_snd_stage = 2;
            }
            if (csqc_cfawm_reload_snd_stage < 3 && elapsed >= CFAWM_RELOAD_RELOAD_TIME)
            {
                localsound("sounds/weapons/wpn_cfawm/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfawm_reload_snd_stage = 3;
            }
        }
    }

    SH_CFAwmTickState(csqc_pred_time);
};

void() CSQC_PredictCFAwmReload =
{
    if (SH_CFAwmTryReload(csqc_pred_time))
    {
        csqc_cfawm_reload_snd_stage = 0;
        csqc_cfawm_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFAwmDisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFAWM_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.34) return CFAWM_SEQ_SHOOT1;
        if (r < 0.67) return CFAWM_SEQ_SHOOT2;
        return CFAWM_SEQ_SHOOT3;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return CFAWM_SEQ_RELOAD;

    return CFAWM_SEQ_IDLE;
};

void() CSQC_CFAwmDropClear =
{
    self.mag_cfawm  = 0;
    self.ammo_cfawm = 0;
};

void() CSQC_CFAwmEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_awm", SCOPE_CLASS_SNIPER_BOLT);
    self.weapon_name         = CFAWM_DISPLAY_NAME;
    self.weapon_viewmodel    = CFAWM_VIEWMODEL;
    self.weapon_worldmodel   = CFAWM_WORLDMODEL;
    self.weapon_deploy_sound = CFAWM_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFAwmCommand;
    self.csqc_predict_reload = CSQC_PredictCFAwmReload;
    self.csqc_display_frame  = CSQC_CFAwmDisplayFrame;
    self.csqc_drop_clear     = CSQC_CFAwmDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
    self.weapon_muzzle_bone   = CFAWM_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFAWM_MUZZLE_OFFSET;

    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfawm_draw_snd_played = 1;
        csqc_cfawm_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
