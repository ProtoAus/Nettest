// ============================================================
//  shared/weapons/sh_wpn_csknife.qc  -  CS Knife (GoldSrc MDL)
//
//  Slot  : SLOT_MELEE
//  Fire  : slash (primary) / stab (alt-fire)
//
//  Sequence-driven GoldSrc viewmodel — same pattern as sh_wpn_csusp.qc.
//  Setting self.weaponframe = N tells FTE to play sequence N as a whole
//  and animate it internally; we don't step weaponframe per tick.
//
//  v_knife.mdl sequence order (from the $sequence declarations):
//      0  idle3
//      1  slash1
//      2  slash2
//      3  draw
//      4  stab
//      5  stab_miss
//      6  midslash1
//      7  midslash2
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

// --- Sequence indices ---
const float KNIFE_SEQ_IDLE3     = 0;
const float KNIFE_SEQ_SLASH1    = 1;
const float KNIFE_SEQ_SLASH2    = 2;
const float KNIFE_SEQ_DRAW      = 3;
const float KNIFE_SEQ_STAB      = 4;
const float KNIFE_SEQ_STAB_MISS = 5;
const float KNIFE_SEQ_MIDSLASH1 = 6;
const float KNIFE_SEQ_MIDSLASH2 = 7;

// --- Timing ---
//
// SLASH_DELAY / STAB_DELAY   : gameplay cooldown before the next attack
//                              is allowed (attack_finished gate).
// DRAW_DURATION / FIRE_      : visual anim window — the state transitions
// DURATION / SPECIAL_          back to WS_IDLE and weaponframe flips to
// DURATION                     KNIFE_SEQ_IDLE3 after this elapsed, so it
//                              must be >= the sequence's natural length
//                              or the anim gets cut mid-play.
//
// FIRE_DURATION > SLASH_DELAY is allowed — a re-slash inside the window
// interrupts the current slash visual (SH_KnifeTrySlash no longer requires
// WS_IDLE, only a passed attack_finished cooldown).
//
// Tune these to match the v_knife.mdl sequence lengths. Count frames in
// the .qc source and divide by the sequence's fps if they look off.
const float KNIFE_DRAW_DURATION    = 1.03;
const float KNIFE_FIRE_DURATION    = 0.84;
const float KNIFE_SPECIAL_DURATION = 1.22;

const float KNIFE_SLASH_DELAY      = 0.35;
const float KNIFE_STAB_DELAY       = 0.60;
const float KNIFE_FRAME_INTERVAL   = 0.05;

// --- Hit-detection timings (elapsed since wep_anim_start) ---
// Sequence-driven, so hit detection runs on elapsed time rather than a
// specific frame number. Values picked to fire on the model's visible
// contact point. Tweak if hits feel early/late against the on-screen
// swing.
const float KNIFE_SLASH_HIT_TIME   = 0.10;
const float KNIFE_STAB_HIT_TIME    = 0.15;
const float KNIFE_STAB_MISS_TIME   = 0.30;

// Draw sound timing (elapsed since wep_anim_start)
const float KNIFE_DRAW_SOUND_TIME  = 0.15;

const string KNIFE_VIEWMODEL    = "models/weapons/wpn_csknife/v_knife.mdl";
const string KNIFE_WORLDMODEL   = "models/weapons/wpn_csknife/w_knife.mdl";
// Left empty on purpose. CSQC_PredictSelectWeapon plays weapon_deploy_sound
// IMMEDIATELY on weapon switch — but W_KnifeFrame plays the same deploy
// sound at elapsed >= KNIFE_DRAW_SOUND_TIME, which is the in-anim
// slide/pull moment. Setting this to "" suppresses the immediate play and
// lets the elapsed-time event be the single authoritative deploy sound,
// matching the USP's approach.
const string KNIFE_DEPLOY_SOUND = "";
const string KNIFE_DISPLAY_NAME = "KNIFE";

// Per-entity stage tracker so timed sound / hit events fire exactly once
// per action. Mirrors the csusp_snd_stage field — separate on both sides,
// the server authoritative for hits, the CSQC one only for sound dedup.
.float knife_snd_stage;

// ============================================================
//  SHARED — sequence-pick helpers
// ============================================================

// Deterministically pick one of the four slash sequences from
// wep_action_id so client and server agree on which variant plays.
float() SH_KnifePickSlashSeq =
{
    float r = SH_SpreadHash(self.wep_action_id);
    if (r < 0.25) return KNIFE_SEQ_SLASH1;
    if (r < 0.50) return KNIFE_SEQ_SLASH2;
    if (r < 0.75) return KNIFE_SEQ_MIDSLASH1;
    return KNIFE_SEQ_MIDSLASH2;
};

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
//
// Only blocks during the deploy animation or when the cooldown
// (attack_finished) hasn't elapsed. A new slash is allowed mid-slash or
// mid-stab once the cooldown passes — the new sequence replaces the
// visual on the next wepframe tick. This is necessary because the
// animation windows (FIRE_DURATION / SPECIAL_DURATION) are longer than
// the gameplay delays (SLASH_DELAY / STAB_DELAY) so the anim can play
// fully without gating the next attack.
//
// CSQC-only csqc_fire_guard latch (cltime-based) blocks reconciliation
// replays from re-firing the same slash. Without it, at high ping the
// rolled-back attack_finished timestamp lets the replayed input re-enter
// WS_FIRE and the render path sees a "stuck mid-slash" viewmodel during
// what should be idle time.
float(float now) SH_KnifeTrySlash =
{
#ifdef CSQC
    if (cltime < self.csqc_fire_guard)
        return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + KNIFE_SLASH_DELAY;
#ifdef CSQC
    self.csqc_fire_guard = cltime + KNIFE_SLASH_DELAY;
#endif
    return 1;
};

// Returns: 1 = stab started, 0 = blocked
float(float now) SH_KnifeTryStab =
{
#ifdef CSQC
    if (cltime < self.csqc_fire_guard)
        return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + KNIFE_STAB_DELAY;
#ifdef CSQC
    self.csqc_fire_guard = cltime + KNIFE_STAB_DELAY;
#endif
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
    self.weaponframe    = KNIFE_SEQ_IDLE3;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe  = 0;
    self.knife_snd_stage = 0;
};

// GoldSrc world models have their pivot at a hand/grip bone, not at the
// model's geometric center. setmodel here, then shift .origin so the
// model's natural center sits on the desired drop point, and compensate
// the touch hull via setsize so it stays anchored to the same world
// position. Same helper pattern as W_CSUSPSetupWorldEntity.
void(vector hull_mins, vector hull_maxs) W_KnifeSetupWorldEntity =
{
    vector desired = self.origin;
    setmodel(self, KNIFE_WORLDMODEL);

    vector mdl_center = (self.mins + self.maxs) * 0.5;

    setorigin(self, desired - mdl_center);
    setsize(self, hull_mins + mdl_center, hull_maxs + mdl_center);
};

// Equip — called by W_ChangeWeapon (self = player)
void() W_KnifeEquip =
{
    self.weaponmodel             = KNIFE_VIEWMODEL;
    self.weapon_name             = KNIFE_DISPLAY_NAME;
    self.weapon_draw_start_frame = KNIFE_SEQ_DRAW;
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
    self.weaponframe             = KNIFE_SEQ_DRAW;
    self.wep_nextframe           = time + KNIFE_FRAME_INTERVAL;
    self.knife_snd_stage         = 0;
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

    W_DebugImpact(trace_endpos, damage, W_BoneToHitgroup(trace_bone_id));

    // Narrow dimension_send so any hit sound we broadcast DOES NOT reach
    // the attacker. The attacker's CSQC runs CSQC_PredictKnifeHitSound at
    // the same elapsed moment and plays the identical sound locally, so
    // without this the attacker would hear a ping-delayed echo layered on
    // top of their predicted audio. Mirrors the ric-sound / breakable-
    // impact attacker-exclude pattern in the rest of the codebase.
    float saved_dim = dimension_send;
    dimension_send = dimension_send & ~self.dimension_seen;

    if (W_CanDamageTarget(trace_ent))
    {
        if (random() < 0.5)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csknife/hit1.wav", 1.0, ATTN_NORM);
        else
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csknife/hit2.wav", 1.0, ATTN_NORM);

        dimension_send = saved_dim;
        W_ApplyDamage(self, trace_ent, damage);
        return TRUE;
    }

    sound(self, CHAN_AUTO, "sounds/weapons/wpn_csknife/hitwall.wav", 1.0, ATTN_NORM);
    dimension_send = saved_dim;

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

    // Pick one of four slash variants deterministically from action id
    // so the client's display picks the same one.
    self.weaponframe   = SH_KnifePickSlashSeq();
    self.wep_nextframe = time + KNIFE_FRAME_INTERVAL;
    self.knife_snd_stage = 0;

    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/slash.wav", 1.0, ATTN_NORM);
};

// Alt-fire — stab attack (self = player)
void() W_KnifeAltFire =
{
    if (!SH_KnifeTryStab(time))
        return;

    // Pick stab or stab_miss sequence based on whether the trace would
    // connect. Client mirrors the same trace in CSQC_KnifeDisplayFrame
    // and CSQC_PredictKnifeCommand so both pick the same variant + sound.
    float would_hit = W_KnifeAltFireWouldHit();
    if (would_hit)
        self.weaponframe = KNIFE_SEQ_STAB;
    else
        self.weaponframe = KNIFE_SEQ_STAB_MISS;

    self.wep_nextframe = time + KNIFE_FRAME_INTERVAL;
    self.knife_snd_stage = 0;

    // Swing sound: connect-style stab on hit, generic swipe on miss.
    if (would_hit)
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/stab.wav", 1.0, ATTN_NORM);
    else
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/slash.wav", 1.0, ATTN_NORM);
    PlayerModelPlayPrimaryAttack();
};

// Frame — elapsed-time hit detection + timed sound events (self = player)
void() W_KnifeFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — we do NOT step weaponframe per tick.
    // We only fire timed hit/sound events and run the tick state machine.
    self.wep_nextframe += KNIFE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= KNIFE_DRAW_SOUND_TIME && self.knife_snd_stage < 1)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csknife/deploy.wav", 1.0, ATTN_NORM);
            self.knife_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= KNIFE_SLASH_HIT_TIME && self.knife_snd_stage < 1)
        {
            W_KnifeSlashStrike();
            self.knife_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        // Stab vs stab_miss: hit frame timing differs slightly. The
        // weaponframe we set earlier tells us which sequence is playing.
        if (self.weaponframe == KNIFE_SEQ_STAB)
        {
            if (elapsed >= KNIFE_STAB_HIT_TIME && self.knife_snd_stage < 1)
            {
                W_KnifeStabStrike();
                self.knife_snd_stage = 1;
            }
        }
        else   // KNIFE_SEQ_STAB_MISS
        {
            if (elapsed >= KNIFE_STAB_MISS_TIME && self.knife_snd_stage < 1)
            {
                W_KnifeStabStrike();
                self.knife_snd_stage = 1;
            }
        }
    }

    // Shared state transitions — handles all → idle
    if (SH_KnifeTickState(time) & 1)
    {
        self.weaponframe   = KNIFE_SEQ_IDLE3;
        self.wep_nextframe = 0;
        self.knife_snd_stage = 0;
    }
};

// World entity — spawned from map (classname "weapon_knife")
void() weapon_knife =
{
    W_KnifeSetupWorldEntity('-16 -16 0', '16 16 32');
    self.classname   = "weapon_knife";
    self.solid       = SOLID_TRIGGER;
    self.movetype    = MOVETYPE_TOSS;
    self.weapon      = WEP_KNIFE;
    self.weapon_slot = SLOT_MELEE;
    self.weap_draw   = W_KnifeEquip;
    self.weap_drop_func = W_KnifeDrop;
    self.pickupcopy  = W_KnifePickupCopy;
    self.touch       = weapon_touch;
    self.dropped_spin = 1;
    W_RegisterMapWeapon(weapon_knife);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

float csqc_knife_snd_stage;
float csqc_knife_snd_action;   // wep_action_id of the action this stage belongs to

// Predict knife actions for this input command.
// Called from CSQC_PredictWeaponCommand dispatcher.
//
// Mirrors the USP's CSQC_PredictCSUSPCommand structure: the state machine
// (SH_KnifeTryX / SH_KnifeTickState) runs on EVERY tick including replays,
// and only the individual localsound calls are gated on !pm_suppress_sounds.
// Early-outing on pm_suppress_sounds would leave the replay chain with a
// stale WS_IDLE state, causing a held-button re-fire after every reconcile
// at high ping (the "prediction spam" the user saw).
void() CSQC_PredictKnifeCommand =
{
    float elapsed;

    // Reset the predicted-sound stage when we enter a new weapon action.
    // wep_action_id bumps on every SH_KnifeTrySlash/TryStab and on server-
    // driven equip; this is the only legitimate reset source across a
    // reconcile + replay chain. Resetting in CSQC_KnifeEquip instead would
    // fire every reconciliation and retrigger the draw sound per frame.
    if (predicted_player.wep_action_id != csqc_knife_snd_action)
    {
        csqc_knife_snd_action = predicted_player.wep_action_id;
        csqc_knife_snd_stage  = 0;
    }

    // IMPORTANT: FTEQCC's `&&` operator does NOT short-circuit — both
    // operands are evaluated regardless of the left-hand result. An
    // earlier version of this function used
    //     if ((input_buttons & 1) && SH_KnifeTrySlash(csqc_pred_time))
    // which called SH_KnifeTrySlash on EVERY tick even without mouse1,
    // applying the state-change side effects (state=WS_FIRE, wep_action_id
    // increment, wep_anim_start=now) silently. The surrounding if-body
    // didn't run so there was no visible fire flow, but the viewmodel
    // display picks up weaponstate and rendered a slash anim. This caused
    // the "knife swings randomly in the void" report.
    //
    // Fix: gate the button check in a nested if (same pattern every other
    // weapon in this mod uses, e.g. CSQC_PredictCSUSPCommand).
    if (input_buttons & 1)
    {
        if (SH_KnifeTrySlash(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/wpn_csknife/slash.wav");
                CSQC_RecordPredictedWeaponSound();
            }
            csqc_knife_snd_stage  = 0;
            csqc_knife_snd_action = predicted_player.wep_action_id;
        }
    }
    else if (input_buttons & 4)
    {
        if (SH_KnifeTryStab(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // Mirror the server's W_KnifeAltFireWouldHit trace so the
                // client picks the same hit/miss sound variant. uses
                // input_angles (predicted_player doesn't carry v_angle on CSQC).
                vector stab_src, stab_end;
                makevectors(input_angles);
                stab_src = predicted_player.origin + predicted_player.view_ofs;
                stab_end = stab_src + (v_forward * KNIFE_STAB_RANGE);
                traceline(stab_src, stab_end, MOVE_NORMAL | MOVE_HITMODEL, predicted_player);

                if (trace_fraction < 1.0)
                    localsound("sounds/weapons/wpn_csknife/stab.wav");
                else
                    localsound("sounds/weapons/wpn_csknife/slash.wav");
                CSQC_RecordPredictedWeaponSound();
            }
            csqc_knife_snd_stage  = 0;
            csqc_knife_snd_action = predicted_player.wep_action_id;
        }
    }

    // Predicted draw sound — elapsed-time gated so it fires at the same
    // moment the server's W_KnifeFrame does. Prevents a ping-delayed
    // server echo when the stage bit is 0 on arrival.
    if (!pm_suppress_sounds
        && self.wep_anim_start > 0
        && self.weaponstate == WS_DRAW
        && csqc_knife_snd_stage < 1)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (elapsed >= KNIFE_DRAW_SOUND_TIME)
        {
            localsound("sounds/weapons/wpn_csknife/deploy.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_knife_snd_stage = 1;
        }
    }

    // Predicted hit sound — fires at KNIFE_SLASH_HIT_TIME (or the stab's
    // variant-specific hit time) elapsed into an attack, matching the
    // moment W_KnifeTraceAttack runs on the server. The server excludes
    // the attacker from its hit-sound broadcast (via dimension_send
    // narrowing) so this predicted play is the single authoritative
    // audio feedback for the slash/stab contact — eliminating the
    // ~ping-ms delay on hit thumps that made the weapon feel laggy.
    //
    // Stage 2 = hit sound played (separate from stage 1 = draw sound).
    // Trace uses input_angles since predicted_player lacks v_angle on
    // CSQC; MOVE_HITMODEL matches the server's W_WeaponTraceLine path.
    if (!pm_suppress_sounds
        && self.wep_anim_start > 0
        && csqc_knife_snd_stage < 2)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        float hit_time = 0;
        float attack_range = 0;

        if (self.weaponstate == WS_FIRE)
        {
            hit_time     = KNIFE_SLASH_HIT_TIME;
            attack_range = KNIFE_SLASH_RANGE;
        }
        else if (self.weaponstate == WS_SPECIAL)
        {
            // Stab vs stab_miss have different hit-detection moments;
            // predicted_player.weaponframe holds the server-authoritative
            // stab variant picked at alt-fire time.
            attack_range = KNIFE_STAB_RANGE;
            if (predicted_player.weaponframe == KNIFE_SEQ_STAB)
                hit_time = KNIFE_STAB_HIT_TIME;
            else
                hit_time = KNIFE_STAB_MISS_TIME;
        }

        if (hit_time > 0 && elapsed >= hit_time)
        {
            vector hit_src, hit_end;
            makevectors(input_angles);
            hit_src = predicted_player.origin + predicted_player.view_ofs;
            hit_end = hit_src + (v_forward * attack_range);
            traceline(hit_src, hit_end, MOVE_NORMAL | MOVE_HITMODEL, predicted_player);

            if (trace_fraction < 1.0)
            {
                // Player hit → hit1/hit2; world/breakable → hitwall.
                // Player detection matches CSQC_PredictedImpact's logic.
                float is_player_hit =
                    (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
                    || (trace_ent.classname == "player_visual_proxy");

                if (is_player_hit)
                {
                    if (random() < 0.5)
                        localsound("sounds/weapons/wpn_csknife/hit1.wav");
                    else
                        localsound("sounds/weapons/wpn_csknife/hit2.wav");
                }
                else
                {
                    localsound("sounds/weapons/wpn_csknife/hitwall.wav");
                }
                CSQC_RecordPredictedAutoSound();
            }

            csqc_knife_snd_stage = 2;
        }
    }

    SH_KnifeTickState(csqc_pred_time);
};

// GoldSrc viewmodel: return sequence index directly, FTE animates the sequence.
// All branches read from predicted_player so the render path stays consistent.
float(float elapsed) CSQC_KnifeDisplayFrame =
{
    float r;

    // Strong idle guard: every legitimate transition to idle runs
    // SH_WeaponEnterIdle which atomically sets weaponstate=WS_IDLE AND
    // wep_anim_start=0. Keeping this as a belt-and-braces check against
    // any future state mismatch that would otherwise flash a slash frame.
    if (predicted_player.wep_anim_start <= 0)
        return KNIFE_SEQ_IDLE3;

    if (predicted_player.weaponstate == WS_DRAW)
        return KNIFE_SEQ_DRAW;

    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Same deterministic pick as the server — both sides hash the
        // same wep_action_id, so the same variant plays on attacker's
        // viewmodel and on any remote viewer.
        r = SH_SpreadHash(predicted_player.wep_action_id);
        if (r < 0.25) return KNIFE_SEQ_SLASH1;
        if (r < 0.50) return KNIFE_SEQ_SLASH2;
        if (r < 0.75) return KNIFE_SEQ_MIDSLASH1;
        return KNIFE_SEQ_MIDSLASH2;
    }

    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // Mirror the server's would-hit trace so client picks the same
        // stab variant. Uses input_angles (current CSQC input's view
        // direction) since the predicted_player proxy doesn't carry
        // v_angle on CSQC.
        vector src, end;
        makevectors(input_angles);
        src = predicted_player.origin + predicted_player.view_ofs;
        end = src + (v_forward * KNIFE_STAB_RANGE);
        traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, predicted_player);

        if (trace_fraction < 1.0)
            return KNIFE_SEQ_STAB;
        return KNIFE_SEQ_STAB_MISS;
    }

    // Idle fallback (wep_anim_start > 0 but state is none of the above).
    return KNIFE_SEQ_IDLE3;
};

void() CSQC_KnifeDropClear =
{
};

void() CSQC_KnifeEquip =
{
	// CSQC_ResetToConfirmedState re-invokes CSQC_WeaponEquip on every
	// reconciliation (multiple times per second at non-zero ping).  Do
	// NOT reset csqc_knife_snd_stage / csqc_knife_snd_action here — the
	// wep_action_id gate at the top of CSQC_PredictKnifeCommand already
	// resets them on new actions, and touching them on every equip
	// caused the elapsed-time draw sound to fire per tick during the
	// deploy window (the "repeated draw sounds every frame" report).
	self.weapon_name         = KNIFE_DISPLAY_NAME;
	self.weapon_viewmodel    = KNIFE_VIEWMODEL;
	self.weapon_worldmodel   = KNIFE_WORLDMODEL;
	self.weapon_deploy_sound = KNIFE_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictKnifeCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_KnifeDisplayFrame;
	self.csqc_drop_clear     = CSQC_KnifeDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
