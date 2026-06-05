// ============================================================
//  shared/weapons/sh_wpn_butterfly.qc  -  Butterfly Knife (Balisong)
//
//  Slot  : SLOT_MELEE
//  Fire  : combo (random combo_1 / combo_2)        — primary
//  Alt   : bigshot (random bigshot / bigshot_R1)    — alt-fire
//  Spec  : observe (random observe / observe_R1)   — flourish, no damage
//
//  Sequence-driven GoldSrc viewmodel.  Same design pattern as
//  sh_wpn_csknife.qc:  setting self.weaponframe = N tells FTE to play
//  sequence N as a whole and animate it internally; we don't step
//  weaponframe per tick.  Hit detection runs on elapsed time since
//  wep_anim_start so the contact frame matches the on-screen swing.
//
//  Sequence index map (model: models/weapons/wpn_butteryfly/v_knife.mdl):
//      0  idle_0       (50  fps, loop)
//      1  combo_1      (150 fps, sounds @ frames 14 + 82)
//      2  combo_2      (150 fps, sounds @ frames 14 + 59)
//      3  select       (150 fps, sound  @ frame   5)
//      4  bigshot      (150 fps, sounds @ frames 75 + 204)
//      5  bigshot_R1   (150 fps, sounds @ frames 75 + 199)
//      6  combo_1 dup  (ignored — engine still picks indexed seq)
//      7  combo_2 dup  (ignored)
//      8  observe      (50  fps, sound  @ frame   1)
//      9  observe_R1   (50  fps, sound  @ frame   3)
//
//  Sound files in sounds/weapons/wpn_butterfly/ (folder spelled
//  correctly even though the model folder is "wpn_butteryfly").
// ============================================================

// --- Balance ---
const float BUTTERFLY_COMBO_RANGE     = 72;
const float BUTTERFLY_COMBO_DAMAGE    = 22;
const float BUTTERFLY_BIGSHOT_RANGE   = 88;
const float BUTTERFLY_BIGSHOT_DAMAGE  = 55;

// --- Sequence indices (match the $sequence list above) ---
const float BUTTERFLY_SEQ_IDLE        = 0;
const float BUTTERFLY_SEQ_COMBO_1     = 1;
const float BUTTERFLY_SEQ_COMBO_2     = 2;
const float BUTTERFLY_SEQ_SELECT      = 3;
const float BUTTERFLY_SEQ_BIGSHOT     = 4;
const float BUTTERFLY_SEQ_BIGSHOT_R1  = 5;
const float BUTTERFLY_SEQ_OBSERVE     = 8;
const float BUTTERFLY_SEQ_OBSERVE_R1  = 9;

// --- Timing ---
//
// Anim-window durations are queried from the model at runtime via
// SH_SeqDuration (frameduration() builtin) inside SH_SeqDrivenTickState.
// No per-sequence duration constants needed.
//
// _DELAY values gate the next attack via attack_finished.  These are
// gameplay timers (cooldowns), NOT anim lengths — they let the player
// spam-click and chain attacks inside the natural anim window.
const float BUTTERFLY_COMBO_DELAY      = 0.40;
const float BUTTERFLY_BIGSHOT_DELAY    = 0.60;
const float BUTTERFLY_OBSERVE_DELAY    = 1.00;

const float BUTTERFLY_FRAME_INTERVAL   = 0.05;

// --- Sound event timings (elapsed since wep_anim_start) ---
//   frame / fps == elapsed seconds
const float BUTTERFLY_SELECT_SND_TIME      = 0.033;   // select frame 5  / 150
const float BUTTERFLY_COMBO_HIT_TIME       = 0.093;   // combo  frame 14 / 150
const float BUTTERFLY_COMBO_1_SPIN_TIME    = 0.547;   // combo_1 frame 82 / 150
const float BUTTERFLY_COMBO_2_SPIN_TIME    = 0.393;   // combo_2 frame 59 / 150
const float BUTTERFLY_BIGSHOT_HIT_TIME     = 0.500;   // bigshot frame 75 / 150
const float BUTTERFLY_BIGSHOT_SPIN_TIME    = 1.360;   // bigshot frame 204 / 150
const float BUTTERFLY_BIGSHOT_R1_SPIN_TIME = 1.327;   // bigshot_R1 frame 199 / 150
const float BUTTERFLY_OBSERVE_SND_TIME     = 0.020;   // observe frame 1 / 50
const float BUTTERFLY_OBSERVE_R1_SND_TIME  = 0.060;   // observe_R1 frame 3 / 50

const string BUTTERFLY_VIEWMODEL    = "models/weapons/wpn_butteryfly/v_knife.mdl";
const string BUTTERFLY_WORLDMODEL   = "models/weapons/wpn_butteryfly/w_knife.mdl";
// Empty deploy_sound — the elapsed-time event at BUTTERFLY_SELECT_SND_TIME
// is the authoritative draw click; CSQC_PredictSelectWeapon would
// otherwise play a duplicate at switch instant.  Same as the knife.
const string BUTTERFLY_DEPLOY_SOUND = "";
const string BUTTERFLY_DISPLAY_NAME = "BUTTERFLY";

const string BUTTERFLY_SND_SELECT      = "sounds/weapons/wpn_butterfly/Balisong_LE_Select.wav";
const string BUTTERFLY_SND_ATT_1       = "sounds/weapons/wpn_butterfly/Balisong_LE_Att_1.wav";
const string BUTTERFLY_SND_ATT_2       = "sounds/weapons/wpn_butterfly/Balisong_LE_Att_2.wav";
const string BUTTERFLY_SND_COMBO_1_SPIN = "sounds/weapons/wpn_butterfly/Balisong_LE_Combo_1_Spin.wav";
const string BUTTERFLY_SND_COMBO_2_SPIN = "sounds/weapons/wpn_butterfly/Balisong_LE_Combo_2_Spin.wav";
const string BUTTERFLY_SND_BIGSHOT       = "sounds/weapons/wpn_butterfly/Balisong_LE_BigShot.wav";
const string BUTTERFLY_SND_BIGSHOT_R     = "sounds/weapons/wpn_butterfly/Balisong_LE_BigShot_R.wav";
const string BUTTERFLY_SND_BIGSHOT_SPIN  = "sounds/weapons/wpn_butterfly/Balisong_LE_BigShot_Spin.wav";
const string BUTTERFLY_SND_BIGSHOT_R_SPIN = "sounds/weapons/wpn_butterfly/Balisong_LE_BigShot_R_Spin.wav";
const string BUTTERFLY_SND_OBSERVE       = "sounds/weapons/wpn_butterfly/Balisong_LE_Observe.wav";
const string BUTTERFLY_SND_OBSERVE_02    = "sounds/weapons/wpn_butterfly/Balisong_LE_Observe_02.wav";
const string BUTTERFLY_SND_HIT1          = "sounds/weapons/wpn_butterfly/hit1.wav";
const string BUTTERFLY_SND_HIT2          = "sounds/weapons/wpn_butterfly/hit2.wav";
const string BUTTERFLY_SND_HIT3          = "sounds/weapons/wpn_butterfly/hit3.wav";
const string BUTTERFLY_SND_HIT4          = "sounds/weapons/wpn_butterfly/hit4.wav";
const string BUTTERFLY_SND_HITWALL       = "sounds/weapons/wpn_butterfly/hitwall1.wav";

// Per-entity stage tracker — fires each timed sound/hit event exactly
// once per action.  Mirrors knife_snd_stage; bumped to 2 after the
// in-anim spin sound so the sequence (deploy click / hit / spin) doesn't
// re-trigger on a reconcile replay.
.float butterfly_snd_stage;

// ============================================================
//  SHARED — sequence-pick helpers
// ============================================================

// Combo: 50/50 pick between combo_1 and combo_2, deterministic by action id.
float() SH_ButterflyPickComboSeq =
{
    if (SH_SpreadHash(self.wep_action_id) < 0.5)
        return BUTTERFLY_SEQ_COMBO_1;
    return BUTTERFLY_SEQ_COMBO_2;
};

// Bigshot: 50/50 pick between bigshot and bigshot_R1.
float() SH_ButterflyPickBigshotSeq =
{
    if (SH_SpreadHash(self.wep_action_id) < 0.5)
        return BUTTERFLY_SEQ_BIGSHOT;
    return BUTTERFLY_SEQ_BIGSHOT_R1;
};

// Observe: 50/50 pick between observe and observe_R1.
float() SH_ButterflyPickObserveSeq =
{
    if (SH_SpreadHash(self.wep_action_id) < 0.5)
        return BUTTERFLY_SEQ_OBSERVE;
    return BUTTERFLY_SEQ_OBSERVE_R1;
};

// ============================================================
//  SHARED — state machine (server & client identical)
// ============================================================

// State usage:
//   WS_FIRE    — combo (primary)
//   WS_SPECIAL — bigshot (alt-fire)
//   WS_RELOAD  — observe (impulse-7 special).  Repurposed as "playing
//                inspection anim"; this weapon has no real reload.
//
// SH_SeqDrivenTickState reads self.weaponframe and asks the model for
// the active sequence's natural length, returning 1 when the anim
// completes.  No _DURATION constants needed.
float(float now) SH_ButterflyTickState =
{
    return SH_SeqDrivenTickState(now, BUTTERFLY_VIEWMODEL);
};

// Three thin wrappers around SH_StandardTryAction with the per-attack
// target state + cooldown delay.  Each blocks during WS_DRAW and
// gates on attack_finished; combo cooldown (0.40s) is intentionally
// shorter than the natural combo anim (~1.10s) so spam-clicking
// chains — the new fire restarts wep_anim_start and the tick re-tracks
// the new sequence's duration.
float(float now) SH_ButterflyTryCombo =
{
    return SH_StandardTryAction(now, WS_FIRE,    BUTTERFLY_COMBO_DELAY);
};
float(float now) SH_ButterflyTryBigshot =
{
    return SH_StandardTryAction(now, WS_SPECIAL, BUTTERFLY_BIGSHOT_DELAY);
};
float(float now) SH_ButterflyTryObserve =
{
    return SH_StandardTryAction(now, WS_RELOAD,  BUTTERFLY_OBSERVE_DELAY);
};

// ============================================================
//  SERVER ONLY — authoritative fire, frame, equip, world entity
// ============================================================

#ifdef SSQC

void() weapon_touch;
void(vector pos) SpawnImpactLight;
void() PlayerModelPlayPrimaryAttack;

void() W_ButterflyEnterIdle;
void() W_ButterflyComboStrike;
void() W_ButterflyBigshotStrike;
void() W_ButterflyFire;
void() W_ButterflyAltFire;
void() W_ButterflySpecial;
void() W_ButterflyFrame;
void() W_ButterflyEquip;
float(float attack_range, float damage) W_ButterflyTraceAttack;

void(entity receiver) W_ButterflyPickupCopy =
{
};

void() W_ButterflyDrop =
{
    entity tgt = weapon_drop_target;

    // GoldSrc world model — hand-pivot shifted to geometric centre by
    // SH_GoldSrcSetupWorld (shared helper).  setmodel + setorigin happen
    // inside; we just pre-set tgt as self for the helper.
    entity oldself = self;
    self = tgt;
    SH_GoldSrcSetupWorld(BUTTERFLY_WORLDMODEL, '-16 -16 0', '16 16 48');
    self = oldself;

    tgt.classname    = "weapon_butterfly";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_BUTTERFLY;
    tgt.weapon_slot  = SLOT_MELEE;
    tgt.weap_draw    = W_ButterflyEquip;
    tgt.weap_drop_func = W_ButterflyDrop;
    tgt.pickupcopy   = W_ButterflyPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() W_ButterflyEnterIdle =
{
    self.weaponframe       = BUTTERFLY_SEQ_IDLE;
    self.weaponstate       = WS_IDLE;
    self.wep_anim_start    = 0;
    self.wep_nextframe     = 0;
    self.butterfly_snd_stage = 0;
};

// Equip — called by W_ChangeWeapon (self = player)
void() W_ButterflyEquip =
{
    self.weaponmodel             = BUTTERFLY_VIEWMODEL;
    self.weapon_name             = BUTTERFLY_DISPLAY_NAME;
    self.weapon_draw_start_frame = BUTTERFLY_SEQ_SELECT;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_MELEE;
    self.altfire                 = W_ButterflyAltFire;
    self.altrelease              = __NULL__;
    self.shoot                   = W_ButterflyComboStrike;
    self.fire                    = W_ButterflyFire;
    self.reload                  = __NULL__;
    self.special                 = W_ButterflySpecial;
    self.wepframe                = W_ButterflyFrame;
    self.weaponstate             = WS_DRAW;
    self.wep_action_id          += 1;
    self.wep_anim_start          = time;
    self.weaponframe             = BUTTERFLY_SEQ_SELECT;
    self.wep_nextframe           = time + BUTTERFLY_FRAME_INTERVAL;
    self.butterfly_snd_stage     = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

float(float attack_range, float damage) W_ButterflyTraceAttack =
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

    // Attacker is excluded from the broadcast hit sound — the predicted
    // CSQC plays an identical local sound at the same elapsed moment;
    // without this the attacker hears a ping-delayed echo.  Same pattern
    // as W_KnifeTraceAttack.
    float saved_dim = dimension_send;
    dimension_send = dimension_send & ~self.dimension_seen;

    if (W_CanDamageTarget(trace_ent))
    {
        // Four flesh-hit variants — random pick adds variety to a
        // sustained slash chain.
        float r = random();
        string snd = BUTTERFLY_SND_HIT1;
        if (r < 0.25)      snd = BUTTERFLY_SND_HIT1;
        else if (r < 0.50) snd = BUTTERFLY_SND_HIT2;
        else if (r < 0.75) snd = BUTTERFLY_SND_HIT3;
        else               snd = BUTTERFLY_SND_HIT4;
        sound(self, CHAN_AUTO, snd, 1.0, ATTN_NORM);

        dimension_send = saved_dim;
        // Defer player damage to the attacker's hitclaim so the
        // swing doesn't apply damage twice (server-auth +
        // hitclaim).  Mirrors the bullet-weapon pattern.
        float defer_player = (trace_ent.classname == "player")
                             && W_ShouldDeferToClaim(self);
        if (!defer_player)
            W_ApplyDamage(self, trace_ent, damage);
        return TRUE;
    }

    sound(self, CHAN_AUTO, BUTTERFLY_SND_HITWALL, 1.0, ATTN_NORM);
    dimension_send = saved_dim;

    PhysProp_TryPushFromTrace(v_forward, damage);

    if (trace_ent == world || trace_ent.solid == SOLID_BSP)
    {
        W_ImpactEffect(trace_endpos);
        SpawnImpactLight(trace_endpos);
    }

    return TRUE;
};

void() W_ButterflyComboStrike =
{
    W_ButterflyTraceAttack(BUTTERFLY_COMBO_RANGE, BUTTERFLY_COMBO_DAMAGE);
};

void() W_ButterflyBigshotStrike =
{
    W_ButterflyTraceAttack(BUTTERFLY_BIGSHOT_RANGE, BUTTERFLY_BIGSHOT_DAMAGE);
};

// Fire — combo attack (self = player)
void() W_ButterflyFire =
{
    if (!SH_ButterflyTryCombo(time))
        return;

    self.weaponframe   = SH_ButterflyPickComboSeq();
    self.wep_nextframe = time + BUTTERFLY_FRAME_INTERVAL;
    self.butterfly_snd_stage = 0;

    // Combo swing sound — Att_1 for combo_1, Att_2 for combo_2.  Fires
    // immediately at the swing's start (matches the model's frame-14
    // event) and is the audible kickoff of the slash.
    if (self.weaponframe == BUTTERFLY_SEQ_COMBO_1)
        sound(self, CHAN_WEAPON, BUTTERFLY_SND_ATT_1, 1.0, ATTN_NORM);
    else
        sound(self, CHAN_WEAPON, BUTTERFLY_SND_ATT_2, 1.0, ATTN_NORM);
};

// Alt-fire — bigshot attack (self = player)
void() W_ButterflyAltFire =
{
    if (!SH_ButterflyTryBigshot(time))
        return;

    self.weaponframe   = SH_ButterflyPickBigshotSeq();
    self.wep_nextframe = time + BUTTERFLY_FRAME_INTERVAL;
    self.butterfly_snd_stage = 0;

    // Bigshot windup sound — fires at action start (the frame-75 hit
    // event lands later via the snd_stage machine in W_ButterflyFrame).
    // For bigshot the start sound IS the BigShot/_R wav per the model.
    if (self.weaponframe == BUTTERFLY_SEQ_BIGSHOT)
        sound(self, CHAN_WEAPON, BUTTERFLY_SND_BIGSHOT, 1.0, ATTN_NORM);
    else
        sound(self, CHAN_WEAPON, BUTTERFLY_SND_BIGSHOT_R, 1.0, ATTN_NORM);
    PlayerModelPlayPrimaryAttack();
};

// Special — observe flourish, no damage (self = player)
void() W_ButterflySpecial =
{
    if (!SH_ButterflyTryObserve(time))
        return;

    self.weaponframe   = SH_ButterflyPickObserveSeq();
    self.wep_nextframe = time + BUTTERFLY_FRAME_INTERVAL;
    self.butterfly_snd_stage = 0;

    // Observe sound — fires at the model's frame-1 / frame-3 events.
    // Both timings are short enough that playing at action start matches
    // the on-screen flourish closely; remove if a frame-event sound is
    // preferred.  Model has only this one sound per observe variant.
    if (self.weaponframe == BUTTERFLY_SEQ_OBSERVE)
        sound(self, CHAN_WEAPON, BUTTERFLY_SND_OBSERVE, 1.0, ATTN_NORM);
    else
        sound(self, CHAN_WEAPON, BUTTERFLY_SND_OBSERVE_02, 1.0, ATTN_NORM);
};

// Frame — elapsed-time hit detection + spin sounds (self = player)
void() W_ButterflyFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — only timed events + tick state, no manual frame step.
    self.wep_nextframe += BUTTERFLY_FRAME_INTERVAL;

    // All elapsed-time event sounds go on CHAN_AUTO (not CHAN_WEAPON).
    // The CSQC predictor records them as auto-channel via
    // CSQC_RecordPredictedAutoSound; the engine's echo-suppress in
    // CSQC_Event_Sound only matches if the channel agrees.  Sending the
    // server broadcast on CHAN_WEAPON would slip past AUTO suppression
    // and the attacker would hear two copies of the spin sound — which
    // is the bug that showed up on the bigshot's late spin (1.36 s out)
    // because by then the WEAPON dedup window keyed off the fire sound
    // had already expired.
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= BUTTERFLY_SELECT_SND_TIME && self.butterfly_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, BUTTERFLY_SND_SELECT, 1.0, ATTN_NORM);
            self.butterfly_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // Stage 1 — hit at frame 14 (both combos use the same hit moment).
        if (elapsed >= BUTTERFLY_COMBO_HIT_TIME && self.butterfly_snd_stage < 1)
        {
            W_ButterflyComboStrike();
            self.butterfly_snd_stage = 1;
        }
        // Stage 2 — closing-spin sound; per-variant timing.
        float spin_t = (self.weaponframe == BUTTERFLY_SEQ_COMBO_1)
            ? BUTTERFLY_COMBO_1_SPIN_TIME
            : BUTTERFLY_COMBO_2_SPIN_TIME;
        if (elapsed >= spin_t && self.butterfly_snd_stage < 2)
        {
            string snd = (self.weaponframe == BUTTERFLY_SEQ_COMBO_1)
                ? BUTTERFLY_SND_COMBO_1_SPIN
                : BUTTERFLY_SND_COMBO_2_SPIN;
            sound(self, CHAN_AUTO, snd, 1.0, ATTN_NORM);
            self.butterfly_snd_stage = 2;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= BUTTERFLY_BIGSHOT_HIT_TIME && self.butterfly_snd_stage < 1)
        {
            W_ButterflyBigshotStrike();
            self.butterfly_snd_stage = 1;
        }
        // QC locals are function-scoped — re-using the spin_t / snd names
        // declared in the WS_FIRE branch above (no `float` / `string` keyword).
        spin_t = (self.weaponframe == BUTTERFLY_SEQ_BIGSHOT)
            ? BUTTERFLY_BIGSHOT_SPIN_TIME
            : BUTTERFLY_BIGSHOT_R1_SPIN_TIME;
        if (elapsed >= spin_t && self.butterfly_snd_stage < 2)
        {
            snd = (self.weaponframe == BUTTERFLY_SEQ_BIGSHOT)
                ? BUTTERFLY_SND_BIGSHOT_SPIN
                : BUTTERFLY_SND_BIGSHOT_R_SPIN;
            sound(self, CHAN_AUTO, snd, 1.0, ATTN_NORM);
            self.butterfly_snd_stage = 2;
        }
    }
    // Observe (WS_RELOAD) plays its single sound at fire time — no per-frame events.

    // Standard post-tick reset — set idle sequence + per-weapon counters.
    // The CSQC idle-loop frame anchor lives in CSQC_ButterflyDisplayFrame
    // (csqc_butterfly_idle_anchor), independent of this server-side reset.
    if (SH_ButterflyTickState(time) & 1)
    {
        self.weaponframe         = BUTTERFLY_SEQ_IDLE;
        self.wep_nextframe       = 0;
        self.butterfly_snd_stage = 0;
    }
};

// World entity — spawned from map (classname "weapon_butterfly")
void() weapon_butterfly =
{
    SH_GoldSrcSetupWorld(BUTTERFLY_WORLDMODEL, '-16 -16 0', '16 16 48');
    self.classname   = "weapon_butterfly";
    self.solid       = SOLID_TRIGGER;
    self.movetype    = MOVETYPE_TOSS;
    self.weapon      = WEP_BUTTERFLY;
    self.weapon_slot = SLOT_MELEE;
    self.weap_draw   = W_ButterflyEquip;
    self.weap_drop_func = W_ButterflyDrop;
    self.pickupcopy  = W_ButterflyPickupCopy;
    self.touch       = weapon_touch;
    W_RegisterMapWeapon(weapon_butterfly);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

float csqc_butterfly_snd_stage;
float csqc_butterfly_snd_action;

// Idle-loop restart anchor.  The prediction proxy serializes
// wep_anim_start as "elapsed since anim began" and the receiver
// reconstructs it as `cltime - elapsed`, which means in steady-state
// idle the value keeps drifting forward — and the engine's viewmodel
// renderer plays the sequence at frame1time = cltime - wep_anim_start,
// putting the loop at whatever phase happens to fall out of that math.
// To force a clean restart on every transition into idle we capture
// cltime here on the WS_FIRE/SPECIAL/RELOAD/DRAW → WS_IDLE edge and
// hand the renderer (cltime - anchor) via the
// csqc_viewmodel_sequence_time_override mechanism.
float csqc_butterfly_idle_anchor;
float csqc_butterfly_prev_seen_state;   // initialized to 0 (== WS_IDLE) — the equip handler resets this so the first transition still captures cleanly

void() CSQC_PredictButterflySpecial =
{
    if (!SH_ButterflyTryObserve(csqc_pred_time))
        return;

    self.weaponframe = SH_ButterflyPickObserveSeq();
    csqc_butterfly_snd_stage  = 0;
    csqc_butterfly_snd_action = predicted_player.wep_action_id;

    if (!pm_suppress_sounds)
    {
        if (self.weaponframe == BUTTERFLY_SEQ_OBSERVE)
            localsound(BUTTERFLY_SND_OBSERVE);
        else
            localsound(BUTTERFLY_SND_OBSERVE_02);
        CSQC_RecordPredictedWeaponSound();
    }
    CSQC_MarkPendingWeaponAck();
};

void() CSQC_PredictButterflyCommand =
{
    // Hoisted locals — QC has function-scope locals (not block-scope), so
    // reusing names like `snd` / `spin_t` across branches needs them
    // declared once up here.  Letting fteqcc's Q207 trip on the inner
    // re-declarations confuses humans who read the code as if it were C.
    float elapsed;
    float spin_t;
    float did_hit;
    float is_player_hit;
    float r;
    string snd;

    // Reset predicted-sound stage on a new action.  wep_action_id bumps
    // on every SH_ButterflyTry* and on equip; that's the only legitimate
    // reset across a reconcile + replay chain.
    if (predicted_player.wep_action_id != csqc_butterfly_snd_action)
    {
        csqc_butterfly_snd_action = predicted_player.wep_action_id;
        csqc_butterfly_snd_stage  = 0;
    }

    // FTEQCC `&&` does NOT short-circuit; gate input checks in nested
    // ifs so SH_ButterflyTry* doesn't run on every tick (would silently
    // bump action_id and flicker the viewmodel).  Same trap as the knife.
    if (input_buttons & 1)
    {
        if (SH_ButterflyTryCombo(csqc_pred_time))
        {
            self.weaponframe = SH_ButterflyPickComboSeq();
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                snd = (self.weaponframe == BUTTERFLY_SEQ_COMBO_1)
                    ? BUTTERFLY_SND_ATT_1
                    : BUTTERFLY_SND_ATT_2;
                localsound(snd);
                CSQC_RecordPredictedWeaponSound();
            }
            csqc_butterfly_snd_stage  = 0;
            csqc_butterfly_snd_action = predicted_player.wep_action_id;
        }
    }
    else if (input_buttons & 4)
    {
        if (SH_ButterflyTryBigshot(csqc_pred_time))
        {
            self.weaponframe = SH_ButterflyPickBigshotSeq();
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                snd = (self.weaponframe == BUTTERFLY_SEQ_BIGSHOT)
                    ? BUTTERFLY_SND_BIGSHOT
                    : BUTTERFLY_SND_BIGSHOT_R;
                localsound(snd);
                CSQC_RecordPredictedWeaponSound();
            }
            csqc_butterfly_snd_stage  = 0;
            csqc_butterfly_snd_action = predicted_player.wep_action_id;
        }
    }

    // Predicted draw click — fires at the same elapsed moment as the
    // server's W_ButterflyFrame so the click isn't ping-delayed.
    if (!pm_suppress_sounds
        && self.wep_anim_start > 0
        && self.weaponstate == WS_DRAW
        && csqc_butterfly_snd_stage < 1)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (elapsed >= BUTTERFLY_SELECT_SND_TIME)
        {
            localsound(BUTTERFLY_SND_SELECT);
            CSQC_RecordPredictedAutoSound();
            csqc_butterfly_snd_stage = 1;
        }
    }

    // Predicted hit + spin-sound stages — mirror server timing exactly.
    if (!pm_suppress_sounds
        && self.wep_anim_start > 0
        && csqc_butterfly_snd_stage < 2)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_FIRE)
        {
            if (elapsed >= BUTTERFLY_COMBO_HIT_TIME && csqc_butterfly_snd_stage < 1)
            {
                // Routes through the standard predicted-melee path:
                // CSQC_SendHitclaim, breakable break, decal, hit sound.
                // Empty sound args — the random hit1..4 pick happens
                // locally below to match the server's random.
                did_hit = CSQC_PredictedMeleeTrace(
                    BUTTERFLY_COMBO_RANGE, BUTTERFLY_COMBO_DAMAGE,
                    "", "", "");
                if (did_hit)
                {
                    is_player_hit =
                        (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
                        || (trace_ent.classname == "player_visual_proxy");
                    if (is_player_hit)
                    {
                        r = random();
                        if (r < 0.25)      localsound(BUTTERFLY_SND_HIT1);
                        else if (r < 0.50) localsound(BUTTERFLY_SND_HIT2);
                        else if (r < 0.75) localsound(BUTTERFLY_SND_HIT3);
                        else               localsound(BUTTERFLY_SND_HIT4);
                    }
                    else
                    {
                        localsound(BUTTERFLY_SND_HITWALL);
                    }
                    CSQC_RecordPredictedAutoSound();
                }
                csqc_butterfly_snd_stage = 1;
            }

            spin_t = (predicted_player.weaponframe == BUTTERFLY_SEQ_COMBO_1)
                ? BUTTERFLY_COMBO_1_SPIN_TIME
                : BUTTERFLY_COMBO_2_SPIN_TIME;
            if (elapsed >= spin_t && csqc_butterfly_snd_stage < 2)
            {
                snd = (predicted_player.weaponframe == BUTTERFLY_SEQ_COMBO_1)
                    ? BUTTERFLY_SND_COMBO_1_SPIN
                    : BUTTERFLY_SND_COMBO_2_SPIN;
                localsound(snd);
                CSQC_RecordPredictedAutoSound();
                csqc_butterfly_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_SPECIAL)
        {
            if (elapsed >= BUTTERFLY_BIGSHOT_HIT_TIME && csqc_butterfly_snd_stage < 1)
            {
                // Re-using did_hit / is_player_hit / r from the WS_FIRE
                // branch — QC locals are function-scoped, no `float` keyword.
                did_hit = CSQC_PredictedMeleeTrace(
                    BUTTERFLY_BIGSHOT_RANGE, BUTTERFLY_BIGSHOT_DAMAGE,
                    "", "", "");
                if (did_hit)
                {
                    is_player_hit =
                        (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
                        || (trace_ent.classname == "player_visual_proxy");
                    if (is_player_hit)
                    {
                        r = random();
                        if (r < 0.25)      localsound(BUTTERFLY_SND_HIT1);
                        else if (r < 0.50) localsound(BUTTERFLY_SND_HIT2);
                        else if (r < 0.75) localsound(BUTTERFLY_SND_HIT3);
                        else               localsound(BUTTERFLY_SND_HIT4);
                    }
                    else
                    {
                        localsound(BUTTERFLY_SND_HITWALL);
                    }
                    CSQC_RecordPredictedAutoSound();
                }
                csqc_butterfly_snd_stage = 1;
            }

            spin_t = (predicted_player.weaponframe == BUTTERFLY_SEQ_BIGSHOT)
                ? BUTTERFLY_BIGSHOT_SPIN_TIME
                : BUTTERFLY_BIGSHOT_R1_SPIN_TIME;
            if (elapsed >= spin_t && csqc_butterfly_snd_stage < 2)
            {
                snd = (predicted_player.weaponframe == BUTTERFLY_SEQ_BIGSHOT)
                    ? BUTTERFLY_SND_BIGSHOT_SPIN
                    : BUTTERFLY_SND_BIGSHOT_R_SPIN;
                localsound(snd);
                CSQC_RecordPredictedAutoSound();
                csqc_butterfly_snd_stage = 2;
            }
        }
        // WS_RELOAD (observe) has no per-frame predicted events; the
        // single sound was played at action-start in
        // CSQC_PredictButterflySpecial.
    }

    SH_ButterflyTickState(csqc_pred_time);
};

// GoldSrc viewmodel: return sequence index directly; the engine animates
// within the sequence based on .frame1time.
float(float elapsed) CSQC_ButterflyDisplayFrame =
{
    float ws = predicted_player.weaponstate;

    // Capture the cltime at the WS_(non-idle) → WS_IDLE edge so the
    // override below can hand the renderer a fresh "0 → growing"
    // sequence time on every entry to idle.  Display runs once per
    // render frame, so prev_seen_state correctly tracks last-frame state.
    if (ws == WS_IDLE && csqc_butterfly_prev_seen_state != WS_IDLE)
        csqc_butterfly_idle_anchor = cltime;
    csqc_butterfly_prev_seen_state = ws;

    if (ws == WS_DRAW)
        return BUTTERFLY_SEQ_SELECT;

    // For attack/observe states the variant is already encoded in
    // predicted_player.weaponframe (set by W_ButterflyFire/AltFire/Special
    // server-side, mirrored by CSQC_PredictButterflyCommand).  Just
    // surface that sequence — the engine plays it from frame1time.
    if (ws == WS_FIRE || ws == WS_SPECIAL || ws == WS_RELOAD)
        return predicted_player.weaponframe;

    // Idle.  Override the renderer's frame1time with our captured
    // anchor so the 8.10 s loop always starts at frame 0 the moment we
    // land here, regardless of what the proxy has done with
    // wep_anim_start.  See the anchor declaration above for why.
    csqc_viewmodel_sequence_time_override = TRUE;
    csqc_viewmodel_sequence_time = max(0, cltime - csqc_butterfly_idle_anchor);
    return BUTTERFLY_SEQ_IDLE;
};

void() CSQC_ButterflyDropClear =
{
};

void() CSQC_ButterflyEquip =
{
    self.weapon_name         = BUTTERFLY_DISPLAY_NAME;
    self.weapon_viewmodel    = BUTTERFLY_VIEWMODEL;
    self.weapon_worldmodel   = BUTTERFLY_WORLDMODEL;
    self.weapon_deploy_sound = BUTTERFLY_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictButterflyCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_ButterflyDisplayFrame;
    self.csqc_drop_clear     = CSQC_ButterflyDropClear;
    self.weapon_uses_sequences = TRUE;

    // Do NOT reset csqc_butterfly_idle_anchor / prev_seen_state here.
    // CSQC_ResetToConfirmedState re-invokes CSQC_WeaponEquip on every
    // reconcile (many times per second at non-zero ping); resetting
    // either field on every call would clobber the anchor right after
    // it was captured on the DRAW → IDLE edge, freezing frame1time near
    // 0 and making the idle look stationary.  Same gotcha called out in
    // sh_wpn_csknife.qc:754.  Natural flow handles weapon-switch-away
    // and -back: the next DRAW → IDLE transition captures fresh anchor.
};

#endif // CSQC
