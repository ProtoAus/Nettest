// ============================================================
//  shared/weapons/sh_wpn_oppipewrench.qc  -  Opposing Force pipe wrench
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo; three-take swing on primary, charged big swing on secondary
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6957 (weapon_pipewrench, "Wrench"),
//  svencoop/models/{v,p,w}_pipe_wrench.mdl and the twelve
//  svencoop/sound/weapons/pwrench_*.wav.
//
//  Previously an alias onto WEP_WRENCH (sv_goldsrc_pickups.qc:196) — this mod's
//  own wrench, which is a single-swing melee weapon.  What that lost is the half
//  of the sound set nothing was playing: pwrench_big_hit1/2,
//  pwrench_big_hitbod1/2 and pwrench_big_miss exist because Opposing Force's
//  wrench has a SECOND attack you charge by holding the button, and the model
//  carries attackbigwind / attackbigloop / attackbighit / attackbigmiss to match.
//  That charged swing is the reason this weapon is worth having separately.

// --- Sequence indices, read out of svencoop/models/v_pipe_wrench.mdl (15) ----
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).  idle2 and idle3 carry STUDIO_LOOPING; idle1 does not,
// which is why the resting pose below is idle2.
const float PWR_SEQ_IDLE1        = 0;    // idle1,         2.000 s (61f @ 30)  NOT looping
const float PWR_SEQ_IDLE2        = 1;    // idle2,         3.000 s (91f @ 30)  LOOPING  <- resting
const float PWR_SEQ_IDLE3        = 2;    // idle3,         3.000 s (91f @ 30)  LOOPING
const float PWR_SEQ_DRAW         = 3;    // draw,          0.667 s (21f @ 30)
const float PWR_SEQ_HOLSTER      = 4;    // holster,       0.667 s (21f @ 30)  no holster state here
const float PWR_SEQ_ATTACK1HIT   = 5;    // attack1hit,    0.733 s (23f @ 30)
const float PWR_SEQ_ATTACK1MISS  = 6;    // attack1miss,   0.900 s (28f @ 30)
const float PWR_SEQ_ATTACK2HIT   = 7;    // attack2hit,    0.733 s (23f @ 30)
const float PWR_SEQ_ATTACK2MISS  = 8;    // attack2miss,   0.733 s (23f @ 30)
const float PWR_SEQ_ATTACK3HIT   = 9;    // attack3hit,    0.567 s (18f @ 30)
const float PWR_SEQ_ATTACK3MISS  = 10;   // attack3miss,   0.733 s (23f @ 30)
const float PWR_SEQ_BIGWIND      = 11;   // attackbigwind, 0.867 s (27f @ 30)
const float PWR_SEQ_BIGHIT       = 12;   // attackbighit,  0.933 s (29f @ 30)
const float PWR_SEQ_BIGMISS      = 13;   // attackbigmiss, 0.967 s (30f @ 30)
const float PWR_SEQ_BIGLOOP      = 14;   // attackbigloop, 0.067 s  (3f @ 30)

const float PWR_FRAME_INTERVAL = 0.05;

// --- Balance ---
// This mod's melee cadence and reach, for the same reason sh_wpn_thspanner.qc
// takes them: the client predicts its own hit/miss verdict and can disagree with
// the server's for a single swing, so an outcome-dependent rate of fire would
// turn one disagreement into a lasting cadence mismatch.
const float PWR_FIRE_DELAY   = 0.5;
const float PWR_RANGE        = 72;
const float PWR_DAMAGE       = 25;     // the crowbar's number

// The charged swing.  Held for PWR_BIG_CHARGE_TIME it lands PWR_BIG_DAMAGE —
// more than twice a normal hit, for more than twice the time, which is the
// trade Opposing Force's version makes.
const float PWR_BIG_CHARGE_TIME = 1.0;
const float PWR_BIG_DAMAGE      = 60;
const float PWR_BIG_DELAY       = 1.2;

// --- State durations, taken from the sequences themselves ---
const float PWR_DRAW_DURATION = 0.667;
const float PWR_FIRE_DURATION = 0.900;   // the longest of the three miss takes
const float PWR_BIG_DURATION  = 0.967;   // attackbigmiss, the longest big take
const float PWR_WIND_DURATION = 0.867;   // attackbigwind, before attackbigloop holds

const string PWR_VIEWMODEL    = "models/v_pipe_wrench.mdl";
const string PWR_WORLDMODEL   = "models/w_pipe_wrench.mdl";
const string PWR_DEPLOY_SOUND = "";
const string PWR_DISPLAY_NAME = "PIPE WRENCH";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// Three takes, cycled off wep_action_id so client and server land on the same
// one.  `x - floor(x/n)*n` is this codebase's fmod idiom (sh_pmove.qc:2578);
// there is no `%` operator.
float(float swing_id, float did_hit) SH_PWrenchPickSwingSeq =
{
    float n = swing_id - floor(swing_id / 3) * 3;
    if (n == 0) return did_hit ? PWR_SEQ_ATTACK1HIT : PWR_SEQ_ATTACK1MISS;
    if (n == 1) return did_hit ? PWR_SEQ_ATTACK2HIT : PWR_SEQ_ATTACK2MISS;
    return did_hit ? PWR_SEQ_ATTACK3HIT : PWR_SEQ_ATTACK3MISS;
};

// ---- THE CHARGED SWING, SHARED -------------------------------------------
//
// All of this used to live inside #ifdef SSQC, and .pwr_charge_start was
// declared there too.  That is the whole of the reported "it makes sound and the
// playermodel moves, but no v_model changes": the server wound the wrench, set
// self.weaponframe and played the samples, while CSQC_PWrenchDisplayFrame — which
// is the only thing that decides what the VIEWMODEL shows — had no arm for the
// wind at all and returned idle2 throughout.  The wind-up does not even set a
// weaponstate (it stays WS_IDLE by design, so +attack stays live), so there was
// nothing for the client to notice even in principle.
//
// Made shared and predicted instead.  Both fields are deliberately NOT on the
// prediction proxy: the client derives the whole charge from the +attack2 bit it
// already has, exactly as the AT launchers derive their shoulder hold, so there is
// nothing to reconcile and the only divergence is the client leading by ~1 RTT.
.float pwr_charge_start;   // when the wind-up began, 0 = not winding
.float pwr_big_swing;      // the swing in flight is the charged one

// Did THIS swing connect, and which swing that answer belongs to.  Both halves
// matter: the verdict is only known once the trace has run (server) or been
// predicted (client), and a reconcile REPLAY re-runs the try-fire without
// re-running the trace, so an unkeyed latch would be cleared on every replay and
// the hit take would flicker.  Keying on wep_action_id is the same guard
// csqc_crowbar_anim_id uses, and it needs no reset anywhere: a replay lands on
// the same action id the live pass did, and the next swing bumps it.
.float pwr_swing_hit;
.float pwr_swing_hit_id;

// Begins the wind-up.  Returns TRUE if it started this call.
float(float now) SH_PWrenchTryCharge =
{
    if (Weapon_SprintBlocksFire()) return FALSE;
    if (Weapon_LowerBlocksFire())  return FALSE;
    if (self.weaponstate == WS_DRAW) return FALSE;
    if (now < self.attack_finished)  return FALSE;
    if (self.pwr_charge_start)       return FALSE;   // already winding

    self.pwr_charge_start = now;
    return TRUE;
};

// Ends it.  Returns 1 for the charged swing, -1 for the ordinary one it decays
// into when released early, and 0 when nothing was wound.
//
// TEST THIS WITH == 1 / == -1.  In QC -1 is TRUTHY, so `if (SH_PWrenchRelease...)`
// treats the early release as a big swing.
float(float now) SH_PWrenchReleaseCharge =
{
    if (!self.pwr_charge_start)
        return 0;

    float held = now - self.pwr_charge_start;
    float big  = (held >= PWR_BIG_CHARGE_TIME);

    self.pwr_charge_start = 0;
    self.pwr_big_swing    = big;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + (big ? PWR_BIG_DELAY : PWR_FIRE_DELAY);
#ifdef CSQC
    // Without this the client's own +attack path (which gates on csqc_fire_guard,
    // not attack_finished) would let an ordinary swing start straight out of the
    // charged one.
    self.csqc_fire_guard = self.attack_finished;
#endif
    return big ? 1 : -1;
};

// The wind-up pose.  `attackbigwind` plays once and then `attackbigloop` holds —
// the model carries that 3-frame take for exactly this and NOTHING was playing it
// on the viewmodel.  Neither take has STUDIO_LOOPING (verified against the file:
// only idle2 and idle3 do), so the loop take is held by the engine's clamp on its
// last frame, which is the wound pose.
float(float held) SH_PWrenchSeqWind =
{
    if (held >= PWR_WIND_DURATION)
        return PWR_SEQ_BIGLOOP;
    return PWR_SEQ_BIGWIND;
};

// Did the swing in flight connect?  0 unless the latch belongs to THIS swing —
// see .pwr_swing_hit.  Entity form because the display path runs on
// predicted_player and the state machine on self, and they are not the same.
float(entity e) SH_PWrenchSwingHit =
{
    if (e.pwr_swing_hit_id != e.wep_action_id)
        return FALSE;
    return e.pwr_swing_hit;
};

// The take this swing is actually playing.  Six of the twelve swing sequences —
// every *hit variant, plus attackbighit — were UNREACHABLE before this: both
// entry points hardcoded `did_hit` FALSE and nothing corrected it once the trace
// had run, so a wrench that connected played the miss animation.
float(entity e) SH_PWrenchSwingSeq =
{
    float hit = SH_PWrenchSwingHit(e);
    if (e.pwr_big_swing)
        return hit ? PWR_SEQ_BIGHIT : PWR_SEQ_BIGMISS;
    return SH_PWrenchPickSwingSeq(e.wep_action_id, hit);
};

float(float now) SH_PWrenchTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= PWR_DRAW_DURATION) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        // Off the take that is actually on screen, not off a fixed longest-case.
        // The charged take is longer than the ordinary ones (attackbigmiss 0.967
        // against attack1miss 0.900) and the HIT takes are shorter than their own
        // miss partners (attack3hit 0.567 against attack3miss 0.733), so one
        // number could only ever be right for one of the six.  Same class of
        // defect as the reported "DoD knives have attack times too short".
        float dur = SH_SeqDuration(PWR_VIEWMODEL, SH_PWrenchSwingSeq(self),
                                   self.pwr_big_swing ? PWR_BIG_DURATION : PWR_FIRE_DURATION);
        if (elapsed >= dur) { SH_WeaponEnterIdle(); self.pwr_big_swing = 0; return 1; }
        return 0;
    }

    return 0;
};

float(float now) SH_PWrenchTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    // `now`-based — see sh_weapon_standard.qc SH_StandardTryFire.
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + PWR_FIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + PWR_FIRE_DELAY;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_PWrenchPickupCopy =
{
};

// `big` selects the charged swing's damage and its own sound set.
void(float big) W_PWrenchSwingEx =
{
    vector src, end;
    float dmg = big ? PWR_BIG_DAMAGE : PWR_DAMAGE;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * PWR_RANGE;

    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    // THE HIT VARIANT, and this is where it has to be latched.  W_PWrenchFire and
    // the charged release both set the MISS take before swinging, because at that
    // point the verdict is not known — but nothing ever corrected it afterwards,
    // so attack1hit / attack2hit / attack3hit could not play at all and half the
    // model's swing set was dead.  The crowbar has always done it here, off its
    // own trace (sh_wpn_hlcrowbar.qc:348), and the big swing has the same pair.
    self.pwr_swing_hit    = (trace_fraction < 1.0);
    self.pwr_swing_hit_id = self.wep_action_id;
    self.weaponframe      = SH_PWrenchSwingSeq(self);

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, dmg, W_BoneToHitgroup(trace_bone_id));

        float into_body = W_CanDamageTarget(trace_ent);

        // The set distinguishes hitting a BODY from hitting the world, and the
        // charged swing has its own pair of each.  Five of these twelve samples
        // had never been played by anything.
        if (big)
        {
            if (into_body)
                sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/pwrench_big_hitbod1.wav"
                                                          : "weapons/pwrench_big_hitbod2.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/pwrench_big_hit1.wav"
                                                          : "weapons/pwrench_big_hit2.wav", 1, ATTN_NORM);
        }
        else if (into_body)
        {
            float r = random();
            if (r < 0.333)      sound(self, CHAN_WEAPON, "weapons/pwrench_hitbod1.wav", 1, ATTN_NORM);
            else if (r < 0.666) sound(self, CHAN_WEAPON, "weapons/pwrench_hitbod2.wav", 1, ATTN_NORM);
            else                sound(self, CHAN_WEAPON, "weapons/pwrench_hitbod3.wav", 1, ATTN_NORM);
        }
        else
            sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/pwrench_hit1.wav"
                                                      : "weapons/pwrench_hit2.wav", 1, ATTN_NORM);

        if (into_body)
        {
            // Defer player damage to the attacker's client hitclaim so it is not
            // applied twice (server-auth + hitclaim).  BRACES MATTER — without
            // them the guard covers only the sv_dmg_bits line and the damage
            // lands regardless; see the same trap in sh_wpn_hlcrowbar.qc.
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                sv_dmg_bits = DMG_CLUB;
                W_ApplyDamage(self, trace_ent, dmg);
            }
        }
        else
        {
            PhysProp_TryPushFromTrace(v_forward, dmg);
            W_ImpactEffect(trace_endpos);
        }
    }
    else
    {
        if (big)
            sound(self, CHAN_WEAPON, "weapons/pwrench_big_miss.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/pwrench_miss1.wav"
                                                      : "weapons/pwrench_miss2.wav", 1, ATTN_NORM);
    }
};

void() W_PWrenchSwing =
{
    W_PWrenchSwingEx(FALSE);
};

void() W_PWrenchFire =
{
    if (SH_PWrenchTryFire(time))
    {
        // The miss take goes up first because the verdict is not known yet;
        // W_PWrenchSwingEx re-picks it off its own trace one call later.  A
        // predicted verdict that disagrees for one swing is the same documented
        // tradeoff the crowbar carries.
        self.weaponframe   = SH_PWrenchPickSwingSeq(self.wep_action_id, FALSE);
        self.wep_nextframe = time + PWR_FRAME_INTERVAL;
        W_PWrenchSwing();
    }
};

// Secondary: hold to wind, release to swing.  The gate itself is shared now
// (SH_PWrenchTryCharge) so the client can run the identical test and show the
// wind-up on the viewmodel; this half keeps only what is server-side, which is
// the frame pump and the damage.
void() W_PWrenchFire2 =
{
    if (SH_PWrenchTryCharge(time))
    {
        self.weaponframe   = PWR_SEQ_BIGWIND;
        self.wep_nextframe = time + PWR_FRAME_INTERVAL;
    }
};

void() W_PWrenchFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += PWR_FRAME_INTERVAL;

    // Charged swing released.  Held long enough it lands the big hit; released
    // early it is a normal swing, which is what stops the charge being free.
    //
    // .button1, NOT .button3 — and this one word was the whole bug behind "the
    // pipewrench still doesn't have an +attack2 charge attack".  The engine
    // writes exactly three of these fields (pr_cmds.c:10401-10404): button0 from
    // bit 0 (+attack), button2 from bit 1 (+jump) and button1 from bit 2
    // (+attack2).  Nothing ever writes button3, so this test read "the button is
    // not held" on the very first tick after the wind started — every single
    // time.  `held` came out at about one frame, never reached
    // PWR_BIG_CHARGE_TIME, and the charged swing was unreachable: +attack2 wound
    // for a frame and then threw an ordinary swing.
    //
    // sh_wpn_wrench.qc:220 already carried the corrected form and the reason.
    // sh_wpn_opknife.qc had the identical typo and is fixed with this.
    if (self.pwr_charge_start && !(self.button1))
    {
        float rel = SH_PWrenchReleaseCharge(time);

        // == 1, not truthiness: the shared helper returns -1 for the ordinary
        // swing an early release decays into, and -1 is TRUE in QC.
        float big = (rel == 1);

        self.weaponframe   = big ? PWR_SEQ_BIGMISS
                                 : SH_PWrenchPickSwingSeq(self.wep_action_id, FALSE);
        self.wep_nextframe = time + PWR_FRAME_INTERVAL;

        W_PWrenchSwingEx(big);
    }
    // Still winding — hold the short take the model provides for it rather than
    // letting the wind-up animation clamp to its last frame.  The threshold is
    // the WIND take's own length; it used to be PWR_BIG_DURATION (attackbigmiss,
    // 0.967) which is a different sequence entirely, so the hold pose arrived
    // 0.100 s late.
    else if (self.pwr_charge_start)
    {
        self.weaponframe   = SH_PWrenchSeqWind(time - self.pwr_charge_start);
        self.wep_nextframe = time + PWR_FRAME_INTERVAL;
        return;
    }

    float result = SH_PWrenchTickState(time);
    if (result & 1)
    {
        // The resting pose has to be a LOOPING sequence — idle1 is not one; 1
        // and 2 are.  See the note in sh_wpn_thspanner.qc for what holding a
        // non-looping sequence does.
        self.weaponframe   = PWR_SEQ_IDLE2;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_PWrenchEquip =
{
    W_StandardEquipSetup(PWR_VIEWMODEL, PWR_DISPLAY_NAME, PWR_SEQ_DRAW,
        PWR_FRAME_INTERVAL, PLAYER_ATTACKANIM_MELEE);
    self.fire     = W_PWrenchFire;
    self.altfire  = W_PWrenchFire2;
    self.reload   = __NULL__;
    self.wepframe = W_PWrenchFrame;
    self.shoot    = W_PWrenchSwing;
    self.pwr_charge_start = 0;
    self.pwr_big_swing    = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_PWrenchDrop =
{
    entity tgt = weapon_drop_target;

    self.pwr_charge_start = 0;

    setmodel(tgt, PWR_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_pipewrench";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_PIPEWRENCH;
    tgt.weapon_slot    = SLOT_MELEE;
    tgt.weap_draw      = W_PWrenchEquip;
    tgt.weap_drop_func = W_PWrenchDrop;
    tgt.pickupcopy     = W_PWrenchPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.dropped_spin   = 0;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_pipewrench =
{
    setmodel(self, PWR_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_pipewrench";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_PIPEWRENCH;
    self.weapon_slot    = SLOT_MELEE;
    self.weap_draw      = W_PWrenchEquip;
    self.weap_drop_func = W_PWrenchDrop;
    self.pickupcopy     = W_PWrenchPickupCopy;
    self.touch          = weapon_touch;
    self.dropped_spin   = 0;
    W_RegisterMapWeapon(weapon_pipewrench);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictPWrenchCommand =
{
    // Switching away mid-wind leaves the client's charge latched (it is not on
    // the prediction proxy, so nothing corrects it), and the wind arm in the
    // display frame would then show a wound-up wrench the moment the re-draw
    // ended.  The server clears its copy in W_PWrenchEquip; this is the client's
    // equivalent, and it lives here rather than in CSQC_PWrenchEquip because that
    // function re-runs on every reconcile and would cancel a live charge 20 times
    // a second.
    if (self.weaponstate == WS_DRAW)
        self.pwr_charge_start = 0;

    // Primary only.  The charged swing is server-side (see W_PWrenchFire2).
    // The TRY-FIRE must run on replay passes too; only the trace and its audio
    // are replay-suppressed.  pm_suppress_sounds marks a prediction REPLAY, and
    // with it on the outer test the replay skipped the swing entirely: every
    // reconcile reset to the confirmed state and then re-ran the buffered
    // commands without ever re-entering WS_FIRE, so CSQC_PWrenchDisplayFrame
    // kept returning the idle pose and +attack looked like it did nothing at all.
    // The server was swinging and dealing damage the whole time.
    if (input_buttons & 1)
    {
        if (SH_PWrenchTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // The Ex form, with the FLESH pair W_PWrenchSwingEx has always
                // played and this call never did: with an empty body tail the
                // helper falls through to the material slots on a player hit, so
                // hitting someone rang the metal-on-concrete sample while the
                // server's correct pwrench_hitbod set was muted on the attacker
                // by the 1 s predicted-echo suppressor (client/cl_main.qc:1399).
                // Latched, so the hit take can play here too — the helper's
                // return IS the verdict.  Only the live pass reaches this (the
                // trace and its audio are replay-suppressed); the key on
                // wep_action_id is what carries it through the replays that
                // follow, exactly as csqc_crowbar_anim_id does.
                self.pwr_swing_hit    = CSQC_PredictedMeleeTraceEx(PWR_RANGE, PWR_DAMAGE,
                    "weapons/pwrench_hit1.wav",
                    "weapons/pwrench_hit2.wav",
                    "weapons/pwrench_miss1.wav",
                    "weapons/pwrench_hitbod1.wav",
                    "weapons/pwrench_hitbod2.wav",
                    "weapons/pwrench_hitbod3.wav");
                self.pwr_swing_hit_id = self.wep_action_id;
                // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
                CSQC_RecordPredictedMeleeSound();
            }
        }
    }

    // THE CHARGED SWING, PREDICTED.  Hold +attack2 to wind, release to swing.
    // Previously server-only, which is why the viewmodel never moved for it.
    // The try/release gates run OUTSIDE the pm_suppress_sounds test so a replay
    // walks the same state the live pass did — the trap that made +attack look
    // inert on this weapon once already (see the note at the top of this function).
    if (input_buttons & 4)
    {
        if (SH_PWrenchTryCharge(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }
    else
    {
        float rel = SH_PWrenchReleaseCharge(csqc_pred_time);
        // != 0 rather than truthiness: -1 (the early release) is TRUE in QC, so
        // the two arms below have to be separated explicitly.
        if (rel != 0)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (rel == 1)
                    self.pwr_swing_hit = CSQC_PredictedMeleeTraceEx(PWR_RANGE, PWR_BIG_DAMAGE,
                        "weapons/pwrench_big_hit1.wav",
                        "weapons/pwrench_big_hit2.wav",
                        "weapons/pwrench_big_miss.wav",
                        "weapons/pwrench_big_hitbod1.wav",
                        "weapons/pwrench_big_hitbod2.wav",
                        "");
                else
                    self.pwr_swing_hit = CSQC_PredictedMeleeTraceEx(PWR_RANGE, PWR_DAMAGE,
                        "weapons/pwrench_hit1.wav",
                        "weapons/pwrench_hit2.wav",
                        "weapons/pwrench_miss1.wav",
                        "weapons/pwrench_hitbod1.wav",
                        "weapons/pwrench_hitbod2.wav",
                        "weapons/pwrench_hitbod3.wav");
                self.pwr_swing_hit_id = self.wep_action_id;
                CSQC_RecordPredictedMeleeSound();
            }
        }
    }

    SH_PWrenchTickState(csqc_pred_time);
};

float(float elapsed) CSQC_PWrenchDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return PWR_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // One call covers all six swing takes — charged or not, hit or miss.
        // The charged pair used to be unreachable from here (this arm always
        // returned an ordinary swing, so even the RELEASE of a full charge showed
        // a normal one) and so did every *hit variant.
        //
        // Driven by the RENDERED entity throughout, so a spectated player's
        // viewmodel swings off THEIR counter and THEIR verdict rather than ours
        // (cl_weapons.qc:1805 calls this with predicted_player pointed at a
        // scratch entity, whose latch key will not match — it falls back to the
        // miss cycle, which is what a swing looks like when nothing was hit).
        return SH_PWrenchSwingSeq(predicted_player);
    }

    // THE WIND-UP.  Deliberately outside the weaponstate ladder: winding leaves
    // the weapon in WS_IDLE (so +attack stays live and the ordinary swing can
    // still interrupt), which is precisely why nothing here noticed it before.
    //
    // The take is anchored to the moment the charge began rather than left to
    // free-run, because an idle viewmodel feeds the engine an unbounded
    // frame1time and a non-looping sequence would already be clamped on its last
    // frame before the wind even started.
    if (predicted_player.pwr_charge_start > 0)
    {
        float held = cltime - predicted_player.pwr_charge_start;
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time          = max(0, held);
        return SH_PWrenchSeqWind(held);
    }

    return PWR_SEQ_IDLE2;   // LOOPING — safe to hold
};

void() CSQC_PWrenchDropClear =
{
};

void() CSQC_PWrenchEquip =
{
    self.weapon_name         = PWR_DISPLAY_NAME;
    self.weapon_viewmodel    = PWR_VIEWMODEL;
    self.weapon_worldmodel   = PWR_WORLDMODEL;
    self.weapon_deploy_sound = PWR_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictPWrenchCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_PWrenchDisplayFrame;
    self.csqc_drop_clear     = CSQC_PWrenchDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
