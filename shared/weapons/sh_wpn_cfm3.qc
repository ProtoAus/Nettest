// ============================================================
//  shared/weapons/sh_wpn_cfm3.qc  -  Winchester (CF series, pump shotgun)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 7-shell tube, 28 reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//          FIRE_DELAY = 0.88s paces the pump cycle; the embedded
//          post-fire pump sound (reload.wav at sequence event 5004
//          frame 18 / 35fps = 0.514s) emits well inside that window.
//
//  Sequence-driven GoldSrc viewmodel (v_winchester.mdl) — setting
//  self.weaponframe = N plays sequence N as a whole and the engine
//  animates it internally.  Same pattern as HDAK47 / CFFamas /
//  CFAwp.  W_CFM3Frame does NOT step weaponframe per tick.
//
//  Sequence layout (from v_winchester.mdl source .qc):
//      0  idle_0    30 fps
//      1  prefire   35 fps  (shoot variant A — event 5001 "31";
//                            post-fire pump event 5004 @ frame 18)
//      2  prefire   35 fps  (shoot variant B)
//      3  reload_1  30 fps  (event 5004 @ frame 4 -> bulletin.wav)
//      4  reload_2  20 fps  (event 5004 @ frame 6 -> reload.wav pump)
//      5  reload_0   8 fps  (in-reload idle — not driven explicitly)
//      6  select    30 fps  (event 5004 @ frame 2 -> select.wav)
//
//  Note on $sequence event 5004 markers: FTE does NOT auto-play
//  them, so every audible sound is emitted from QC via elapsed-time
//  comparisons — same approach the rest of the CF / HDAK lineup uses.
//
//  Per-reload sound trackers use SEPARATE fields (.cfm3_draw_snd_played
//  and .cfm3_reload_snd_stage / .cfm3_post_fire_pump_played) — NOT
//  a single collapsed stage variable.  See the HDAK47 reload-sound
//  bug fix commit for why the single-variable approach corrupts
//  state under the every-reconcile CSQC_WeaponEquip call.
//
//  SHELL-BY-SHELL RELOAD LIMITATION (same as cfxm1014): a single R
//  press loads exactly ONE shell.  To refill all 7 chambers the
//  player must press R seven times.  Reload_1 inserts the shell
//  (bulletin.wav); reload_2 caps the cycle (reload.wav pump).
//  If the orchestrator later wants the CSM3-style auto-loop, the
//  WS_RELOAD branch needs a restart gate that re-stamps
//  wep_anim_start while mag < max && ammo > 0 — see CSM3's
//  M3_RELOAD_LOOP_RESTART path for the template.
//
//  Bone-attached muzzle: $attachment 0 "Bone01" 24 0 0 — the flash
//  and tracer track the firing animation instead of sitting at a
//  static camera-local offset.  Mirrors HDAK47 / CFFamas / CFMac10.
//  Static (non-animated) flash sprite — shotgun muzzle reads heavier
//  with the single-frame variant.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_cfm3;
.float ammo_cfm3;

// --- Per-entity sound stage trackers (server side) ---
.float cfm3_draw_snd_played;
.float cfm3_reload_snd_stage;
.float cfm3_post_fire_pump_played;
// Shell-by-shell reload state — same scheme as cfxm1014 (SPAS-12).
// wep_anim_start is re-stamped at each phase transition so the
// engine's frame1time rewinds and the looped reload_1 plays fresh
// for each shell.
.float cfm3_reload_shells_at_start;
.float cfm3_reload_shells_done;
.float cfm3_reload_phase;   // 0 = reload_0, 1 = reload_1, 2 = reload_2

// --- Sequence indices ---
const float CFM3_SEQ_IDLE      = 0;
const float CFM3_SEQ_SHOOT1    = 1;
const float CFM3_SEQ_SHOOT2    = 2;
const float CFM3_SEQ_RELOAD1   = 3;   // bulletin (shell insert)
const float CFM3_SEQ_RELOAD2   = 4;   // pump (chamber)
const float CFM3_SEQ_RELOAD0   = 5;   // in-reload idle (unused as state)
const float CFM3_SEQ_DRAW      = 6;

// --- Sound event timings (elapsed seconds from wep_anim_start) ---
//   shoot1/2  pump      @ frame 18 / 35 fps = 0.514s  (reload.wav)
//   reload_1  bulletin  @ frame  4 / 30 fps = 0.133s  (bulletin.wav)
//   reload_2  pump      @ frame  6 / 20 fps = 0.300s  (reload.wav)
//                       (offset is into reload_2's own elapsed window,
//                        not the whole reload — see W_CFM3Frame)
//   select    clack     @ frame  2 / 30 fps = 0.067s  (select.wav)
const float CFM3_FIRE_PUMP_TIME       = 0.514;
const float CFM3_RELOAD_BULLETIN_TIME = 0.133;
const float CFM3_RELOAD_PUMP_TIME     = 0.300;
const float CFM3_DRAW_CLACK_TIME      = 0.067;

// Shell applied at the bulletin frame (mag visually catches the shell).
const float CFM3_RELOAD_APPLY_TIME    = 0.133;

// --- Gameplay tuning ---
const float CFM3_FIRE_DELAY        = 0.88;   // pump cycle cadence
const float CFM3_DRYFIRE_DELAY     = 0.20;
const float CFM3_FRAME_INTERVAL    = 0.05;   // state-machine tick rate

const float MAX_MAG_CFM3           = 7;
const float MAX_AMMO_CFM3          = 28;

// --- Balance ---
// Winchester reclassified as a single-bullet rifle (lever-action) —
// routes through W_PenetratingHitscanShoot / CSQC_PredictedPenetratingImpact
// like the CF rifles.  Tuning mirrors CFGALIL but heavier per-shot:
// slow cadence, higher close damage, longer falloff.
const float CFM3_BASE_SPREAD           = 0.010;
const float CFM3_MOVE_SPREAD           = 0.08;
const float CFM3_FULL_SPREAD_SPEED     = 320;
const float CFM3_CLOSE_DAMAGE          = 60;
const float CFM3_MIN_DAMAGE            = 30;
const float CFM3_DAMAGE_FALLOFF_RANGE  = 4096;
const float CFM3_PENETRATION_MAX       = 32;
const float CFM3_PENETRATION_LOSS      = 0.97;
// sv_gunkick — pump shotgun, big single-shot kick.
const float CFM3_KICK_PITCH    = 2.6;
const float CFM3_KICK_VARIANCE = 0.6;
const float CFM3_KICK_STRENGTH = 1.6;

// Muzzle attachment — sourced from v_winchester.mdl's $attachment 0:
//     $attachment 0 "Bone01" 24.0 0.0 0.0
// Bone-attached so the static flash + tracer track the pump animation
// instead of sitting at a camera-relative offset.  Mirrors HDAK47 /
// CFFamas / CFMac10.
const string CFM3_MUZZLE_BONE   = "Bone01";
#define CFM3_MUZZLE_OFFSET ('24.0 0.0 0.0')

const string CFM3_VIEWMODEL    = "models/weapons/wpn_cfm3/v_m3.mdl";
const string CFM3_WORLDMODEL   = "models/weapons/wpn_cfm3/w_m3.mdl";
const string CFM3_DEPLOY_SOUND = "";
const string CFM3_DISPLAY_NAME = "Winchester";

// ============================================================
//  SHARED — sequence pick + state-machine helpers
// ============================================================

// Deterministic shoot-sequence pick from wep_action_id so client and
// server agree which of shoot1/2 plays for this shot.
float() SH_CFM3PickShootSeq =
{
    return (SH_SpreadHash(self.wep_action_id) < 0.5)
            ? CFM3_SEQ_SHOOT1
            : CFM3_SEQ_SHOOT2;
};

// Helper: total reload duration is reload_1 + reload_2 played back to
// back.  Both queried at runtime via SH_SeqDuration so the gameplay
// layer follows the artist's retimes.
float() SH_CFM3ReloadDuration =
{
    return SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD1, 0.7)
         + SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD2, 0.5);
};

// Custom tick state — skips WS_RELOAD entirely; the shell-by-shell
// driver SH_CFM3ReloadTick owns reload pacing + mag/ammo updates.
// Returns bitmask: bit 0 = transitioned to idle, bit 1 = ammo applied.
float(float now) SH_CFM3TickState =
{
    float elapsed, result, draw_dur, fire_dur, reload_dur;

    if (self.weaponstate == WS_IDLE)
        return 0;
    if (self.weaponstate == WS_RELOAD)
        return 0;   // driven by SH_CFM3ReloadTick

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    result  = 0;

    if (self.weaponstate == WS_DRAW)
    {
        draw_dur = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_DRAW, 1.0);
        if (elapsed >= draw_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        fire_dur = SH_SeqDuration(CFM3_VIEWMODEL, self.weaponframe, 0.5);
        if (elapsed >= fire_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

// Shell-by-shell reload driver — same shape as the SPAS-12's
// SH_CFXM1014ReloadTick.  Phases:
//   0 = playing reload_0 (in-reload idle / pre-load)
//   1 = playing reload_1 (shell insert, looped per shell)
//   2 = playing reload_2 (pump close)
// Re-stamps self.wep_anim_start at every sequence boundary so the
// engine restarts each animation from frame 0 — required because the
// engine doesn't re-trigger a sequence when weaponframe is set to the
// SAME value (looping reload_1 between shells).
//
// Returns bitmask:
//   bit 0 = reload done (transition to idle)
//   bit 1 = a shell was just applied
float(float now) SH_CFM3ReloadTick =
{
    if (self.weaponstate != WS_RELOAD)
        return 0;

    float elapsed_in_seq = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    float shells_needed = self.cfm3_reload_shells_at_start;
    float result = 0;

    // Nothing to insert — skip to pump close.
    if (shells_needed <= 0)
    {
        if (self.cfm3_reload_phase != 2)
        {
            self.cfm3_reload_phase = 2;
            self.weaponframe       = CFM3_SEQ_RELOAD2;
            self.wep_anim_start    = now;
            elapsed_in_seq         = 0;
        }
        float dur_r2 = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD2, 0.5);
        if (elapsed_in_seq >= dur_r2)
        {
            self.weaponstate              = WS_IDLE;
            self.weaponframe              = CFM3_SEQ_IDLE;
            self.wep_nextframe            = 0;
            self.wep_anim_start           = 0;
            self.cfm3_reload_phase        = 0;
            self.cfm3_reload_shells_done  = 0;
            self.cfm3_reload_snd_stage    = 0;
            return 1;
        }
        return 0;
    }

    // Phase 0 — pre-load idle (reload_0).
    if (self.cfm3_reload_phase == 0)
    {
        float dur_r0 = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD0, 0.4);
        if (elapsed_in_seq >= dur_r0)
        {
            self.cfm3_reload_phase     = 1;
            self.weaponframe           = CFM3_SEQ_RELOAD1;
            self.wep_anim_start        = now;
            self.cfm3_reload_snd_stage = 0;
        }
        return 0;
    }

    // Phase 1 — shell insert loop.
    if (self.cfm3_reload_phase == 1)
    {
        float dur_r1 = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD1, 1.0);
        if (elapsed_in_seq >= dur_r1)
        {
            self.cfm3_reload_shells_done += 1;
            self.mag_cfm3  += 1;
            self.ammo_cfm3 -= 1;
            result = result | 2;

            if (self.cfm3_reload_shells_done < shells_needed)
            {
                // Next shell — re-stamp so reload_1 restarts.
                self.wep_anim_start        = now;
                self.cfm3_reload_snd_stage = 0;
            }
            else
            {
                self.cfm3_reload_phase     = 2;
                self.weaponframe           = CFM3_SEQ_RELOAD2;
                self.wep_anim_start        = now;
                self.cfm3_reload_snd_stage = 0;
            }
        }
        return result;
    }

    // Phase 2 — pump close.
    if (self.cfm3_reload_phase == 2)
    {
        float dur_r2_close = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD2, 0.5);
        if (elapsed_in_seq >= dur_r2_close)
        {
            self.weaponstate              = WS_IDLE;
            self.weaponframe              = CFM3_SEQ_IDLE;
            self.wep_nextframe            = 0;
            self.wep_anim_start           = 0;
            self.cfm3_reload_phase        = 0;
            self.cfm3_reload_shells_done  = 0;
            self.cfm3_reload_snd_stage    = 0;
            result = result | 1;
        }
    }
    return result;
};

float(float now) SH_CFM3TryFire =
{
    // Pump-action: FIRE_DELAY alone paces the cycle.  No semi-auto
    // edge gate needed — holding +attack still respects the 0.88s
    // gap because attack_finished is stamped each shot.
    return SH_StandardTryFire(now, mag_cfm3, CFM3_FIRE_DELAY, CFM3_DRYFIRE_DELAY);
};

float(float now) SH_CFM3TryReload =
{
    float r = SH_StandardTryReload(now, mag_cfm3, ammo_cfm3, MAX_MAG_CFM3,
        SH_CFM3ReloadDuration());
    if (r)
    {
        float shells = MAX_MAG_CFM3 - self.mag_cfm3;
        if (shells > self.ammo_cfm3) shells = self.ammo_cfm3;
        self.cfm3_reload_shells_at_start = shells;
        self.cfm3_reload_shells_done     = 0;
        self.cfm3_reload_phase           = 0;
        self.weaponframe                 = CFM3_SEQ_RELOAD0;
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CFM3PickupCopy =
{
    player.mag_cfm3  = self.mag_cfm3;
    player.ammo_cfm3 = self.ammo_cfm3;
};

// Single-bullet penetrating hitscan — Winchester runs the rifle path
// (W_PenetratingHitscanShoot) since the reclassification.  Same shape
// as CFGALIL / CFFAMAS so behaviour stays consistent across the CF
// rifle line.
void() W_CFM3Shoot =
{
    W_PenetratingHitscanShoot(CFM3_BASE_SPREAD, CFM3_MOVE_SPREAD, CFM3_FULL_SPREAD_SPEED,
        CFM3_CLOSE_DAMAGE, CFM3_MIN_DAMAGE, CFM3_DAMAGE_FALLOFF_RANGE,
        CFM3_PENETRATION_MAX, CFM3_PENETRATION_LOSS,
        CFM3_KICK_PITCH, CFM3_KICK_VARIANCE, CFM3_KICK_STRENGTH);
};

void() W_CFM3Fire =
{
    float r = SH_CFM3TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_CFM3PickShootSeq();
        self.wep_nextframe = time + CFM3_FRAME_INTERVAL;
        self.cfm3_post_fire_pump_played = 0;

        W_CFM3Shoot();

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm3/fire.WAV", 1, ATTN_NORM);

        // Match pump-cycle eject below — lever-action chamber is the
        // same case in both paths (fire writes, pump physically ejects).
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CFM3Reload =
{
    // Shell-by-shell — TryReload sets weaponframe to SEQ_RELOAD0 and
    // stamps the shell counter; the tick driver advances from there.
    if (SH_CFM3TryReload(time))
    {
        self.wep_nextframe = time + CFM3_FRAME_INTERVAL;
        self.cfm3_reload_snd_stage = 0;
    }
};

void() W_CFM3Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;
    float reload1_dur = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD1, 0.7);

    // Sequence-driven model — DO NOT step weaponframe per tick.  Only
    // tick the state machine and fire timed sound events.  CHAN_AUTO
    // for reload-side cues so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.  Fire
    // sound stays CHAN_WEAPON (emitted in W_CFM3Fire above) so it
    // dedups against the CHAN_WEAPON predicted-weapon-sound window.
    self.wep_nextframe += CFM3_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFM3_DRAW_CLACK_TIME && !self.cfm3_draw_snd_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm3/draw.WAV", 1, ATTN_NORM);
            self.cfm3_draw_snd_played = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // Post-fire pump — embedded inside the prefire sequence at
        // frame 18 / 35 fps.  Sits ~0.37s inside the 0.88s fire delay
        // so the pump always finishes before the next shot can be
        // queued.  reload.wav doubles as the pump SFX (same file the
        // reload_2 stage emits) — that's the source mdl's choice.
        if (elapsed >= CFM3_FIRE_PUMP_TIME && !self.cfm3_post_fire_pump_played)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm3/reload.WAV", 1, ATTN_NORM);
            // Lever-action chambers a fat straight-walled rifle case
            // (.30-30 / .45-70 / .44 Mag — none of which are shotgun
            // shells).  SHELL_RIFLE_BIG (riflecasingbig.mdl) is the
            // closest visual match; the prior SHELL_SHOTGUN1 ejected a
            // CS-style 12 ga hull which looked completely wrong.
            W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
            self.cfm3_post_fire_pump_played = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        // Each phase / shell re-stamps wep_anim_start, so `elapsed`
        // here is time within the current sequence cycle.  Sound stage
        // is reset by ReloadTick at each boundary.
        if (self.cfm3_reload_phase == 1
            && self.cfm3_reload_snd_stage < 1
            && elapsed >= CFM3_RELOAD_BULLETIN_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm3/bulletin.WAV", 1, ATTN_NORM);
            self.cfm3_reload_snd_stage = 1;
        }
        else if (self.cfm3_reload_phase == 2
            && self.cfm3_reload_snd_stage < 1
            && elapsed >= CFM3_RELOAD_PUMP_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_cfm3/reload.WAV", 1, ATTN_NORM);
            self.cfm3_reload_snd_stage = 1;
        }
    }

    // Drive reload state separately from DRAW/FIRE state.  The standard
    // tick state handles DRAW->IDLE and FIRE->IDLE; the shell-by-shell
    // driver owns RELOAD->IDLE.  SH_CFM3TickState short-circuits when
    // weaponstate is WS_RELOAD so they don't clash.
    if (self.weaponstate == WS_RELOAD)
        result = SH_CFM3ReloadTick(time);
    else
        result = SH_CFM3TickState(time);
    if (result & 1)
    {
        self.weaponframe   = CFM3_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.cfm3_reload_snd_stage = 0;
        self.cfm3_post_fire_pump_played = 0;
    }
};

void() W_CFM3Equip =
{
    W_StandardEquipSetup(CFM3_VIEWMODEL, CFM3_DISPLAY_NAME, CFM3_SEQ_DRAW,
        CFM3_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFM3Fire;
    self.reload   = W_CFM3Reload;
    self.wepframe = W_CFM3Frame;
    self.shoot    = W_CFM3Shoot;
    self.cfm3_draw_snd_played       = 0;
    self.cfm3_reload_snd_stage      = 0;
    self.cfm3_post_fire_pump_played = 0;
    W_SetCrosshairProfile(CFM3_BASE_SPREAD, CFM3_MOVE_SPREAD, CFM3_FULL_SPREAD_SPEED, 3, TRUE);
};

void() W_CFM3Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_cfm3  = self.mag_cfm3;
    tgt.ammo_cfm3 = self.ammo_cfm3;

    self.mag_cfm3  = 0;
    self.ammo_cfm3 = 0;

    setmodel(tgt, CFM3_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    tgt.classname     = "weapon_cfm3";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFM3;
    tgt.weapon_slot   = SLOT_PRIMARY;
    tgt.weap_draw     = W_CFM3Equip;
    tgt.weap_drop_func = W_CFM3Drop;
    tgt.pickupcopy    = W_CFM3PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfm3 =
{
    setmodel(self, CFM3_WORLDMODEL);
    // setsize removed - engine uses the model's $bbox set by setmodel().
    self.classname     = "weapon_cfm3";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_CFM3;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_CFM3Equip;
    self.weap_drop_func = W_CFM3Drop;
    self.pickupcopy    = W_CFM3PickupCopy;
    self.touch         = weapon_touch;
    self.mag_cfm3      = MAX_MAG_CFM3;
    self.ammo_cfm3     = MAX_AMMO_CFM3;
    W_RegisterMapWeapon(weapon_cfm3);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_cfm3_draw_snd_played;
float csqc_cfm3_reload_snd_stage;
float csqc_cfm3_post_fire_pump_played;
float csqc_cfm3_snd_action;

void() CSQC_PredictCFM3Command =
{
    float r;
    float elapsed;
    float reload1_dur = SH_SeqDuration(CFM3_VIEWMODEL, CFM3_SEQ_RELOAD1, 0.7);

    // Reset sound-stage on action change so each draw / fire / reload
    // fires its events exactly once even when pmove replay re-runs
    // the same buffered command.
    if (predicted_player.wep_action_id != csqc_cfm3_snd_action)
    {
        csqc_cfm3_snd_action            = predicted_player.wep_action_id;
        // Snapshot-driven draws bump wep_action_id AFTER
        // CSQC_<Wep>Equip's suppress latch was set — don't
        // undo it here in WS_DRAW or the predicted draw sound
        // fires alongside the server's CHAN_AUTO broadcast.
        if (predicted_player.weaponstate != WS_DRAW)
            csqc_cfm3_draw_snd_played  = 0;
        csqc_cfm3_reload_snd_stage      = 0;
        csqc_cfm3_post_fire_pump_played = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_CFM3TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_cfm3_post_fire_pump_played = 0;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_cfm3/fire.WAV", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(CFM3_BASE_SPREAD, CFM3_MOVE_SPREAD, CFM3_FULL_SPREAD_SPEED,
                    CFM3_CLOSE_DAMAGE, CFM3_MIN_DAMAGE, CFM3_DAMAGE_FALLOFF_RANGE,
                    CFM3_PENETRATION_MAX, CFM3_PENETRATION_LOSS,
                    CFM3_KICK_PITCH, CFM3_KICK_VARIANCE, CFM3_KICK_STRENGTH);
                // Bone-attached static muzzle flash + smoke — sampled
                // from v_winchester.mdl's $attachment 0 (Bone01) so
                // the flash tracks the pump animation.  Tracer start
                // follows automatically via CSQC_MuzzleFlashWorldPos.
                vector muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                    CFM3_MUZZLE_BONE, CFM3_MUZZLE_OFFSET);
                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, 1);
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

    // Predicted draw / fire-pump / reload sounds — match the server's
    // W_CFM3Frame timings exactly so the dedup window suppresses the
    // server echo.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (!csqc_cfm3_draw_snd_played && elapsed >= CFM3_DRAW_CLACK_TIME)
            {
                localsound("sounds/weapons/wpn_cfm3/draw.WAV");
                CSQC_RecordPredictedAutoSound();
                csqc_cfm3_draw_snd_played = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            // Post-fire pump sfx + casing — mirrors the server's
            // CFM3_FIRE_PUMP_TIME emission on CHAN_AUTO.
            if (!csqc_cfm3_post_fire_pump_played && elapsed >= CFM3_FIRE_PUMP_TIME)
            {
                localsound("sounds/weapons/wpn_cfm3/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                csqc_cfm3_post_fire_pump_played = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            // Each phase / shell re-stamps wep_anim_start so elapsed
            // here is time within the current sequence cycle.
            // self.cfm3_reload_snd_stage is the shared entity field
            // (reset by ReloadTick at each boundary).
            if (self.cfm3_reload_phase == 1
                && self.cfm3_reload_snd_stage < 1
                && elapsed >= CFM3_RELOAD_BULLETIN_TIME)
            {
                localsound("sounds/weapons/wpn_cfm3/bulletin.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfm3_reload_snd_stage = 1;
            }
            else if (self.cfm3_reload_phase == 2
                && self.cfm3_reload_snd_stage < 1
                && elapsed >= CFM3_RELOAD_PUMP_TIME)
            {
                localsound("sounds/weapons/wpn_cfm3/reload.WAV");
                CSQC_RecordPredictedAutoSound();
                self.cfm3_reload_snd_stage = 1;
            }
        }
    }

    if (self.weaponstate == WS_RELOAD)
        SH_CFM3ReloadTick(csqc_pred_time);
    SH_CFM3TickState(csqc_pred_time);
};

void() CSQC_PredictCFM3Reload =
{
    if (SH_CFM3TryReload(csqc_pred_time))
    {
        csqc_cfm3_reload_snd_stage = 0;
        csqc_cfm3_snd_action       = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// GoldSrc viewmodel: return sequence index directly; FTE animates the
// sequence internally using .frame1time.  Reload stage is read off
// the elapsed window so the client renders reload_1 -> reload_2 in
// lockstep with the server's W_CFM3Frame transition.
float(float elapsed) CSQC_CFM3DisplayFrame =
{
    float reload1_dur;

    if (predicted_player.weaponstate == WS_DRAW)
        return CFM3_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        return (SH_SpreadHash(predicted_player.wep_action_id) < 0.5)
                ? CFM3_SEQ_SHOOT1
                : CFM3_SEQ_SHOOT2;
    }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        // Phase-driven shell-by-shell render — both server and CSQC
        // run SH_CFM3ReloadTick so predicted_player.cfm3_reload_phase
        // is valid here.
        if (predicted_player.cfm3_reload_phase == 0)
            return CFM3_SEQ_RELOAD0;
        if (predicted_player.cfm3_reload_phase == 1)
            return CFM3_SEQ_RELOAD1;
        return CFM3_SEQ_RELOAD2;
    }

    return CFM3_SEQ_IDLE;
};

void() CSQC_CFM3DropClear =
{
    self.mag_cfm3  = 0;
    self.ammo_cfm3 = 0;
};

void() CSQC_CFM3Equip =
{
    self.weapon_name         = CFM3_DISPLAY_NAME;
    self.weapon_viewmodel    = CFM3_VIEWMODEL;
    self.weapon_worldmodel   = CFM3_WORLDMODEL;
    self.weapon_deploy_sound = CFM3_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFM3Command;
    self.csqc_predict_reload = CSQC_PredictCFM3Reload;
    self.csqc_display_frame  = CSQC_CFM3DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFM3DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index, the
    // engine animates within the sequence using .frame1time.  Without
    // this flag CSQC_AddPredictedViewmodel falls into the frame-
    // stepping branch and the model just sits at the first frame of
    // whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // Left-handed source model — RF_XFLIP mirrors the viewmodel.
    self.weapon_viewmodel_flip = TRUE;

    // Sway-pivot + muzzle anchor — same constants the fire path uses
    // for CSQC_ViewmodelAttachmentWorldPos so the flash and the
    // viewfx sway-pivot rotate around the same point.
    self.weapon_muzzle_bone   = CFM3_MUZZLE_BONE;
    self.weapon_muzzle_offset = CFM3_MUZZLE_OFFSET;

    // Snapshot-driven equip suppress for the draw-clack: weaponstate
    // at this point is WS_IDLE / WS_DEAD on a snapshot-driven draw
    // (cl_player.qc sets WS_DRAW AFTER Equip), so latching the
    // draw-snd-played flag here means the predict path skips the
    // local select clack and lets the server's CHAN_AUTO emission
    // play through unsuppressed.  Local-prediction draw
    // (CSQC_PredictSelectWeapon sets WS_DRAW BEFORE Equip) skips
    // this branch — predicted draw sound still fires.  Mid-RELOAD /
    // mid-FIRE reconciles also skip the stomp (avoiding the HDAK47
    // collapsed-tracker bug — see commit history).  Same shape as
    // cffiveseven / cfawp / cfg3sg1.
    if (self.weaponstate != WS_DRAW
        && self.weaponstate != WS_RELOAD
        && self.weaponstate != WS_FIRE)
    {
        csqc_cfm3_draw_snd_played = 1;
        csqc_cfm3_snd_action      = self.wep_action_id;
    }
};

#endif // CSQC
