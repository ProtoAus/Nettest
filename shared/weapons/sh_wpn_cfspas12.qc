// ============================================================
//  shared/weapons/sh_wpn_cfspas12.qc  -  SPAS-12 (CF series)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell tube, 32 reserve, pump-action
//  Fire  : 9-pellet hitscan, linear damage falloff, ~0.88s pump cycle
//
//  Sequence-driven GoldSrc viewmodel (v_xm1014.mdl).  Setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally — same pattern as HDAK47 / CFM9 /
//  CFBarrett.  W_CFSPAS12Frame does NOT step weaponframe per tick.
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
//  for v_xm1014.mdl, swap these for CFSPAS12_MUZZLE_BONE +
//  CFSPAS12_MUZZLE_OFFSET and replace the AtMuzzle calls below with
//  the CSQC_ViewmodelAttachmentWorldPos / AtWorld pattern from HDAK47.
//
//  Per-reload sound trackers use SEPARATE fields (NOT a single
//  collapsed stage variable).  This is the CFM9 / CFBarrett pattern
//  — see the HDAK47 reload-sound bug fix commit for why the single-
//  variable approach corrupts state under the every-reconcile
//  CSQC_WeaponEquip call.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfspas12;
.float ammo_cfspas12;

// --- Per-entity sound stage trackers (server side) ---
.float cfspas12_draw_snd_played;
.float cfspas12_reload_snd_stage;
// Shell-by-shell reload state.  Stamped at reload start; both server
// and CSQC drive phase transitions from elapsed time + this baseline
// so visuals + sounds + mag/ammo updates stay in lockstep.
.float cfspas12_reload_shells_at_start;   // total shells to insert
.float cfspas12_reload_shells_done;       // shells already inserted this reload
.float cfspas12_reload_phase;             // 0 = reload_0, 1 = reload_1, 2 = reload_2

// --- Sequence indices ---
const float CFSPAS12_SEQ_IDLE     = 0;
const float CFSPAS12_SEQ_SHOOT1   = 1;
const float CFSPAS12_SEQ_SHOOT2   = 2;
const float CFSPAS12_SEQ_RELOAD_1 = 3;
const float CFSPAS12_SEQ_RELOAD_2 = 4;
const float CFSPAS12_SEQ_RELOAD_0 = 5;
const float CFSPAS12_SEQ_DRAW     = 6;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
// Reload_1 sequence @ 30 fps:
//   bulletin at frame 2 / 30 = 0.067s   — shell inserted
// Reload_2 sequence @ 20 fps  (unused by this simplified reload path —
//   kept as a constant for future shell-by-shell expansion):
//   bback    at frame 1 / 20 = 0.050s   — pump back
// Select sequence @ 30 fps:
//   reload   at frame 10 / 30 = 0.333s  — draw clack
const float CFSPAS12_RELOAD_BULLETIN_TIME = 0.067;
const float CFSPAS12_RELOAD_BBACK_TIME    = 0.050;
const float CFSPAS12_DRAW_CLACK_TIME      = 0.333;

// Ammo applies at the bulletin event — single-pass simplified reload.
// See file-top note re. pump-shotgun limitation.
const float CFSPAS12_RELOAD_APPLY_TIME    = 0.10;

// --- Gameplay tuning ---
const float CFSPAS12_FIRE_DELAY        = 0.88;   // pump cycle
const float CFSPAS12_DRYFIRE_DELAY     = 0.20;
const float CFSPAS12_FRAME_INTERVAL    = 0.05;   // state-machine tick rate

const float MAX_MAG_CFSPAS12           = 8;
const float MAX_AMMO_CFSPAS12          = 32;

// --- Balance ---
// 7-degree cone — tan(7°) ≈ 0.122, matched to this codebase's spread
// convention (radial multiplier on v_right / v_up, see W_M3FirePellets
// for the canonical pellet-spread shape).
const float CFSPAS12_PELLETS              = 9;
const float CFSPAS12_SPREAD               = 0.122;
const float CFSPAS12_PELLET_CLOSE_DAMAGE  = 22;
const float CFSPAS12_PELLET_MIN_DAMAGE    = 5;
const float CFSPAS12_DAMAGE_FALLOFF_RANGE = 1024;
// sv_gunkick — pump shotgun, big single-shot kick (long pump delay).
const float CFSPAS12_KICK_PITCH    = 2.6;
const float CFSPAS12_KICK_VARIANCE = 0.6;
const float CFSPAS12_KICK_STRENGTH = 1.6;

// Muzzle attachment from v_xm1014.mdl's $attachment 0:
//   $attachment 0 "Bone01" 29.0 0.0 1.2
const string CFSPAS12_MUZZLE_BONE   = "Bone01";
#define CFSPAS12_MUZZLE_OFFSET ('29.0 0.0 1.2')

const string CFSPAS12_VIEWMODEL    = "models/weapons/wpn_cfspas12/v_spas12.mdl";
const string CFSPAS12_WORLDMODEL   = "models/weapons/wpn_cfspas12/w_spas12.mdl";
const string CFSPAS12_DEPLOY_SOUND = "";
const string CFSPAS12_DISPLAY_NAME = "SPAS-12";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFSPAS12PickShootSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.5) return CFSPAS12_SEQ_SHOOT1;
    return CFSPAS12_SEQ_SHOOT2;
};

// SH_StandardTickState normally handles WS_RELOAD by applying mag/ammo
// at reload_apply_time and transitioning to WS_IDLE at reload_dur.  For
// shell-by-shell we drive WS_RELOAD ourselves (see SH_CFSPAS12ReloadTick)
// so we pass an enormous reload_dur to keep the standard helper from
// ever firing the auto-transition; the reload_apply_time stays at the
// per-shell value but the WS_RELOAD branch never reads it because the
// caller checks weaponstate before invoking SH_StandardTickState.
float(float now) SH_CFSPAS12TickState =
{
    if (self.weaponstate == WS_RELOAD)
        return 0;   // shell-by-shell drives the reload state itself
    return SH_StandardTickState(now, mag_cfspas12, ammo_cfspas12, MAX_MAG_CFSPAS12,
        SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_DRAW,     1.0),
        SH_SeqDuration(CFSPAS12_VIEWMODEL, self.weaponframe,      0.9),
        SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_RELOAD_1, 1.0),
        CFSPAS12_RELOAD_APPLY_TIME);
};

// Shared shell-by-shell driver.  Called from both W_CFSPAS12Frame
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
// Phase state lives in self.cfspas12_reload_phase (0/1/2).  Shell
// counter in self.cfspas12_reload_shells_done.
//
// Returns:
//   bit 0 = transition to idle just happened (reload done)
//   bit 1 = a shell was just inserted (mag/ammo updated)
float(float now) SH_CFSPAS12ReloadTick =
{
    if (self.weaponstate != WS_RELOAD)
        return 0;

    float elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    float shells_needed = self.cfspas12_reload_shells_at_start;
    float result = 0;

    // No shells to insert — skip straight to the pump close.
    if (shells_needed <= 0)
    {
        if (self.cfspas12_reload_phase != 2)
        {
            self.cfspas12_reload_phase = 2;
            self.weaponframe           = CFSPAS12_SEQ_RELOAD_2;
            self.wep_anim_start        = now;
            elapsed                    = 0;
        }
        float dur_2 = SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2)
        {
            self.weaponstate                 = WS_IDLE;
            self.weaponframe                 = CFSPAS12_SEQ_IDLE;
            self.wep_nextframe               = 0;
            self.wep_anim_start              = 0;
            self.cfspas12_reload_phase       = 0;
            self.cfspas12_reload_shells_done = 0;
            self.cfspas12_reload_snd_stage   = 0;
            return 1;
        }
        return 0;
    }

    // Phase 0 — reload_0 (start idle).  When its sequence ends,
    // transition to reload_1 for the first shell and re-stamp.
    if (self.cfspas12_reload_phase == 0)
    {
        float dur_0 = SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_RELOAD_0, 0.4);
        if (elapsed >= dur_0)
        {
            self.cfspas12_reload_phase     = 1;
            self.weaponframe               = CFSPAS12_SEQ_RELOAD_1;
            self.wep_anim_start            = now;
            self.cfspas12_reload_snd_stage = 0;
        }
        return 0;
    }

    // Phase 1 — shell insert.  When reload_1's sequence ends, apply
    // +1 mag / -1 ammo and either restart reload_1 for the next shell
    // or transition to reload_2.
    if (self.cfspas12_reload_phase == 1)
    {
        float dur_1 = SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_RELOAD_1, 1.0);
        if (elapsed >= dur_1)
        {
            self.cfspas12_reload_shells_done += 1;
            self.mag_cfspas12  += 1;
            self.ammo_cfspas12 -= 1;
            result = result | 2;

            if (self.cfspas12_reload_shells_done < shells_needed)
            {
                // Next shell — re-stamp anim start so the engine
                // restarts reload_1 from frame 0.
                self.wep_anim_start            = now;
                self.cfspas12_reload_snd_stage = 0;
            }
            else
            {
                // Last shell done — transition to reload_2.
                self.cfspas12_reload_phase     = 2;
                self.weaponframe               = CFSPAS12_SEQ_RELOAD_2;
                self.wep_anim_start            = now;
                self.cfspas12_reload_snd_stage = 0;
            }
        }
        return result;
    }

    // Phase 2 — reload_2 pump close.  When its sequence ends, return
    // to idle.
    if (self.cfspas12_reload_phase == 2)
    {
        float dur_2_close = SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_RELOAD_2, 0.5);
        if (elapsed >= dur_2_close)
        {
            self.weaponstate                 = WS_IDLE;
            self.weaponframe                 = CFSPAS12_SEQ_IDLE;
            self.wep_nextframe               = 0;
            self.wep_anim_start              = 0;
            self.cfspas12_reload_phase       = 0;
            self.cfspas12_reload_shells_done = 0;
            self.cfspas12_reload_snd_stage   = 0;
            result = result | 1;
        }
    }
    return result;
};

float(float now) SH_CFSPAS12TryFire =
{
    // Pump shotgun: FIRE_DELAY itself enforces single-shot pacing —
    // no semi-auto edge gate needed.  Same call as RIFLE / SMG path.
    return SH_StandardTryFire(now, mag_cfspas12, CFSPAS12_FIRE_DELAY, CFSPAS12_DRYFIRE_DELAY);
};

float(float now) SH_CFSPAS12TryReload =
{
    // Use a representative duration as the "reload window" hint for
    // SH_StandardTryReload's accept checks (mag-full, no-ammo, busy
    // gates).  Actual sequence pacing is owned by SH_CFSPAS12ReloadTick.
    float dur_hint = SH_SeqDuration(CFSPAS12_VIEWMODEL, CFSPAS12_SEQ_RELOAD_1, 1.0);
    float r = SH_StandardTryReload(now, mag_cfspas12, ammo_cfspas12, MAX_MAG_CFSPAS12, dur_hint);
    if (r)
    {
        // Stamp the shell-by-shell baseline so the tick driver can
        // advance phases off self.wep_anim_start (already set by the
        // standard helper).
        float shells = MAX_MAG_CFSPAS12 - self.mag_cfspas12;
        if (shells > self.ammo_cfspas12) shells = self.ammo_cfspas12;
        self.cfspas12_reload_shells_at_start = shells;
        self.cfspas12_reload_shells_done     = 0;
        self.cfspas12_reload_phase           = 0;
        self.weaponframe                     = CFSPAS12_SEQ_RELOAD_0;
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFSPAS12PickupCopy =
{
    player.mag_cfspas12  = self.mag_cfspas12;
    player.ammo_cfspas12 = self.ammo_cfspas12;
};

// Per-pellet hitscan — mirrors CSM3 / FlakShotgun's W_*FirePellets
// shape (no W_ShotgunHitscanShoot helper exists for sequence-driven
// shotguns; the pellet loop is short and well-tested inline).
void() W_CFSPAS12Shoot =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    // sv_gunkick — one impulse per trigger pull (not per pellet),
    // applied first so the trace direction below uses the kicked
    // aim.  Mirrors W_M3FirePellets / W_PenetratingHitscanShoot.
    SH_ApplyViewKick(CFSPAS12_KICK_PITCH, CFSPAS12_KICK_VARIANCE, CFSPAS12_KICK_STRENGTH);

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
    for (i = 0; i < CFSPAS12_PELLETS; i++)
    {
        sx  = SH_SpreadJitter(self.wep_action_id + i, 0) * CFSPAS12_SPREAD;
        sy  = SH_SpreadJitter(self.wep_action_id + i, 1) * CFSPAS12_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist,
                CFSPAS12_PELLET_CLOSE_DAMAGE, CFSPAS12_PELLET_MIN_DAMAGE,
                CFSPAS12_DAMAGE_FALLOFF_RANGE);
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

void() W_CFSPAS12Fire =
{
    float r = SH_CFSPAS12TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFSPAS12PickShootSeq();
        self.wep_nextframe = time + CFSPAS12_FRAME_INTERVAL;

        W_CFSPAS12Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfspas12/fire.WAV", 2, ATTN_NORM);

        W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFSPAS12Reload =
{
    // Shell-by-shell — TryReload sets weaponframe to SEQ_RELOAD_0 and
    // stamps the shell counter; the tick driver advances from there.
    if (SH_CFSPAS12TryReload(time))
    {
        self.wep_nextframe = time + CFSPAS12_FRAME_INTERVAL;
        self.cfspas12_reload_snd_stage = 0;
    }
};

void() W_CFSPAS12Frame =
{
    float result = 0;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO so
    // the predicted-sound dedup window matches CSQC_RecordPredictedAuto-
    // Sound on the client (using CHAN_WEAPON would collide with the
    // fire-sound dedup).
    self.wep_nextframe += CFSPAS12_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFSPAS12_DRAW_CLACK_TIME && !self.cfspas12_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfspas12/draw.WAV", 1, ATTN_NORM);
            self.cfspas12_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        // Each phase / shell re-stamps wep_anim_start, so `elapsed`
        // here measures time within the CURRENT sequence cycle.  The
        // snd_stage tracker is reset at each re-stamp by ReloadTick.
        if (self.cfspas12_reload_phase == 1
            && self.cfspas12_reload_snd_stage < 1
            && elapsed >= CFSPAS12_RELOAD_BULLETIN_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfspas12/clipin.WAV", 1, ATTN_NORM);
            self.cfspas12_reload_snd_stage = 1;
        }
        else if (self.cfspas12_reload_phase == 2
            && self.cfspas12_reload_snd_stage < 1
            && elapsed >= CFSPAS12_RELOAD_BBACK_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfspas12/clipout.WAV", 1, ATTN_NORM);
            self.cfspas12_reload_snd_stage = 1;
        }
    }

    // Drive reload state separately so WS_DRAW / WS_FIRE still hit
    // SH_CFSPAS12TickState for their state-transition handling.
    if (self.weaponstate == WS_RELOAD)
        result = SH_CFSPAS12ReloadTick(time);
    else
        result = SH_CFSPAS12TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFSPAS12_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfspas12_reload_snd_stage = 0;
    }
};

void() W_CFSPAS12Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_spas12", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(CFSPAS12_VIEWMODEL, CFSPAS12_DISPLAY_NAME, CFSPAS12_SEQ_DRAW,
        CFSPAS12_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFSPAS12Fire;
    self.reload   = W_CFSPAS12Reload;
    self.wepframe = W_CFSPAS12Frame;
    self.shoot    = W_CFSPAS12Shoot;
    self.cfspas12_draw_snd_played       = 0;
    self.cfspas12_reload_snd_stage      = 0;
    self.cfspas12_reload_shells_at_start = 0;
    self.cfspas12_reload_shells_done    = 0;
    self.cfspas12_reload_phase          = 0;
    W_SetCrosshairProfile(CFSPAS12_SPREAD, 0, 320, 3, TRUE);
};

void() W_CFSPAS12Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfspas12  = self.mag_cfspas12;
    tgt.ammo_cfspas12 = self.ammo_cfspas12;

    self.mag_cfspas12  = 0;
    self.ammo_cfspas12 = 0;

    setmodel(tgt, CFSPAS12_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfspas12";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFSPAS12;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFSPAS12Equip;
    tgt.weap_drop_func = W_CFSPAS12Drop;
    tgt.pickupcopy    = W_CFSPAS12PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfspas12 =
{
    setmodel(self, CFSPAS12_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfspas12";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFSPAS12;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFSPAS12Equip;
    self.weap_drop_func = W_CFSPAS12Drop;
    self.pickupcopy    = W_CFSPAS12PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfspas12  = MAX_MAG_CFSPAS12;
    self.ammo_cfspas12 = MAX_AMMO_CFSPAS12;
    W_RegisterMapWeapon(weapon_cfspas12);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfspas12_draw_snd_played;
float csqc_cfspas12_reload_snd_stage;
float csqc_cfspas12_snd_action;

void() CSQC_PredictCFSPAS12Command =
{
    float r;
    float elapsed;

    // Reset sound-stage on action change so each draw / reload / fire
    // fires its events exactly once even when pmove replay re-runs the
    // same buffered command.
    if (predicted_player.wep_action_id != csqc_cfspas12_snd_action)
    {
        csqc_cfspas12_snd_action       = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfspas12_draw_snd_played  = 0;
        csqc_cfspas12_reload_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFSPAS12TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfspas12/fire.WAV", 2, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(CFSPAS12_PELLETS, CFSPAS12_SPREAD,
                    CFSPAS12_PELLET_CLOSE_DAMAGE, CFSPAS12_PELLET_MIN_DAMAGE,
                    CFSPAS12_DAMAGE_FALLOFF_RANGE,
                    CFSPAS12_KICK_PITCH, CFSPAS12_KICK_VARIANCE, CFSPAS12_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Bone-attached muzzle (Bone01) — tracks the firing
                // animation instead of staying camera-fixed.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFSPAS12_MUZZLE_BONE, CFSPAS12_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, CFSPAS12_PELLETS);
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

    // Predicted draw / reload sounds — match the server's W_CFSPAS12Frame
    // timings exactly so the dedup window suppresses the server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfspas12_draw_snd_played && elapsed >= CFSPAS12_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfspas12/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfspas12_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            // Use the entity field (shared with the server-side tracker)
            // rather than the CSQC-only global so ReloadTick's per-phase
            // reset propagates here automatically.
            if (self.cfspas12_reload_phase == 1
                && self.cfspas12_reload_snd_stage < 1
                && elapsed >= CFSPAS12_RELOAD_BULLETIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfspas12/clipin.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfspas12_reload_snd_stage = 1;
            }
            else if (self.cfspas12_reload_phase == 2
                && self.cfspas12_reload_snd_stage < 1
                && elapsed >= CFSPAS12_RELOAD_BBACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfspas12/clipout.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfspas12_reload_snd_stage = 1;
            }
        }
    }

    // Drive shell-by-shell reload locally so prediction matches server.
    if (self.weaponstate == WS_RELOAD)
        SH_CFSPAS12ReloadTick(csqc_pred_time);
    SH_CFSPAS12TickState(csqc_pred_time);
};

void() CSQC_PredictCFSPAS12Reload =
{
    if (SH_CFSPAS12TryReload(csqc_pred_time))
    {
        csqc_cfspas12_reload_snd_stage = 0;
        csqc_cfspas12_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_CFSPAS12DisplayFrame =
{
    float r;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFSPAS12_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.5) return CFSPAS12_SEQ_SHOOT1;
        return CFSPAS12_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        // Phase-driven shell-by-shell render: server sets weaponframe
        // to the correct sequence at each phase transition.  CSQC
        // mirrors the same logic via SH_CFSPAS12ReloadTick in the
        // predict path, so predicted_player.cfspas12_reload_phase is
        // valid here.
        if (predicted_player.cfspas12_reload_phase == 0)
            return CFSPAS12_SEQ_RELOAD_0;
        if (predicted_player.cfspas12_reload_phase == 1)
            return CFSPAS12_SEQ_RELOAD_1;
        return CFSPAS12_SEQ_RELOAD_2;
    }

    return CFSPAS12_SEQ_IDLE;
};

void() CSQC_CFSPAS12DropClear =
{
    self.mag_cfspas12  = 0;
    self.ammo_cfspas12 = 0;
};

void() CSQC_CFSPAS12Equip =
{
    W_SetADSProfile(TRUE, "cl_ads_spas12", SCOPE_CLASS_NONE);
    self.weapon_name         = CFSPAS12_DISPLAY_NAME;
    self.weapon_viewmodel    = CFSPAS12_VIEWMODEL;
    self.weapon_worldmodel   = CFSPAS12_WORLDMODEL;
    self.weapon_deploy_sound = CFSPAS12_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFSPAS12Command;
    self.csqc_predict_reload = CSQC_PredictCFSPAS12Reload;
    self.csqc_display_frame  = CSQC_CFSPAS12DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFSPAS12DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-stepping
    // branch and the model just sits at the first frame of whatever
    // sequence we set.
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;
    // Sway-pivot + muzzle anchor — bone-attached now.
    self.weapon_muzzle_bone   = CFSPAS12_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFSPAS12_MUZZLE_OFFSET;

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
        csqc_cfspas12_draw_snd_played = 1;
        csqc_cfspas12_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
