// ============================================================
//  shared/weapons/sh_wpn_flakshotgun.qc  -  Flak Shotgun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 24-shell magazine, no reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//
//  ----------------------------------------------------------
//  ANATOMY OF A WEAPON FILE  (use this file as the baseline)
//  ----------------------------------------------------------
//  (1) Constants — balance, frame/sequence indices, sound paths,
//      model paths, muzzle offsets.
//  (2) State-machine wrappers — one-liner functions calling
//      SH_StandardTickState / SH_SimpleTickState / SH_SeqDrivenTickState
//      and SH_StandardTryFire / SH_StandardTryReload / SH_StandardTryAction
//      with this weapon's constants.
//  (3) W_*Fire / W_*Reload / W_*AltFire / W_*Special — server-side
//      action: gate via the wrapper, then trace + sound + effect.
//  (4) W_*Frame — fire timed sound/effect events (per-weapon
//      `weapon_snd_stage` counter), then call the tick wrapper.
//  (5) W_*Equip + W_*Drop + weapon_* map-spawn — equip via
//      W_StandardEquipSetup + per-weapon function-pointer assignments;
//      drop + world entity inline (use SH_GoldSrcSetupWorld for
//      GoldSrc world models).
//  (6) CSQC mirror — CSQC_Predict*Command + CSQC_Predict*Reload +
//      CSQC_*DisplayFrame + CSQC_*Equip + CSQC_*DropClear.
//
//  Per-weapon state lives in: .float mag_*, .float weapon_snd_stage,
//  plus the universal weaponstate / wep_anim_start / attack_finished.
//  Anything beyond "actionable now or not" is a code smell.
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
// sv_gunkick — heavy auto-shotgun, big per-shot kick.
const float FLAKSHOTGUN_KICK_PITCH    = 2.5;
const float FLAKSHOTGUN_KICK_VARIANCE = 0.6;
const float FLAKSHOTGUN_KICK_STRENGTH = 1.5;

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float FLAKSHOTGUN_MUZZLE_FORWARD = 42;
const float FLAKSHOTGUN_MUZZLE_RIGHT   = 6.5;
const float FLAKSHOTGUN_MUZZLE_DOWN    = 8.5;

// --- Balance ---
const float FLAKSHOTGUN_PELLETS              = 8;
const float FLAKSHOTGUN_SPREAD               = 0.04;
const float FLAKSHOTGUN_PELLET_CLOSE_DAMAGE  = 15;
const float FLAKSHOTGUN_PELLET_MIN_DAMAGE    = 4;
const float FLAKSHOTGUN_DAMAGE_FALLOFF_RANGE = 1024;

// --- Pre-computed state durations ---
const float FLAKSHOTGUN_DRAW_DURATION  = (FLAKSHOTGUN_DRAW_END - FLAKSHOTGUN_DRAW_START) * FLAKSHOTGUN_FRAME_INTERVAL;
const float FLAKSHOTGUN_FIRE_DURATION  = (FLAKSHOTGUN_FIRE_END - FLAKSHOTGUN_FIRE_START) * FLAKSHOTGUN_FRAME_INTERVAL;

const string FLAKSHOTGUN_VIEWMODEL    = "models/weapons/wpn_flakshotgun/v_flakshotgun.mdl";
const string FLAKSHOTGUN_WORLDMODEL   = "models/weapons/wpn_flakshotgun/w_flakshotgun.mdl";
const string FLAKSHOTGUN_DEPLOY_SOUND = "";
const string FLAKSHOTGUN_DISPLAY_NAME = "FLAK SHOTGUN";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_FlakShotgunTickState =
{
    return SH_SimpleTickState(now, FLAKSHOTGUN_DRAW_DURATION, FLAKSHOTGUN_FIRE_DURATION);
};

float(float now) SH_FlakShotgunTryFire =
{
    return SH_StandardTryFire(now, mag_flakshotgun, FLAKSHOTGUN_FIRE_DELAY, FLAKSHOTGUN_DRYFIRE_DELAY);
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

    // sv_gunkick — one impulse per trigger pull.
    SH_ApplyViewKick(FLAKSHOTGUN_KICK_PITCH, FLAKSHOTGUN_KICK_VARIANCE, FLAKSHOTGUN_KICK_STRENGTH);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    pellet = 0;
    // Tag every impact this loop emits as one pellet of a single blast, so
    // remote viewers bypass their per-shot decal/effect caps (all pellets
    // share one wep_action_id).  See sv_impact_is_blast in sv_weapons.qc.
    sv_impact_is_blast = 1;
    while (pellet < FLAKSHOTGUN_PELLETS)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + pellet, 0) * FLAKSHOTGUN_SPREAD;
        sy  = SH_SpreadJitter(self.wep_action_id + pellet, 1) * FLAKSHOTGUN_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

#ifdef SSQC
        // Server: QC rewind already applied — no MOVE_LAGGED.
        Lagcomp_TraceLine(src, end, MOVE_NORMAL, self);
#else
        // Client prediction path: traces against locally-replicated ents,
        // no engine antilag involvement.
        traceline(src, end, MOVE_NORMAL, self);
#endif

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist,
                FLAKSHOTGUN_PELLET_CLOSE_DAMAGE, FLAKSHOTGUN_PELLET_MIN_DAMAGE,
                FLAKSHOTGUN_DAMAGE_FALLOFF_RANGE);

            if (W_CanDamageTarget(trace_ent))
            {
                if (trace_ent.classname == "player")
                {
                    // Stamp hitgroup before W_ApplyDamage so the gib-on-
                    // headshot path inside it sees this pellet's hitgroup.
                    trace_ent.death_hitgroup = W_BoneToHitgroup(trace_bone_id);
                }
                W_ApplyDamage(self, trace_ent, damage);
                if (trace_ent.classname == "player")
                {
                    // All player hits use the lethal spark-splash variant —
                    // matches the cool head-pop look on every body shot.
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
                }
                else
                {
                    // Breakable — auto-classify; flesh breakables get the
                    // lethal upgrade on the killing pellet.
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

        pellet += 1;
    }
    sv_impact_is_blast = 0;
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
    W_StandardEquipSetup(FLAKSHOTGUN_VIEWMODEL, FLAKSHOTGUN_DISPLAY_NAME, FLAKSHOTGUN_DRAW_START, FLAKSHOTGUN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_FlakShotgunFire;
    self.reload   = __NULL__;
    self.wepframe = W_FlakShotgunFrame;
    self.shoot    = W_FlakShotgunShoot;
    W_SetCrosshairProfile(FLAKSHOTGUN_SPREAD, 0, 0, 3, TRUE);
};

void() W_FlakShotgunDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_flakshotgun = self.mag_flakshotgun;
    self.mag_flakshotgun = 0;

    setmodel(tgt, "models/weapons/wpn_flakshotgun/w_flakshotgun.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_flakshotgun";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_FLAKSHOTGUN;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_FlakShotgunEquip;
    tgt.weap_drop_func = W_FlakShotgunDrop;
    tgt.pickupcopy   = W_FlakShotgunPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.dropped_spin = 0;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_flakshotgun =
{
    setmodel(self, "models/weapons/wpn_flakshotgun/w_flakshotgun.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_flakshotgun";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_FLAKSHOTGUN;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_FlakShotgunEquip;
    self.weap_drop_func = W_FlakShotgunDrop;
    self.pickupcopy    = W_FlakShotgunPickupCopy;
    self.touch         = weapon_touch;
    self.dropped_spin  = 0;
    self.mag_flakshotgun = MAX_MAG_FLAKSHOTGUN;
    W_RegisterMapWeapon(weapon_flakshotgun);
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
            if (CSQC_BeginFireActionEffects())
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
                CSQC_PredictedShotgunImpact(FLAKSHOTGUN_PELLETS, FLAKSHOTGUN_SPREAD,
                    FLAKSHOTGUN_PELLET_CLOSE_DAMAGE, FLAKSHOTGUN_PELLET_MIN_DAMAGE, FLAKSHOTGUN_DAMAGE_FALLOFF_RANGE,
                    FLAKSHOTGUN_KICK_PITCH, FLAKSHOTGUN_KICK_VARIANCE, FLAKSHOTGUN_KICK_STRENGTH);
                // Shotgun muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(FLAKSHOTGUN_MUZZLE_FORWARD, FLAKSHOTGUN_MUZZLE_RIGHT,
                    FLAKSHOTGUN_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(FLAKSHOTGUN_MUZZLE_FORWARD, FLAKSHOTGUN_MUZZLE_RIGHT,
                    FLAKSHOTGUN_MUZZLE_DOWN, self.wep_action_id, FLAKSHOTGUN_PELLETS);
                CSQC_EndFireActionEffects();
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
    return CSQC_StandardDisplayFrame(elapsed, FLAKSHOTGUN_FRAME_INTERVAL,
        FLAKSHOTGUN_DRAW_START, FLAKSHOTGUN_DRAW_END,
        FLAKSHOTGUN_FIRE_START, FLAKSHOTGUN_FIRE_END,
        0, 0,
        FLAKSHOTGUN_IDLE_FRAME);
};

void() CSQC_FlakShotgunDropClear =
{
	self.mag_flakshotgun = 0;
};

void() CSQC_FlakShotgunEquip =
{
	self.weapon_name         = FLAKSHOTGUN_DISPLAY_NAME;
	self.weapon_viewmodel    = FLAKSHOTGUN_VIEWMODEL;
	self.weapon_worldmodel   = FLAKSHOTGUN_WORLDMODEL;
	self.weapon_deploy_sound = FLAKSHOTGUN_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictFlakShotgunCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_FlakShotgunDisplayFrame;
	self.csqc_drop_clear     = CSQC_FlakShotgunDropClear;
};

#endif // CSQC
