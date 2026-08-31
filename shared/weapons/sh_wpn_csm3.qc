// ============================================================
//  shared/weapons/sh_wpn_csm3.qc  -  CS M3 Super 90
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell tube, 24 reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//  Reload: Shell-by-shell insertion (frame-driven loop)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_m3;
.float ammo_m3;

// --- Sequence indices (GoldSrc IDST viewmodel, models/v_m3.mdl) ---
//
// FALLBACKS ONLY — resolved by NAME through SH_SeqForName; see sh_wpn_csaug.qc.
// Read out of cstrike/models/v_m3.mdl itself:
//   [0] idle          12fps  11f  0.833s
//   [1] shoot1        32fps  38f  1.156s   f0 5001 (muzzleflash, attachment 2)
//   [2] shoot2        37fps  38f  1.000s   f0 5001
//   [3] insert        65fps  28f  0.415s   f0 "m3_insertshell"
//   [4] after_reload  38fps  34f  0.868s   f0 "m3_pump"
//   [5] start_reload  30fps  16f  0.500s
//   [6] draw          30fps  31f  1.000s   f11 "m3_pump"
//
// The two shoot takes are DIFFERENT LENGTHS (1.156 vs 1.000), which is exactly
// the pair of cadences the old frame bake modelled by hand as M3_FIRE_DELAY /
// M3_ALT_FIRE_DELAY.  SH_M3FireVariantIsAlt keeps picking between them off the
// parity of wep_action_id, so the deterministic client/server agreement the old
// comment describes is unchanged — only where the numbers come from moved.
const float M3_SEQ_IDLE    = 0;
const float M3_SEQ_SHOOT1  = 1;
const float M3_SEQ_SHOOT2  = 2;
const float M3_SEQ_INSERT  = 3;
const float M3_SEQ_AFTER   = 4;
const float M3_SEQ_START   = 5;
const float M3_SEQ_DRAW    = 6;

const float M3_FRAME_INTERVAL         = 0.0333334;   // state-machine tick rate

const float M3_FIRE_DELAY             = 1.0;
const float M3_ALT_FIRE_DELAY         = 0.9;

// Event marks as a FRACTION of their sequence.
const float M3_DRAW_F_PUMP            = 0.3667;   // frame 11 / 30
const float M3_FIRE_F_EJECT           = 0.3200;   // the shell clears the port
const float M3_INSERT_F_SHELL         = 0.1500;   // model event is f0; pulled just
                                                  // inside so a tick always sees it
const float M3_AFTER_F_PUMP           = 0.0500;   // model event is f0, same reason

const float MAX_MAG_M3                = 8;
const float MAX_AMMO_M3               = 24;

// --- Balance ---
const float M3_PELLETS                = 12;
const float M3_SPREAD                 = 0.08;
const float M3_PELLET_CLOSE_DAMAGE    = 15;
const float M3_PELLET_MIN_DAMAGE      = 4;
const float M3_PELLET_FALLOFF_RANGE   = 1024;
const float M3_DRYFIRE_DELAY          = 0.2;
// sv_gunkick — pump shotgun, big single-shot kick (long pump delay).
const float M3_KICK_PITCH    = 2.5;
const float M3_KICK_VARIANCE = 0.6;
const float M3_KICK_STRENGTH = 1.5;

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float M3_MUZZLE_FORWARD = 42;
const float M3_MUZZLE_RIGHT   = 8.025;
const float M3_MUZZLE_DOWN    = 4.025;

// THE MOUNTED COUNTER-STRIKE VIEW MODEL.  This used to be a 565 KB mod-local
// IDPO (Quake-format) re-bake under models/weapons/wpn_csm3/, which is what made
// the M3 read as "the game version, not the mounted version".  The note below
// about the v_ model being deliberately left alone described that earlier pass;
// the viewmodel has since moved to the mount with the rest of the set, and the
// animation half of this file went sequence-driven with it.
const string M3_VIEWMODEL    = "models/v_m3.mdl";
// THE MOUNTED COUNTER-STRIKE WORLD MODEL, not the mod-local one.
//
// models/weapons/wpn_csm3/w_m3.mdl is a QUAKE-format conversion (`IDPO`, not
// `IDST`) with an 8-bit palettised skin, and it is the flattest world model in
// the set at 1.30 units thick against the AK47's 2.44 — a dark, nearly flat
// plate that is genuinely hard to see lying on a floor.  Nothing was failing to
// load: it was drawing, and you could not pick it out.  The mounted GoldSrc
// original is the model Counter-Strike actually ships, and the same file is
// still sitting beside the converted one as `w_m3.mdlold2` if the mod-local
// path is ever wanted back.
//
// The PLAYER model is the mount's too (models/p_m3.mdl, via the manifest row).
const string M3_WORLDMODEL   = "models/w_m3.mdl";
const string M3_DEPLOY_SOUND = "";
const string M3_DISPLAY_NAME = "M3";

// Reload bookkeeping — `shells` is the plan fixed at reload start, `inserted` is
// how much of it has been paid out.  Same shape as sh_wpn_csxm1014.qc, which is
// the in-tree precedent for a shell-by-shell reload on a sequence-driven model.
.float m3_shells;
.float m3_inserted;
.float m3_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_M3SeqIdle   = { return SH_SeqForName(M3_VIEWMODEL, "idle",         M3_SEQ_IDLE); };
float() SH_M3SeqShoot1 = { return SH_SeqForName(M3_VIEWMODEL, "shoot1",       M3_SEQ_SHOOT1); };
float() SH_M3SeqShoot2 = { return SH_SeqForName(M3_VIEWMODEL, "shoot2",       M3_SEQ_SHOOT2); };
float() SH_M3SeqInsert = { return SH_SeqForName(M3_VIEWMODEL, "insert",       M3_SEQ_INSERT); };
float() SH_M3SeqAfter  = { return SH_SeqForName(M3_VIEWMODEL, "after_reload", M3_SEQ_AFTER); };
float() SH_M3SeqStart  = { return SH_SeqForName(M3_VIEWMODEL, "start_reload", M3_SEQ_START); };
float() SH_M3SeqDraw   = { return SH_SeqForName(M3_VIEWMODEL, "draw",         M3_SEQ_DRAW); };

float() SH_M3DrawDuration   = { return SH_SeqDuration(M3_VIEWMODEL, SH_M3SeqDraw(),   1.000); };
float() SH_M3EnterDuration  = { return SH_SeqDuration(M3_VIEWMODEL, SH_M3SeqStart(),  0.500); };
float() SH_M3InsertDuration = { return SH_SeqDuration(M3_VIEWMODEL, SH_M3SeqInsert(), 0.415); };
float() SH_M3ExitDuration   = { return SH_SeqDuration(M3_VIEWMODEL, SH_M3SeqAfter(),  0.868); };

// Total length of a reload that pays out `shells` shells — written once here.
float(float shells) SH_M3ReloadTotal =
{
    return SH_M3EnterDuration()
         + shells * SH_M3InsertDuration()
         + SH_M3ExitDuration();
};

// The plan, computed identically on both sides from pre-reload mag and ammo.
float() SH_M3PlannedShells =
{
    float n = min(MAX_MAG_M3 - self.mag_m3, self.ammo_m3);
    if (n < 1) n = 1;
    return n;
};

// ============================================================
//  SHARED — state machine + try functions
// ============================================================

float(float now, float shells) SH_M3TickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_M3DrawDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        // The two takes are different lengths — ask the one that is playing.
        if (elapsed >= SH_SeqDuration(M3_VIEWMODEL, self.weaponframe, 1.156))
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SH_M3ReloadTotal(shells))
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

// Deterministic variant pick — alternates between the two fire
// animations on parity of wep_action_id.  Both server and client
// observe the same wep_action_id at the moment of fire, so they
// always agree on which variant played and what delay to apply.
// Older code did the pick via random() on the server only and the
// client always assumed M3_FIRE_DELAY — when the server rolled the
// 0.9 s alt path the client's predicted next-fire stamp was 100 ms
// late, causing visible "skipped beat / silent for a few shots"
// patterns under sustained fire.
float() SH_M3FireVariantIsAlt =
{
    return (self.wep_action_id & 1) ? 1 : 0;
};

float() SH_M3FireDelayForVariant =
{
    return SH_M3FireVariantIsAlt() ? M3_ALT_FIRE_DELAY : M3_FIRE_DELAY;
};

float() SH_M3FireFrameStartForVariant =
{
    return SH_M3FireVariantIsAlt() ? SH_M3SeqShoot2() : SH_M3SeqShoot1();
};

// Same pick, but taking the action id explicitly.  The display frame runs with
// `self` set to the viewmodel entity, not the player, so it cannot go through
// SH_M3FireVariantIsAlt's `self.wep_action_id` — it passes
// predicted_player.wep_action_id in here instead.  Same parity, same answer.
float(float action_id) SH_M3PickShootSeq =
{
    return (action_id & 1) ? SH_M3SeqShoot2() : SH_M3SeqShoot1();
};

float(float now) SH_M3TryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_m3 <= 0)
    { self.attack_finished = now + M3_DRYFIRE_DELAY; return -1; }

    self.mag_m3          -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    // Compute delay AFTER incrementing wep_action_id so server and
    // client read the same parity bit.  Phase-locked advance — see
    // SH_StandardTryFire for the rationale.  M3's ~1 s cadence
    // tolerates drift better than a fast SMG would, but the same
    // determinism rules apply.
    float fd = SH_M3FireDelayForVariant();
    if (now - self.attack_finished < fd)
        self.attack_finished += fd;
    else
        self.attack_finished  = now + fd;
    return 1;
};

float(float now) SH_M3TryReload =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_m3 >= MAX_MAG_M3 || self.ammo_m3 <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_M3PickupCopy =
{ player.mag_m3 = self.mag_m3; player.ammo_m3 = self.ammo_m3; };

void() W_M3FirePellets =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    // sv_gunkick — one impulse per trigger pull (not per pellet),
    // applied first so the trace direction below uses the kicked
    // aim. Mirrors W_PenetratingHitscanShoot's structure.
    SH_ApplyViewKick(M3_KICK_PITCH, M3_KICK_VARIANCE, M3_KICK_STRENGTH);

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
    for (i = 0; i < M3_PELLETS; i++)
    {
        sx = SH_SpreadJitter(self.wep_action_id + i, 0) * M3_SPREAD;
        sy = SH_SpreadJitter(self.wep_action_id + i, 1) * M3_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist, M3_PELLET_CLOSE_DAMAGE, M3_PELLET_MIN_DAMAGE, M3_PELLET_FALLOFF_RANGE);
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
    }
    sv_impact_is_blast = 0;
};

void() W_M3Fire =
{
    float r = SH_M3TryFire(time);
    if (r == 1)
    {
        // Variant + delay already chosen deterministically inside
        // SH_M3TryFire — just mirror the matching frame here for the
        // visible animation pick.  Don't re-stamp attack_finished.
        self.weaponframe   = SH_M3FireFrameStartForVariant();
        self.wep_nextframe = time + M3_FRAME_INTERVAL;
        self.m3_snd_stage  = 0;
        W_M3FirePellets();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm3/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_M3Reload =
{
    // Take the plan BEFORE TryReload, off the pre-reload magazine, so the CSQC
    // half below walks an identical timeline.
    float plan = SH_M3PlannedShells();

    if (SH_M3TryReload(time))
    {
        self.m3_shells     = plan;
        self.m3_inserted   = 0;
        self.m3_snd_stage  = 0;
        self.weaponframe   = SH_M3SeqStart();
        self.wep_nextframe = time + M3_FRAME_INTERVAL;
    }
};

void() W_M3Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven: weaponframe holds the SEQUENCE, so it is switched at phase
    // boundaries rather than stepped every tick.
    self.wep_nextframe += M3_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_M3DrawDuration() * M3_DRAW_F_PUMP && self.m3_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm3/pump.wav", 1, ATTN_NORM);
            self.m3_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_SeqDuration(M3_VIEWMODEL, self.weaponframe, 1.156) * M3_FIRE_F_EJECT
            && self.m3_snd_stage < 1)
        {
            W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');
            self.m3_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float enter = SH_M3EnterDuration();
        float ins   = SH_M3InsertDuration();

        // Phase 2 — pay out the plan.  A `while` rather than an `if` so a frame
        // that arrives late still credits every shell it passed instead of
        // silently finishing the reload short.
        while (self.m3_inserted < self.m3_shells
               && elapsed >= enter + self.m3_inserted * ins + ins * M3_INSERT_F_SHELL)
        {
            if (self.mag_m3 < MAX_MAG_M3 && self.ammo_m3 > 0)
            {
                self.mag_m3  += 1;
                self.ammo_m3 -= 1;
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm3/insertshell.wav", 1, ATTN_NORM);
            }
            self.m3_inserted += 1;
            self.weaponframe  = SH_M3SeqInsert();
        }

        // Phase 3 — the gun comes back up and is pumped.
        if (elapsed >= enter + self.m3_shells * ins)
        {
            self.weaponframe = SH_M3SeqAfter();
            if (elapsed >= enter + self.m3_shells * ins
                           + SH_M3ExitDuration() * M3_AFTER_F_PUMP
                && self.m3_snd_stage < 1)
            {
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm3/pump.wav", 1, ATTN_NORM);
                self.m3_snd_stage = 1;
            }
        }
    }

    result = SH_M3TickState(time, self.m3_shells);
    if (result & 1)
    {
        self.weaponframe    = SH_M3SeqIdle();
        self.wep_nextframe  = 0;
        self.m3_snd_stage   = 0;
        self.m3_inserted    = 0;
    }
};

void() W_M3Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_csm3", SCOPE_CLASS_NONE);
    self.weaponmodel = M3_VIEWMODEL;
    self.weapon_name = M3_DISPLAY_NAME;
    self.weapon_draw_start_frame = SH_M3SeqDraw();
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_M3Fire; self.reload = W_M3Reload; self.wepframe = W_M3Frame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = SH_M3SeqDraw();
    self.wep_nextframe = time + M3_FRAME_INTERVAL;
    self.m3_snd_stage = 0;
    self.m3_inserted  = 0;
    self.m3_shells    = 0;
    W_SetCrosshairProfile(M3_SPREAD, 0, 320, 3, TRUE);
};

void() W_M3Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_m3 = self.mag_m3; tgt.ammo_m3 = self.ammo_m3;
    self.mag_m3 = 0; self.ammo_m3 = 0;
    setmodel(tgt, M3_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_csm3"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSM3; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_M3Equip; tgt.weap_drop_func = W_M3Drop;
    tgt.pickupcopy = W_M3PickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csm3 =
{
    setmodel(self, M3_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_csm3"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSM3; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_M3Equip; self.weap_drop_func = W_M3Drop;
    self.pickupcopy = W_M3PickupCopy; self.touch = weapon_touch;
    self.mag_m3 = MAX_MAG_M3; self.ammo_m3 = MAX_AMMO_M3;
    W_RegisterMapWeapon(weapon_csm3);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_m3_shells;
float csqc_m3_inserted;
float csqc_m3_snd_stage;
float csqc_m3_snd_action;
float csqc_m3_casing_spawned;

void() CSQC_PredictM3Command =
{
    float r;

    if (predicted_player.wep_action_id != csqc_m3_snd_action)
    {
        csqc_m3_snd_action = predicted_player.wep_action_id;
        csqc_m3_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_M3TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_m3_casing_spawned = FALSE;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm3/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(M3_PELLETS, M3_SPREAD,
                    M3_PELLET_CLOSE_DAMAGE, M3_PELLET_MIN_DAMAGE, M3_PELLET_FALLOFF_RANGE,
                    M3_KICK_PITCH, M3_KICK_VARIANCE, M3_KICK_STRENGTH);
                // Shotgun muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(M3_MUZZLE_FORWARD, M3_MUZZLE_RIGHT,
                    M3_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(M3_MUZZLE_FORWARD, M3_MUZZLE_RIGHT,
                    M3_MUZZLE_DOWN, self.wep_action_id, M3_PELLETS);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted draw pump + fire eject + shell-by-shell reload, all timed off
    // the loaded model's own sequence durations.
    if (self.weaponstate == WS_FIRE && !csqc_m3_casing_spawned
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start
            >= SH_SeqDuration(M3_VIEWMODEL, self.weaponframe, 1.156) * M3_FIRE_F_EJECT)
        {
            CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            csqc_m3_casing_spawned = TRUE;
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_m3_snd_stage < 1
                && elapsed >= SH_M3DrawDuration() * M3_DRAW_F_PUMP)
            {
                localsound("sounds/weapons/wpn_csm3/pump.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_m3_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float snd_enter = SH_M3EnterDuration();
            float snd_ins   = SH_M3InsertDuration();

            // The same while-loop the server runs, over the same timeline.
            while (csqc_m3_inserted < csqc_m3_shells
                   && elapsed >= snd_enter + csqc_m3_inserted * snd_ins
                                 + snd_ins * M3_INSERT_F_SHELL)
            {
                localsound("sounds/weapons/wpn_csm3/insertshell.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_m3_inserted += 1;
            }

            if (csqc_m3_snd_stage < 1
                && elapsed >= snd_enter + csqc_m3_shells * snd_ins
                              + SH_M3ExitDuration() * M3_AFTER_F_PUMP)
            {
                localsound("sounds/weapons/wpn_csm3/pump.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_m3_snd_stage = 1;
            }
        }
    }

    if (SH_M3TickState(csqc_pred_time, csqc_m3_shells) & 1)
        csqc_m3_inserted = 0;
};

void() CSQC_PredictM3Reload =
{
    // Take the plan BEFORE TryReload, from the same pre-reload mag and ammo the
    // server reads, so both sides walk an identical timeline.
    float plan = SH_M3PlannedShells();

    if (SH_M3TryReload(csqc_pred_time))
    {
        csqc_m3_shells     = plan;
        csqc_m3_inserted   = 0;
        csqc_m3_snd_stage  = 0;
        csqc_m3_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
//
// The reload arm also drives csqc_viewmodel_sequence_time, because the insert
// take has to play once PER SHELL and setting .frame alone would leave the second
// and later shells frozen on its final pose — the engine clamps a non-looping
// sequence there.  See sh_wpn_csxm1014.qc for the full note.
float(float elapsed) CSQC_M3DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_M3SeqDraw();

    if (predicted_player.weaponstate == WS_FIRE)
        return SH_M3PickShootSeq(predicted_player.wep_action_id);

    if (predicted_player.weaponstate == WS_RELOAD)
    {
        float enter = SH_M3EnterDuration();
        float ins   = SH_M3InsertDuration();
        float loops = csqc_m3_shells * ins;

        if (elapsed < enter)
            return SH_M3SeqStart();

        float in_reload = elapsed - enter;
        if (in_reload < loops)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = in_reload - floor(in_reload / ins) * ins;
            return SH_M3SeqInsert();
        }

        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = in_reload - loops;
        return SH_M3SeqAfter();
    }

    return SH_M3SeqIdle();
};

void() CSQC_M3DropClear =
{
	self.mag_m3  = 0;
	self.ammo_m3 = 0;
};

void() CSQC_M3Equip =
{
	W_SetADSProfile(TRUE, "cl_ads_csm3", SCOPE_CLASS_NONE);
	self.weapon_name         = M3_DISPLAY_NAME;
	self.weapon_viewmodel    = M3_VIEWMODEL;
	self.weapon_worldmodel   = M3_WORLDMODEL;
	self.weapon_deploy_sound = M3_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictM3Command;
	self.csqc_predict_reload = CSQC_PredictM3Reload;
	self.csqc_display_frame  = CSQC_M3DisplayFrame;
	self.csqc_drop_clear     = CSQC_M3DropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED — models/v_m3.mdl draws the same stock cstrike arm as v_aug /
	// v_glock18 / v_usp, all of which are flipped.  cl_lefthand XORs against it.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
