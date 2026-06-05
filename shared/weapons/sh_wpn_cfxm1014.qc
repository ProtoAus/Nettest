// ============================================================
//  shared/weapons/sh_wpn_cfxm1014.qc  -  SPAS-12 (CF series)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell tube, 32 reserve, pump-action
//  Fire  : 9-pellet hitscan, linear damage falloff, ~0.88s pump cycle
//
//  Sequence-driven GoldSrc viewmodel (v_xm1014.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFFiveSeven /
//  CFAwp.  W_CFXM1014Frame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_xm1014.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   30 fps  (shoot variant A — event 5001 "31")
//      2  prefire   30 fps  (shoot variant B)
//      3  reload_1  30 fps  (event 5004 frame 2 → bulletin.wav)
//      4  reload_2  20 fps  (event 5004 frame 1 → bback.wav)
//      5  reload_0  10 fps  (idle between)
//      6  select    30 fps  (event 5004 frame 10 → reload.wav — draw clack)
//
//  Reload modelling note (pump-shotgun limitation):
//  The XM1014/SPAS-12 source model is built around shell-by-shell
//  insertion, with reload_1 + reload_2 looping per shell and reload_0
//  as an idle.  This implementation simplifies to a SINGLE
//  SH_StandardTryReload pass: we play reload_1 once, refill the mag
//  to MAX in one go at the apply tick, then return to idle.  Trade-off
//  is no per-shell visual + no early-abort-to-fire; in exchange we get
//  fully predictable client/server parity through the same standard
//  state machine the rest of the CF lineup uses.  If shell-by-shell
//  is later required, follow CSM3's frame-driven loop pattern (server
//  steps weaponframe, client mirrors via reload-stage counters).
//
//  Camera-relative muzzle — no $attachment dump available for this
//  model yet, so the flash is anchored to a camera-relative point
//  rather than a bone.  If the user later supplies $attachment 0 data
//  for v_xm1014.mdl, swap these for CFXM1014_MUZZLE_BONE +
//  CFXM1014_MUZZLE_OFFSET and replace the AtMuzzle calls below with
//  the CSQC_ViewmodelAttachmentWorldPos / AtWorld pattern from HDAK47.
//
//  Per-reload sound trackers use SEPARATE fields (NOT a single
//  collapsed stage variable).  This is the CFFiveSeven / CFAwp pattern
//  — see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfxm1014;
.float ammo_cfxm1014;

// --- Per-entity sound stage trackers (server side) ---
.float cfxm1014_draw_snd_played;
.float cfxm1014_reload_snd_stage;
// Shell-by-shell reload state.  Stamped at reload start; both server
// and CSQC drive phase transitions from elapsed time + this baseline
// so visuals + sounds + mag/ammo updates stay in lockstep.
.float cfxm1014_reload_shells_at_start;   // total shells to insert
.float cfxm1014_reload_shells_done;       // shells already inserted this reload
.float cfxm1014_reload_phase;             // 0 = reload_0, 1 = reload_1, 2 = reload_2

// --- Sequence indices ---
const float CFXM1014_SEQ_IDLE     = 0;
const float CFXM1014_SEQ_SHOOT1   = 1;
const float CFXM1014_SEQ_SHOOT2   = 2;
const float CFXM1014_SEQ_RELOAD_1 = 3;
const float CFXM1014_SEQ_RELOAD_2 = 4;
const float CFXM1014_SEQ_RELOAD_0 = 5;
const float CFXM1014_SEQ_DRAW     = 6;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload_1 sequence @ 30 fps:
//   bulletin at frame 2 / 30 = 0.067s   — shell inserted
// Reload_2 sequence @ 20 fps  (unused by this simplified reload path —
//   kept as a constant for future shell-by-shell expansion):
//   bback    at frame 1 / 20 = 0.050s   — pump back
// Select sequence @ 30 fps:
//   reload   at frame 10 / 30 = 0.333s  — draw clack
const float CFXM1014_RELOAD_BULLETIN_TIME = 0.067;
const float CFXM1014_RELOAD_BBACK_TIME    = 0.050;
const float CFXM1014_DRAW_CLACK_TIME      = 0.333;

// Ammo applies at the bulletin event — single-pass simplified reload.
// See file-top note re. pump-shotgun limitation.
const float CFXM1014_RELOAD_APPLY_TIME    = 0.10;

// --- Gameplay tuning ---
const float CFXM1014_FIRE_DELAY        = 0.88;   // pump cycle
const float CFXM1014_DRYFIRE_DELAY     = 0.20;
const float CFXM1014_FRAME_INTERVAL    = 0.05;   // state-machine tick rate

const float MAX_MAG_CFXM1014           = 8;
const float MAX_AMMO_CFXM1014          = 32;

// --- Balance ---
// 7-degree cone — tan(7°) ≈ 0.122, matched to this codebase's spread
// convention (radial multiplier on v_right / v_up, see W_M3FirePellets
// for the canonical pellet-spread shape).
const float CFXM1014_PELLETS              = 9;
const float CFXM1014_SPREAD               = 0.122;
const float CFXM1014_PELLET_CLOSE_DAMAGE  = 22;
const float CFXM1014_PELLET_MIN_DAMAGE    = 5;
const float CFXM1014_DAMAGE_FALLOFF_RANGE = 1024;
// sv_gunkick — pump shotgun, big single-shot kick (long pump delay).
const float CFXM1014_KICK_PITCH    = 2.6;
const float CFXM1014_KICK_VARIANCE = 0.6;
const float CFXM1014_KICK_STRENGTH = 1.6;

// Muzzle attachment from v_xm1014.mdl's $attachment 0:
//   $attachment 0 "Bone01" 29.0 0.0 1.2
const string CFXM1014_MUZZLE_BONE   = "Bone01";
#define CFXM1014_MUZZLE_OFFSET ('29.0 0.0 1.2')

const string CFXM1014_VIEWMODEL    = "models/weapons/wpn_cfxm1014/v_xm1014.mdl";
const string CFXM1014_WORLDMODEL   = "models/weapons/wpn_cfxm1014/w_xm1014.mdl";
const string CFXM1014_DEPLOY_SOUND = "";
const string CFXM1014_DISPLAY_NAME = "SPAS-12";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFXM1014PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFXM1014_SEQ_SHOOT1;
    return CFXM1014_SEQ_SHOOT2;
};

// SH_StandardTickState normally handles WS_RELOAD by applying mag/ammo
// at reload_apply_time and transitioning to WS_IDLE at reload_dur.  For
// shell-by-shell we drive WS_RELOAD ourselves (see SH_CFXM1014ReloadTick)
// so we pass an enormous reload_dur to keep the standard helper from
// ever firing the auto-transition; the reload_apply_time stays at the
// per-shell value but the WS_RELOAD branch never reads it because the
// caller checks weaponstate before invoking SH_StandardTickState.
float(float now) SH_CFXM1014TickState =
{
    if (self.weaponstate == WS_RELOAD)
        return 0;   // shell-by-shell drives the reload state itself
    return SH_StandardTickState(now, mag_cfxm1014, ammo_cfxm1014, MAX_MAG_CFXM1014,
        SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_DRAW,     1.0),
        SH_SeqDuration(CFXM1014_VIEWMODEL, self.weaponframe,      0.9),
        SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_RELOAD_1, 1.0),
        CFXM1014_RELOAD_APPLY_TIME);
};

// Shared shell-by-shell driver.  Called from both W_CFXM1014Frame
// (server) and CSQC predict so phase transitions stay in sync.
//
// CRITICAL: re-stamps self.wep_anim_start at each sequence transition
// (phase 0 → 1, between shells within phase 1, phase 1 → 2).  The
// engine's viewmodel renderer in CSQC_AddPredictedViewmodel computes
// frame1time as (cltime - wep_anim_start); without the re-stamp,
// looping the SAME sequence (reload_1 for each shell) leaves the
// animation frozen on the last frame of the first cycle — visible as
// a "solid frame" between shells.  Re-stamping rewinds frame1time to
// 0 and the engine plays the sequence fresh.
//
// Phase state lives in self.cfxm1014_reload_phase (0/1/2).  Shell
// counter in self.cfxm1014_reload_shells_done.
//
// Returns:
//   bit 0 = transition to idle just happened (reload done)
//   bit 1 = a shell was just inserted (mag/ammo updated)
float(float now) SH_CFXM1014ReloadTick =
{
    if (self.weaponstate != WS_RELOAD)
        return 0;

    float elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    float shells_needed = self.cfxm1014_reload_shells_at_start;
    float result = 0;

    // No shells to insert — skip straight to the pump close.
    if (shells_needed <= 0)
    {
        if (self.cfxm1014_reload_phase != 2)
        {
            self.cfxm1014_reload_phase = 2;
            self.weaponframe           = CFXM1014_SEQ_RELOAD_2;
            self.wep_anim_start        = now;
            elapsed                    = 0;
        }
        float dur_2 = SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2)
        {
            self.weaponstate                 = WS_IDLE;
            self.weaponframe                 = CFXM1014_SEQ_IDLE;
            self.wep_nextframe               = 0;
            self.wep_anim_start              = 0;
            self.cfxm1014_reload_phase       = 0;
            self.cfxm1014_reload_shells_done = 0;
            self.cfxm1014_reload_snd_stage   = 0;
            return 1;
        }
        return 0;
    }

    // Phase 0 — reload_0 (start idle).  When its sequence ends,
    // transition to reload_1 for the first shell and re-stamp.
    if (self.cfxm1014_reload_phase == 0)
    {
        float dur_0 = SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_RELOAD_0, 0.4);
        if (elapsed >= dur_0)
        {
            self.cfxm1014_reload_phase     = 1;
            self.weaponframe               = CFXM1014_SEQ_RELOAD_1;
            self.wep_anim_start            = now;
            self.cfxm1014_reload_snd_stage = 0;
        }
        return 0;
    }

    // Phase 1 — shell insert.  When reload_1's sequence ends, apply
    // +1 mag / -1 ammo and either restart reload_1 for the next shell
    // or transition to reload_2.
    if (self.cfxm1014_reload_phase == 1)
    {
        float dur_1 = SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_RELOAD_1, 1.0);
        if (elapsed >= dur_1)
        {
            self.cfxm1014_reload_shells_done += 1;
            self.mag_cfxm1014  += 1;
            self.ammo_cfxm1014 -= 1;
            result = result | 2;

            if (self.cfxm1014_reload_shells_done < shells_needed)
            {
                // Next shell — re-stamp anim start so the engine
                // restarts reload_1 from frame 0.
                self.wep_anim_start            = now;
                self.cfxm1014_reload_snd_stage = 0;
            }
            else
            {
                // Last shell done — transition to reload_2.
                self.cfxm1014_reload_phase     = 2;
                self.weaponframe               = CFXM1014_SEQ_RELOAD_2;
                self.wep_anim_start            = now;
                self.cfxm1014_reload_snd_stage = 0;
            }
        }
        return result;
    }

    // Phase 2 — reload_2 pump close.  When its sequence ends, return
    // to idle.
    if (self.cfxm1014_reload_phase == 2)
    {
        float dur_2_close = SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2_close)
        {
            self.weaponstate                 = WS_IDLE;
            self.weaponframe                 = CFXM1014_SEQ_IDLE;
            self.wep_nextframe               = 0;
            self.wep_anim_start              = 0;
            self.cfxm1014_reload_phase       = 0;
            self.cfxm1014_reload_shells_done = 0;
            self.cfxm1014_reload_snd_stage   = 0;
            result = result | 1;
        }
    }
    return result;
};

float(float now) SH_CFXM1014TryFire =
{
    // Pump shotgun: FIRE_DELAY itself enforces single-shot pacing —
    // no semi-auto edge gate needed.  Same call as RIFLE / SMG path.
    return SH_StandardTryFire(now, mag_cfxm1014, CFXM1014_FIRE_DELAY, CFXM1014_DRYFIRE_DELAY);
};

float(float now) SH_CFXM1014TryReload =
{
    // Use a representative duration as the "reload window" hint for
    // SH_StandardTryReload's accept checks (mag-full, no-ammo, busy
    // gates).  Actual sequence pacing is owned by SH_CFXM1014ReloadTick.
    float dur_hint = SH_SeqDuration(CFXM1014_VIEWMODEL, CFXM1014_SEQ_RELOAD_1, 1.0);
    float r = SH_StandardTryReload(now, mag_cfxm1014, ammo_cfxm1014, MAX_MAG_CFXM1014, dur_hint);
    if (r)
    {
        // Stamp the shell-by-shell baseline so the tick driver can
        // advance phases off self.wep_anim_start (already set by the
        // standard helper).
        float shells = MAX_MAG_CFXM1014 - self.mag_cfxm1014;
        if (shells > self.ammo_cfxm1014) shells = self.ammo_cfxm1014;
        self.cfxm1014_reload_shells_at_start = shells;
        self.cfxm1014_reload_shells_done     = 0;
        self.cfxm1014_reload_phase           = 0;
        self.weaponframe                     = CFXM1014_SEQ_RELOAD_0;
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFXM1014PickupCopy =
{
    player.mag_cfxm1014  = self.mag_cfxm1014;
    player.ammo_cfxm1014 = self.ammo_cfxm1014;
};

// Per-pellet hitscan — mirrors CSM3 / FlakShotgun's W_*FirePellets
// shape (no W_ShotgunHitscanShoot helper exists for sequence-driven
// shotguns; the pellet loop is short and well-tested inline).
void() W_CFXM1014Shoot =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    // sv_gunkick — one impulse per trigger pull (not per pellet),
    // applied first so the trace direction below uses the kicked
    // aim.  Mirrors W_M3FirePellets / W_PenetratingHitscanShoot.
    SH_ApplyViewKick(CFXM1014_KICK_PITCH, CFXM1014_KICK_VARIANCE, CFXM1014_KICK_STRENGTH);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    for (i = 0; i < CFXM1014_PELLETS; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * CFXM1014_SPREAD;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * CFXM1014_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist,
                CFXM1014_PELLET_CLOSE_DAMAGE, CFXM1014_PELLET_MIN_DAMAGE,
                CFXM1014_DAMAGE_FALLOFF_RANGE);
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
};

void() W_CFXM1014Fire =
{
    float r = SH_CFXM1014TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFXM1014PickShootSeq();
        self.wep_nextframe = time + CFXM1014_FRAME_INTERVAL;

        W_CFXM1014Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfxm1014/fire.WAV", 2, ATTN_NORM);

        W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFXM1014Reload =
{
    // Shell-by-shell — TryReload sets weaponframe to SEQ_RELOAD_0 and
    // stamps the shell counter; the tick driver advances from there.
    if (SH_CFXM1014TryReload(time))
    {
        self.wep_nextframe = time + CFXM1014_FRAME_INTERVAL;
        self.cfxm1014_reload_snd_stage = 0;
    }
};

void() W_CFXM1014Frame =
{
    float result = 0;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += CFXM1014_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFXM1014_DRAW_CLACK_TIME && !self.cfxm1014_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfxm1014/draw.WAV", 1, ATTN_NORM);
            self.cfxm1014_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        // Each phase / shell re-stamps wep_anim_start, so `elapsed`
        // here measures time within the CURRENT sequence cycle.  The
        // snd_stage tracker is reset at each re-stamp by ReloadTick.
        if (self.cfxm1014_reload_phase == 1
            && self.cfxm1014_reload_snd_stage < 1
            && elapsed >= CFXM1014_RELOAD_BULLETIN_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfxm1014/clipin.WAV", 1, ATTN_NORM);
            self.cfxm1014_reload_snd_stage = 1;
        }
        else if (self.cfxm1014_reload_phase == 2
            && self.cfxm1014_reload_snd_stage < 1
            && elapsed >= CFXM1014_RELOAD_BBACK_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfxm1014/clipout.WAV", 1, ATTN_NORM);
            self.cfxm1014_reload_snd_stage = 1;
        }
    }

    // Drive reload state separately so WS_DRAW / WS_FIRE still hit
    // SH_CFXM1014TickState for their state-transition handling.
    if (self.weaponstate == WS_RELOAD)
        result = SH_CFXM1014ReloadTick(time);
    else
        result = SH_CFXM1014TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFXM1014_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfxm1014_reload_snd_stage = 0;
    }
};

void() W_CFXM1014Equip =
{
    W_StandardEquipSetup(CFXM1014_VIEWMODEL, CFXM1014_DISPLAY_NAME, CFXM1014_SEQ_DRAW,
        CFXM1014_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFXM1014Fire;
    self.reload   = W_CFXM1014Reload;
    self.wepframe = W_CFXM1014Frame;
    self.shoot    = W_CFXM1014Shoot;
    self.cfxm1014_draw_snd_played       = 0;
    self.cfxm1014_reload_snd_stage      = 0;
    self.cfxm1014_reload_shells_at_start = 0;
    self.cfxm1014_reload_shells_done    = 0;
    self.cfxm1014_reload_phase          = 0;
    W_SetCrosshairProfile(CFXM1014_SPREAD, 0, 320, 3, TRUE);
};

void() W_CFXM1014Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfxm1014  = self.mag_cfxm1014;
    tgt.ammo_cfxm1014 = self.ammo_cfxm1014;

    self.mag_cfxm1014  = 0;
    self.ammo_cfxm1014 = 0;

    setmodel(tgt, CFXM1014_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfxm1014";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFXM1014;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFXM1014Equip;
    tgt.weap_drop_func = W_CFXM1014Drop;
    tgt.pickupcopy    = W_CFXM1014PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfxm1014 =
{
    setmodel(self, CFXM1014_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfxm1014";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFXM1014;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFXM1014Equip;
    self.weap_drop_func = W_CFXM1014Drop;
    self.pickupcopy    = W_CFXM1014PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfxm1014  = MAX_MAG_CFXM1014;
    self.ammo_cfxm1014 = MAX_AMMO_CFXM1014;
    W_RegisterMapWeapon(weapon_cfxm1014);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfxm1014_draw_snd_played;
float csqc_cfxm1014_reload_snd_stage;
float csqc_cfxm1014_snd_action;

void() CSQC_PredictCFXM1014Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload / fire
    // fires its events exactly once even when pmove replay re-runs the
    // same buffered command.
    if (predicted_player.wep_action_id != csqc_cfxm1014_snd_action)
    {
        csqc_cfxm1014_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfxm1014_draw_snd_played  = 0;
        csqc_cfxm1014_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFXM1014TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfxm1014/fire.WAV", 2, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(CFXM1014_PELLETS, CFXM1014_SPREAD,
                    CFXM1014_PELLET_CLOSE_DAMAGE, CFXM1014_PELLET_MIN_DAMAGE,
                    CFXM1014_DAMAGE_FALLOFF_RANGE,
                    CFXM1014_KICK_PITCH, CFXM1014_KICK_VARIANCE, CFXM1014_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle (Bone01) — tracks the firing
                // animation instead of staying camera-fixed.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFXM1014_MUZZLE_BONE, CFXM1014_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, CFXM1014_PELLETS);
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

    // Predicted draw / reload sounds — match the server's W_CFXM1014Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfxm1014_draw_snd_played && elapsed >= CFXM1014_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfxm1014/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfxm1014_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            // Use the entity field (shared with the server-side tracker)
            // rather than the CSQC-only global so ReloadTick's per-phase
            // reset propagates here automatically.
            if (self.cfxm1014_reload_phase == 1
                && self.cfxm1014_reload_snd_stage < 1
                && elapsed >= CFXM1014_RELOAD_BULLETIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfxm1014/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfxm1014_reload_snd_stage = 1;
            }
            else if (self.cfxm1014_reload_phase == 2
                && self.cfxm1014_reload_snd_stage < 1
                && elapsed >= CFXM1014_RELOAD_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfxm1014/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfxm1014_reload_snd_stage = 1;
            }
        }
    }

    // Drive shell-by-shell reload locally so prediction matches server.
    if (self.weaponstate == WS_RELOAD)
        SH_CFXM1014ReloadTick(csqc_pred_time);
    SH_CFXM1014TickState(csqc_pred_time);
};

void() CSQC_PredictCFXM1014Reload =
{
    if (SH_CFXM1014TryReload(csqc_pred_time))
    {
        csqc_cfxm1014_reload_snd_stage = 0;
        csqc_cfxm1014_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFXM1014DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFXM1014_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFXM1014_SEQ_SHOOT1;
        return CFXM1014_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        // Phase-driven shell-by-shell render: server sets weaponframe
        // to the correct sequence at each phase transition.  CSQC
        // mirrors the same logic via SH_CFXM1014ReloadTick in the
        // predict path, so predicted_player.cfxm1014_reload_phase is
        // valid here.
        if (predicted_player.cfxm1014_reload_phase == 0)
            return CFXM1014_SEQ_RELOAD_0;
        if (predicted_player.cfxm1014_reload_phase == 1)
            return CFXM1014_SEQ_RELOAD_1;
        return CFXM1014_SEQ_RELOAD_2;
    }

    return CFXM1014_SEQ_IDLE;
};

void() CSQC_CFXM1014DropClear =
{
    self.mag_cfxm1014  = 0;
    self.ammo_cfxm1014 = 0;
};

void() CSQC_CFXM1014Equip =
{
    self.weapon_name         = CFXM1014_DISPLAY_NAME;
    self.weapon_viewmodel    = CFXM1014_VIEWMODEL;
    self.weapon_worldmodel   = CFXM1014_WORLDMODEL;
    self.weapon_deploy_sound = CFXM1014_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFXM1014Command;
    self.csqc_predict_reload = CSQC_PredictCFXM1014Reload;
    self.csqc_display_frame  = CSQC_CFXM1014DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFXM1014DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-stepping
    // branch and the model just sits at the first frame of whatever
    // sequence we set.
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    // Sway-pivot + muzzle anchor — bone-attached now.
    self.weapon_muzzle_bone   = CFXM1014_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFXM1014_MUZZLE_OFFSET;

    // Snapshot-driven equip suppress for the draw-clack: weaponstate at
    // this point is WS_IDLE / WS_DEAD on a snapshot-driven draw
    // (cl_player.qc sets WS_DRAW AFTER Equip), so latching the
    // draw-snd-played flag here means the predict path skips the local
    // draw-clack and lets the server's CHAN_AUTO emission play through
    // unsuppressed.  Local-prediction draw (CSQC_PredictSelectWeapon
    // sets WS_DRAW BEFORE Equip) skips this branch — predicted draw
    // sound still fires.  Mid-RELOAD / mid-FIRE reconciles also skip
    // (avoiding the HDAK47 collapsed-tracker bug — see commit history).
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfxm1014_draw_snd_played = 1;
        csqc_cfxm1014_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
