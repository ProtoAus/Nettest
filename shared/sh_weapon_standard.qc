// ============================================================
//  shared/sh_weapon_standard.qc  -  Generic weapon functions
//
//  Compiled by both sv_progs and cl_progs.
//  Standard hitscan weapons delegate to these instead of
//  duplicating the same logic in every sh_wpn_*.qc file.
//
//  Uses FTEQW field-reference parameters (.float) so the
//  generic functions can read/write per-weapon ammo fields.
// ============================================================

// Fire spread penalty constants are in sh_customdefs.qc
// (must be available before sh_pmove.qc in cl_progs compile order)

#ifdef SSQC
// Server death-ragdoll bullet shove (sv_ragdoll.qc, compiled later) — fwd-decl so the
// hitscan sites below can call it.  Server-only (ragdolls live in sv.world).
void(vector src, vector shotend, vector dir, float damage) Ragdoll_TryShove;
#endif

// ============================================================
//  SHARED — state machines
// ============================================================

// Generic tick state for weapons with draw/fire/reload cycle.
// Returns bitmask: bit 0 = transitioned to idle, bit 1 = reload ammo applied.
float(float now,
      .float mag_fld, .float ammo_fld, float max_mag,
      float draw_dur, float fire_dur,
      float reload_dur, float reload_apply_time) SH_StandardTickState =
{
    float elapsed, result, needed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    result = 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= draw_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= fire_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= reload_apply_time)
        {
            needed = max_mag - self.(mag_fld);
            if (needed > 0)
            {
                if (self.(ammo_fld) >= needed)
                {
                    self.(mag_fld)  += needed;
                    self.(ammo_fld) -= needed;
                }
                else
                {
                    self.(mag_fld)  += self.(ammo_fld);
                    self.(ammo_fld)  = 0;
                }
                result = result | 2;
            }
        }

        if (elapsed >= reload_dur)
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return 0;
};

// Simple tick state for weapons with only draw + fire (no reload).
// Returns: 1 = transitioned to idle, 0 = no change.
float(float now, float draw_dur, float fire_dur) SH_SimpleTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= draw_dur)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= fire_dur)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

// ============================================================
//  SHARED — fire / reload validation
// ============================================================

// Forward decl — SH_StandardTryFireSemiAuto below is defined before
// SH_StandardTryFire so the semi-auto wrapper can call the underlying
// helper.  Definition follows immediately.
float(float now, .float mag_fld, float fire_delay, float dryfire_delay) SH_StandardTryFire;

// Forward decl — sh_pmove.qc declares .pm_oldbuttons but the SSQC
// build order (sv_progs.src) compiles this file BEFORE sh_pmove.qc.
// CSQC's cl_progs.src has the reverse order so it's redundant there
// but harmless.  Same logic for the PM_BTN_FIRE bit constant — we
// use the literal value 1 below so no forward decl is needed for it.
.float pm_oldbuttons;

#ifdef SSQC
// server/sv_ai_core.qc, which compiles a long way below this file - QC
// forward-declares functions, so the ordering costs one line.
void(entity who) AI_HeardGunfire;
#endif

// Semi-auto wrapper around SH_StandardTryFire.
// Blocks fire when +attack was already held last pmove tick — the
// player must release and re-press for each shot.  Used by handguns
// (Beretta M9, USP, Deagle, .357, 9mm) to prevent hold-to-empty.
//
// Edge state lives in bit 0 (PM_BTN_FIRE) of self.pm_oldbuttons,
// which PM_PlayerMove updates at the end of each tick.  Because
// CSQC_PredictWeaponCommand (and SSQC's W_WeaponFrame) run BEFORE
// PM_PlayerMove on their respective sides, pm_oldbuttons read here
// reflects the PREVIOUS tick's button state — exactly the "was held"
// reference needed for rising-edge detection.
//
// pm_oldbuttons is already replicated through the prediction proxy
// (it carries duck-edge tracking too), so reconcile-replay sees the
// correct baseline on every rewind.
//
// Returns: 1 = fired, -1 = dry fire, 0 = blocked (no-edge OR underlying
// SH_StandardTryFire blocked).
float(float now, .float mag_fld,
      float fire_delay, float dryfire_delay) SH_StandardTryFireSemiAuto =
{
    // Rising-edge gate.  If +attack was held last tick, swallow the
    // press silently — no dryfire sound, no fire — until the player
    // releases it.
    if ((input_buttons & 1) && (self.pm_oldbuttons & 1))   // bit 0 = PM_BTN_FIRE
        return 0;
    return SH_StandardTryFire(now, mag_fld, fire_delay, dryfire_delay);
};

// Generic fire validation for standard weapons.
// Returns: 1 = fired, -1 = dry fire, 0 = blocked.
float(float now, .float mag_fld,
      float fire_delay, float dryfire_delay) SH_StandardTryFire =
{
    // Server-policy: sv_sprintdisableshooting blocks firing while the
    // player is in a sprinting stance.  Routed through the same shared
    // helper on both CSQC (prediction) and SSQC (authoritative) so the
    // block engages identically and prediction can't ghost-fire.
    if (Weapon_SprintBlocksFire())
        return 0;
    // Lower-pose block: grapple active OR (sv_codladders + on ladder).
    // Same dual-side routing as the sprint gate — keeps the viewmodel
    // visual (dropped off-screen via the cl_viewfx lower envelope) and
    // the fire decision in lockstep so prediction can't trigger an
    // input that the server is going to reject.
    if (Weapon_LowerBlocksFire())
        return 0;
    // A raised tactical shield occupies the hand that would pull the trigger.
    // Gated here rather than per-weapon for the same reason the sprint and
    // ladder gates above are: it has to hold on BOTH sides, or prediction fires
    // a shot the server then refuses.
    if (SH_ShieldBlocksFire())
        return 0;
#ifdef CSQC
    // Client-local fire latch. See .csqc_fire_guard in sh_customdefs.qc.
    // Must sit before the attack_finished check so stale snaps can't bypass it.
    //
    // Uses `now` (csqc_pred_time), NOT cltime — both are monotonic so the
    // pause-snap protection still works, but during reconcile-replay
    // `now` is the buffered timestamp (past) while cltime is current.
    // The cltime-based check used to pass during replay (cltime way past
    // guard), letting replay re-fire silently and advance attack_finished
    // beyond live cltime — at which point live fires got blocked until
    // attack_finished caught up.  Switching to `now` makes the guard work
    // correctly in both live (now == cltime) and replay (now == past)
    // contexts.
    if (now < self.csqc_fire_guard)
        return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    if (self.(mag_fld) <= 0)
    {
        self.attack_finished = now + dryfire_delay;
#ifdef CSQC
        self.csqc_fire_guard = now + dryfire_delay;
#endif
        return -1;
    }

    self.(mag_fld)       -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    // One refire period is exactly how long the third-person shoot pose should
    // occupy — see .wep_state_dur in sh_weapons.qc.
    self.wep_state_dur    = fire_delay;

    // sv_codstamina + cl_codscope: stamp the absolute-time at which
    // post-fire scope suppression should release.  Drives THREE
    // behaviours that all read this same field:
    //   (a) Pmove stamina drain stops counting +attack2 as scoped
    //       while time < this stamp (fixes "bar keeps depleting after
    //       fire" — drain only resumes once the scope visually re-engages).
    //   (b) cl_viewfx ADS target = 0 while suppressed → gun drops
    //       out of ADS even with +attack2 held.
    //   (c) cl_codscope state machine's OFF→RAISING re-entry stays
    //       blocked until expiry, then auto-re-engages if the player
    //       is still holding +attack2 (the "return to ADS scoping in
    //       after the shot is complete" behaviour).
    //  Uses `time` (the pmove clock that PM_PlayerMoveStep reads) so
    //  CSQC + SSQC + reconcile-replay all see consistent values.
    //  Set even when sv_codstamina is off because cl_codscope's
    //  fire-cancel + auto-re-engage hooks read the same field.
    self.pm_fire_suppress_until = time
        + PM_ReadMovevar("sv_codstamina_fire_suppress_time", 0.4);

    // Effective fire delay — for CSQC, floor at sv_mintic so the
    // client's predicted fire rate matches what the server can
    // physically deliver.  Server's W_WeaponFrame fires AT MOST once
    // per server tick (sv_weapons.qc:2893), so a weapon with
    // fire_delay < sv_mintic has its effective server rate clamped
    // to 1/sv_mintic.  Without the same clamp on the client, the
    // client predicts EXTRA fires the server never produces (the
    // "burst trick": tap +attack for one fire-delay-and-a-bit and
    // get TWO client traces but only ONE server impact, with the
    // ammo counter falling out of sync).  SSQC keeps the raw
    // fire_delay — its actual rate ceiling is the tick rate
    // already, so no double-clamping needed.
    float effective_delay = fire_delay;
#ifdef CSQC
    float tick = serverkeyfloat("sv_mintic", 0.01);
    if (tick > effective_delay)
        effective_delay = tick;
#endif

    // Phase-locked cadence — when we're inside a held-trigger burst
    // (gate elapsed by less than one period), advance attack_finished
    // by EXACTLY effective_delay so successive shots stay on a stable
    // rhythm regardless of tick alignment.  The naive `now + delay`
    // pattern drifts: each shot rebases the next-fire stamp from the
    // moment of fire (which is always slightly LATER than the gate
    // expired), accumulating ~one tick of drift per shot and
    // perceptibly slowing sustained fire below the target RPS.
    //
    // If we've been idle longer than one period (trigger released,
    // server hitch, weapon-switch settle), reset the phase so the
    // first shot of a fresh burst doesn't try to "catch up" by firing
    // multiple times in one tick.
    if (now - self.attack_finished < effective_delay)
        self.attack_finished += effective_delay;
    else
        self.attack_finished  = now + effective_delay;
#ifdef CSQC
    // Mirror onto the CSQC reconcile-replay guard.  Same value either
    // way — keeps the guard at least as far in the future as the
    // server-authoritative attack_finished so stale snapshots can't
    // re-fire under reconcile.
    self.csqc_fire_guard  = self.attack_finished;

    // Client-shot notification.  Under sv_trust_clienthits >= 1 the
    // server's W_WeaponFrame skips its own auto-fire (see the gate in
    // server/sv_weapons.qc) and instead waits for this `cmd cs` to
    // call self.fire() exactly once per predicted client fire.  That
    // eliminates the rate-divergence symptom — "client mag empty
    // while the server is still firing extra shots" — by making the
    // server's fire count definitionally equal to the client's.
    //
    // Gated on !pm_suppress_sounds so reconcile-replay ticks (which
    // re-run already-fired buffered cmds with sounds suppressed) don't
    // re-emit the cs cmd.  The first live-discovery of a shot does
    // run with pm_suppress_sounds=FALSE (or temporarily unsuppressed
    // through CSQC_BeginFireActionEffects), so live emissions still
    // get through.
    if (!pm_suppress_sounds)
    {
        // Include the current scope sway delta (pitch, yaw in degrees)
        // so the server's authoritative trace inside the `cs` handler
        // can bias self.v_angle by the same amount the CSQC predict
        // trace used.  Zero for unscoped weapons / sv_snipersway off.
        localcmd(sprintf("cmd cs %g %g %g\n", self.weapon,
            csqc_codscope_sway_pitch, csqc_codscope_sway_yaw));
    }
#endif
    // Queue penalty — applied AFTER this shot's spread is calculated
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
#ifdef SSQC
    // Tell the monsters.  This is the single authoritative "a shot was fired"
    // point for every standard weapon, which is why the hook lives here rather
    // than in each of the fifty weapon files.
    //
    // SSQC only: on the client this function also runs during prediction and
    // reconcile-replay, where firing it would be both meaningless (no monsters)
    // and repeated.  AI_HeardGunfire rate-limits itself globally, so a minigun
    // costs the same as a pistol.
    AI_HeardGunfire(self);
#endif
    return 1;
};

// Generic reload validation for standard weapons.
// Returns: 1 = reload started, 0 = blocked.
float(float now, .float mag_fld, .float ammo_fld,
      float max_mag, float reload_dur) SH_StandardTryReload =
{
#ifdef CSQC
    // Client-local reload latch. See .csqc_reload_guard in sh_customdefs.qc.
    // Uses `now` not cltime — same rationale as the fire guard above.
    if (now < self.csqc_reload_guard)
        return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW)
        return 0;
    if (self.(mag_fld) >= max_mag || self.(ammo_fld) <= 0)
        return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.wep_state_dur   = reload_dur;   // see .wep_state_dur in sh_weapons.qc
#ifdef CSQC
    self.csqc_reload_guard = now + reload_dur;
#endif
    return 1;
};

// Non-fire action gate.  Same shape as SH_StandardTryFire but without
// mag/dryfire/spread bookkeeping — pure "is the player allowed to start
// this action right now" gate.  Used for melee specials, inspections,
// any non-mag-consuming action.  Pass the target weaponstate (commonly
// WS_FIRE / WS_SPECIAL / WS_RELOAD) and the cooldown delay.
//
// Returns: 1 = action started, 0 = blocked.
float(float now, float target_state, float delay) SH_StandardTryAction =
{
    if (Weapon_SprintBlocksFire())
        return 0;
    if (Weapon_LowerBlocksFire())
        return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard)
        return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate     = target_state;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + delay;
#ifdef CSQC
    self.csqc_fire_guard = now + delay;
#endif
    return 1;
};

// ============================================================
//  SHARED — sequence-duration lookup (GoldSrc MDL)
// ============================================================

// Returns the natural length (seconds) of a sequence in a GoldSrc-format
// MDL, asking the engine via frameduration() instead of hardcoding it.
// `viewmodel_path` must already be precached — getmodelindex returns 0
// otherwise, in which case we fall back to the supplied default so a
// freshly-loaded map doesn't see zero-length anims for one tick before
// the engine catches up.
// AND A SEQUENCE AUTHORED AT 0 FPS RETURNS INFINITY, not zero.  The engine
// computes `(numframes-1)/timing` verbatim (gl_hlmdl.c:1763) with no divide
// guard, so svencoop's v_9mmar.mdl `launch` — 181 frames at 0.00 fps — comes back
// as +inf and sails straight past a `dur <= 0` test.  Any state that took its
// length from it would never retire, which for the SMG's grenade is a weapon
// frozen mid-launch for the rest of the map.  The seqprobe row prints it plainly:
//     seqprobe models/v_9mmar.mdl ... launch(inf) ...
// SEQ_DURATION_SANE_MAX is far above any real take here (the longest is the CS
// knife's 12.583 s idle) and far below infinity, so it separates the two without
// having to express a NaN/inf test in QC.
const float SEQ_DURATION_SANE_MAX = 600;

float(string viewmodel_path, float seq, float fallback) SH_SeqDuration =
{
    float midx = getmodelindex(viewmodel_path);
    if (midx <= 0)
        return fallback;
    float dur = frameduration(midx, seq);
    if (dur <= 0 || dur > SEQ_DURATION_SANE_MAX)
        return fallback;
    return dur;
};

// Resolve a sequence by NAME, so weapon code can say "reload" instead of a
// magic index that quietly means something else after a model is swapped.
// This is the same lookup the monster AI has always used
// (AI_SetSequenceNamed / AI_SeqNameExists at sv_ai_anim.qc:505/:526) —
// weapons simply never adopted it, and every sh_wpn_*.qc still hardcodes
// indices it read out of the model by hand.
//
// `fallback` is returned when the model is not precached yet, carries no
// sequence by that name, or has no names at all.  That last case is not
// hypothetical: an IDPO conversion overwrites every frame name with
// "frame0".."frameN", and FTE groups Quake MDL frames by stripping the
// trailing digits, so the whole model collapses into ONE group named
// "frame" and every lookup here whiffs.  Passing the old hardcoded index
// as the fallback therefore degrades to exactly the previous behaviour.
//
// Range-check the upper end for the same reason AI_SeqForActivity does:
// frameduration silently clamps an out-of-range index and hands back a
// plausible duration for the WRONG sequence, which surfaces as a subtle
// timing bug rather than an obviously missing animation.
float(string viewmodel_path, string seqname, float fallback) SH_SeqForName =
{
    float midx = getmodelindex(viewmodel_path);
    if (midx <= 0)
        return fallback;

    float n = modelframecount(midx);
    float seq = frameforname(midx, seqname);
    if (seq >= 0 && seq < n)
        return seq;

    // THE FALLBACK IS RANGE-CHECKED TOO, which the first version of this did not
    // do.  It matters whenever the same path resolves to different models on
    // different installs: sh_wpn_opsporelauncher.qc asks for sequence 9, which
    // exists on the Sven copy of v_spore_launcher.mdl and not on the gearbox copy
    // (0..8).  Handing that straight back would put an out-of-range index into
    // .frame, and frameduration silently clamps out-of-range to 0 and returns a
    // plausible duration for it - a wrong-animation bug wearing the costume of a
    // timing bug.  0 is the honest answer: on every GoldSrc viewmodel in this tree
    // sequence 0 is an idle, which is the safest thing to be caught playing.
    if (n > 0 && (fallback < 0 || fallback >= n))
        return 0;
    return fallback;
};

// THE PROBE FORM.  Returns the sequence, or a HONEST -1 when the model does not
// carry that name.
//
// SH_SeqForName above must never be used as a probe, and this exists because it
// was.  Its range check launders a negative fallback into 0 — deliberately, and
// correctly, for a real fallback — so `SH_SeqForName(m, "exploding_pinpull", -1)`
// followed by `if (e >= 0) return e;` reads as "use the cooked pose if the model
// has one" and actually means "always return sequence 0", which on every GoldSrc
// viewmodel in this tree is the IDLE.
//
// That is precisely how the three Counter-Strike grenades ended up rendering their
// entire pin-pull and throw as the resting pose: the cook looked like nothing was
// happening at all, while the pin sound still played on schedule.
//
// Same range check on the upper end for the same reason SH_SeqForName has it, and
// the same unprecached-model escape: an unloaded model cannot answer, so -1.
float(string viewmodel_path, string seqname) SH_SeqTryName =
{
    float midx = getmodelindex(viewmodel_path);
    if (midx <= 0)
        return -1;

    float n   = modelframecount(midx);
    float seq = frameforname(midx, seqname);
    if (seq >= 0 && seq < n)
        return seq;
    return -1;
};

// Two-name form, for a path that resolves to models from different source games
// that named the same animation differently.  v_9mmar.mdl is the case that forced
// it: valve and gearbox label the firing takes "shoot", Sven Co-op labels them
// "fire1".."fire3".  Tries `first`, then `second`, then the fallback.
float(string viewmodel_path, string first, string second, float fallback) SH_SeqForName2 =
{
    float midx = getmodelindex(viewmodel_path);
    if (midx <= 0)
        return fallback;
    float seq = frameforname(midx, first);
    if (seq >= 0 && seq < modelframecount(midx))
        return seq;
    return SH_SeqForName(viewmodel_path, second, fallback);
};

// Tick state for sequence-driven (GoldSrc) weapons that don't need the
// reload-apply ammo-transfer branch.  `self.weaponframe` already encodes
// which sequence is playing (set on equip / fire / alt-fire / special),
// so we ask SH_SeqDuration for that sequence's natural length and exit
// the current state when elapsed >= duration.
//
// Returns: 1 = transitioned to idle, 0 = no change.
//
// The caller is responsible for setting weaponframe = idle_seq AFTER
// this returns 1 if the renderer should play an idle loop — same
// post-tick contract every weapon already follows.  The 0.5s fallback
// is generous; real anims are always at least that long in practice.
float(float now, string viewmodel_path) SH_SeqDrivenTickState =
{
    float elapsed;
    float seq_dur;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    seq_dur = SH_SeqDuration(viewmodel_path, self.weaponframe, 0.5);

    if (elapsed >= seq_dur)
    {
        SH_WeaponEnterIdle();
        return 1;
    }
    return 0;
};

#ifdef CSQC
// ============================================================
//  CLIENT ONLY — idle driver for viewmodels with NO looping idle
// ============================================================
//
// Once a weapon is idle, wep_anim_start is 0 and cl_weapons.qc:1695 feeds
// frame1time = cltime — absolute, unbounded — so the engine clamps a
// NON-looping sequence to its final frame (gl_hlmdl.c:1076-1082) and the
// viewmodel is a still image for the rest of the map.  A looping idle is the
// easy answer and most Half-Life viewmodels have one, but plenty do not:
// v_9mmar.mdl carries flags=0 on all eight sequences, and so do six of the
// eight They Hunger viewmodels.  GoldSrc gets away with it because
// CBasePlayerWeapon::WeaponIdle re-SENDS an idle every 10-15 s (mp5.cpp:259-283)
// rather than relying on the loop flag; this reproduces that re-send.
//
// Anchoring is what makes it work: overriding frame1time with `now - anchor`
// restarts the sequence at frame 0 each time one is rolled, so a non-looping
// idle plays through, holds its last pose, and plays again on the next roll.
//
// One set of globals for every caller.  Only one weapon is drawn at a time,
// and `wep` re-arms them on a switch — without that key a fidget index from
// the previous gun would be handed to a model that may not have that many
// sequences.
//
// The prototype for this lived open-coded in sh_wpn_hlsmg.qc, which is the
// commented reference; the six They Hunger weapons would have been six more
// copies of it.
float csqc_seqidle_anchor;      // cltime the current idle sequence started at
float csqc_seqidle_seq;         // which idle is playing
float csqc_seqidle_next;        // cltime at which to roll the next one
float csqc_seqidle_prev_state;  // previous render frame's weaponstate
float csqc_seqidle_owner_wep;   // the .weapon the three above belong to

// Call FIRST from a csqc_display_frame implementation, for EVERY state — it
// has to see the non-idle frames to catch the return-to-idle edge.  Returns
// the idle sequence to display, or -1 when the weapon is not idle, in which
// case the caller falls through to its own per-state picks.
//
// seq_a is the resting idle (also the one used for the first idle after any
// action, so the gun settles the same way every time); seq_b is the fidget
// that alternates in with it.  Pass seq_a twice for a weapon with only one.
float(float now, float wep, float state, float seq_a, float seq_b,
      float rearm_min, float rearm_max) SH_SeqIdleDisplay =
{
    // Weapon switch: drop the previous gun's pick and force a roll below.
    if (csqc_seqidle_owner_wep != wep)
    {
        csqc_seqidle_owner_wep  = wep;
        csqc_seqidle_prev_state = -1;
        csqc_seqidle_next       = 0;
    }

    // Non-idle -> idle edge, so the settle always starts from frame 0 rather
    // than wherever a long-running roll happened to be.
    float entered_idle = (state == WS_IDLE && csqc_seqidle_prev_state != WS_IDLE);
    csqc_seqidle_prev_state = state;

    if (state != WS_IDLE)
        return -1;

    if (entered_idle)
    {
        // Settle onto the resting idle's LAST frame, not its first.
        //
        // Restarting it from frame 0 here meant the idle animation replayed the
        // instant you stopped firing, every time -- the gun visibly fidgeting
        // after each burst.  GoldSrc does the opposite: PrimaryAttack pushes
        // m_flTimeWeaponIdle out to +10..15 s (mp5.cpp:193) and WeaponIdle
        // returns early until then (mp5.cpp:265), so no idle is sent at all and
        // the viewmodel just holds the pose it finished shooting in.
        //
        // Anchoring one full sequence-length in the past reproduces that: the
        // engine clamps a non-looping sequence to its final frame
        // (gl_hlmdl.c:1076-1082), which IS the rest pose, so the gun settles
        // with no motion.  The first real fidget then rolls below on the normal
        // rearm timer.  Every weapon on this helper has non-looping idles --
        // that is the reason the helper exists -- so the clamp is reliable.
        csqc_seqidle_seq    = seq_a;
        csqc_seqidle_anchor = now - SH_SeqDuration(predicted_player.weapon_viewmodel,
                                                   seq_a, 2.0);
        csqc_seqidle_next   = now + rearm_min + random() * (rearm_max - rearm_min);
    }
    else if (now >= csqc_seqidle_next)
    {
        csqc_seqidle_seq    = (random() < 0.5) ? seq_a : seq_b;
        csqc_seqidle_anchor = now;
        csqc_seqidle_next   = now + rearm_min + random() * (rearm_max - rearm_min);
    }

    csqc_viewmodel_sequence_time_override = TRUE;
    csqc_viewmodel_sequence_time          = max(0, now - csqc_seqidle_anchor);
    return csqc_seqidle_seq;
};
#endif // CSQC

// ============================================================
//  SERVER ONLY — hitscan + equip helpers
// ============================================================

#ifdef SSQC

// Set TRUE inside W_RadiusExplode's breakable loop so the per-call
// damage path (W_ApplyDamage / W_CanDamageTarget in sv_weapons.qc)
// knows it's serving a radius explosion.  Two effects:
//   (1) bypass the sv_trust_clientbreak deferral — clients never
//       predict explosions, so deferring would silently drop the hit
//   (2) accept BREAKABLE_ONLY_EXPLOSION brushes (spawned with
//       takedamage = DAMAGE_NO, the flag means "no for hitscan, yes
//       for me")
// Declared here because sh_weapon_standard.qc compiles before
// sv_weapons.qc — the declaration must precede the consumer.
float sv_in_radius_explosion;

// ---------------------------------------------------------------------------
// damage TYPE  —  sv_dmg_bits
// ---------------------------------------------------------------------------
// Half-Life carries a bitsDamageType through every damage call, and one specific
// mask decides whether a hit can tear a corpse apart:
//
//   #define DMG_GIB_CORPSE (DMG_CRUSH|DMG_FALL|DMG_BLAST|DMG_SONIC|DMG_CLUB)
//                                                             cbase.h:638
//
// DMG_BULLET is deliberately NOT in it.  That is the rule behind something every
// Half-Life player knows without being told: you can shoot a body all day and it
// just bleeds, but one crowbar swing or one grenade turns it into pieces.
//
// This is a GLOBAL rather than a parameter because W_ApplyDamage has 58 call
// sites and the overwhelming majority of them are bullets.  Making it a
// parameter would mean touching all 58 to write "DMG_BULLET" 50-odd times, for
// no behaviour.  Instead 0 means bullet, the handful of sources that are NOT
// bullets set it immediately before the call, and W_ApplyDamage reads-and-clears
// it at the top so a value can never leak into the next hit.  Same shape, and
// the same reasoning, as sv_in_radius_explosion directly above.
const float DMG_BULLET = 1;
const float DMG_CLUB   = 2;		// crowbar, knife, any melee — and monster claws
const float DMG_BLAST  = 4;		// explosions
const float DMG_SONIC  = 8;		// houndeye shockwave
const float DMG_CRUSH  = 16;	// doors, trains, movers
const float DMG_FALL   = 32;
const float DMG_DROWN  = 64;	// CBasePlayer::WaterMove, player.cpp:1275

const float DMG_GIB_CORPSE = 62;	// CLUB|BLAST|SONIC|CRUSH|FALL — cbase.h:638
float sv_dmg_bits;					// 0 == DMG_BULLET

// THESE ARE NOT HALF-LIFE'S BITS.  The six above are a compact local vocabulary
// with the same NAMES as cbase.h's and different VALUES: HL's DMG_BURN is 8 and
// ours is DMG_SONIC, HL's DMG_FREEZE is 16 and ours is DMG_CRUSH.  Both of those
// collisions sit inside DMG_GIB_CORPSE, so a map's damagetype assigned straight
// into sv_dmg_bits would gib corpses in every gas trap on the map.  Anything
// carrying HL's numbering must be TRANSLATED — see TriggerHurt_Translate in
// server/sv_trigger_hurt.qc, which is currently the only source of them.

// The DMGHUD_* enum this pairs with is in sh_weapons.qc, beside the wire event
// that carries it — this block is inside #ifdef SSQC and the client needs them.
//
// Read-and-cleared by W_ApplyDamage exactly as sv_dmg_bits is, and for the same
// reason: 58 call sites, almost none of which care.
float sv_dmg_hudtype;

// Damage this monster has landed on a PLAYER, cumulative.  Declared here rather
// than with the other .ai_* fields because W_ApplyDamage writes it and compiles
// long before the AI layer.  It is the one number that separates "this monster
// never attacks" from "this monster attacks and the damage goes nowhere" — which
// were both true at once, of different monsters, in the same playtest.
.float ai_dbg_dmgdealt;

// HL's pev->deadflag values (cbase.h).  .deadflag is a STOCK engine field
// (sv_defs.qc:345), so unlike .ai_state it is readable from sv_weapons.qc, which
// compiles long before the AI layer — that is what lets the damage path tell a
// corpse from a living monster at all.
const float DEAD_NO           = 0;
const float DEAD_DYING        = 1;
const float DEAD_DEAD         = 2;
const float DEAD_RESPAWNABLE  = 3;

// Forward declarations — defined in sv_weapons.qc (compiled later)
float(entity target) W_CanDamageTarget;
float(entity attacker, entity target, float damage) W_ApplyDamage;
void(vector pos) W_ImpactEffect;
void(vector pos, vector normal) W_ImpactEffectAll;
void(vector pos, vector normal, float mat) W_ImpactEffectAllMat;
float(entity hit) W_ClassifyImpactMaterial;
// W_BoneToHitgroup + W_HitgroupDamageMultiplier moved to sh_weapon_logic.qc
// (shared, compiled before this file) so CSQC can call them too. Real
// definitions visible from earlier in compile order — no forward decl
// needed here.
float(vector shot_dir, float damage) PhysProp_TryPushFromTrace;
// Radius variant — used by explosive weapons to wake + shove nearby
// physics drops/props. Defined in sv_physprop.qc.
void(vector center, float radius, float peak_damage) PhysProp_TryRadiusPush;
void(entity target) W_SendServerHitboxes;
// Hitbox expansion bookends:
//   SSQC: server/sv_weapons.qc walks the live player chain.
//   CSQC: shared/sh_weapons.qc walks the player_visual_proxy chain.
// Defined earlier in cl_progs.src than sh_weapon_logic.qc so its
// inline traces can reach the helpers without a forward decl here.

// Phys-drop trace helpers — declared in server/sv_weapons.qc.  Wrap
// the trace so the engine sees an inflated AABB on every phys-drop for
// the duration of the call, then restores the tight ODE shape.
void() W_PhysDropsExpandTraceBboxes;
void() W_PhysDropsRestoreTraceBboxes;

// ---------------------------------------------------------------------------
//  Corpse trace opt-in
// ---------------------------------------------------------------------------
// AI_Died leaves a body at SOLID_CORPSE so it stops blocking movement and stops
// disagreeing with client prediction (sv_ai_core.qc).  The engine's price is that
// a SOLID_SLIDEBOX tracer — which every player is — gets a default hit mask with
// NO corpse bit (engine world.c:2841-2856, "slidebox passes through corpses").
// Without opting back in, every bullet and every crowbar swing would sail through
// a body and W_DeadTakeDamage would never run.  The engine's own constant docs
// name this exact recipe (pr_cmds.c:13560).
//
// Both weapon trace chokepoints call this, and there are two of them because
// melee and hitscan took different routes long before corpses were damageable:
// melee goes through W_WeaponTraceLine (sv_weapons.qc), hitscan through
// W_ServerTraceLineWithPhysDrops below.  Missing either one is a silent
// half-fix, so the pair lives here rather than being written out twice.
//
// A zero mask means "engine default" and therefore cannot simply be OR'd — the
// default has to be spelled out.  Same idiom as CSQC_WeaponTraceLine
// (sh_weapon_logic.qc:731-738).
int(entity e) W_CorpseMaskBegin =
{
    int saved = e.hitcontentsmaski;
    if (saved == 0i)
        e.hitcontentsmaski = CONTENTBITS_POINTSOLID | CONTENTBIT_CORPSE;
    else
        e.hitcontentsmaski = saved | CONTENTBIT_CORPSE;
    return saved;
};

void(entity e, int saved) W_CorpseMaskEnd =
{
    e.hitcontentsmaski = saved;
};

void(vector src, vector end, float moveflags, entity ignore) W_ServerTraceLineWithPhysDrops =
{
    float saved_dim_hit = self.dimension_hit;
    self.dimension_hit = saved_dim_hit | PHYSDROP_DIM;
    int saved_mask = W_CorpseMaskBegin(self);
    // Inflate every phys-drop's traceline AABB to a rotation-safe size
    // so the engine broadphase reaches the rotated mesh; ODE's collision
    // shape stays tight because we restore before the next physics step.
    W_PhysDropsExpandTraceBboxes();
    traceline(src, end, moveflags, ignore);
    W_PhysDropsRestoreTraceBboxes();
    W_CorpseMaskEnd(self, saved_mask);
    self.dimension_hit = saved_dim_hit;
};

// One-stop radius explosion: linear-falloff radius damage, player
// knockback (+lift), and wake/shove on every nearby physics drop or
// prop.  Replaces the boilerplate findradius loop that every explosive
// weapon was duplicating — drop in a single call from any weapon's
// detonation handler and it picks up phys-drop blasts for free.
//
// The te_explosion / CSQC_EVENT_GRENADE_EXPLODE / dimension_send
// shooter-exclude filtering stays per-weapon (call this AFTER the
// visual effect dispatch) since each weapon has its own convention.
void(vector center, float radius,
     float peak_damage, float min_damage,
     float push_force, float push_uplift,
     entity attacker) W_RadiusExplode =
{
    // Diagnostic — most "grenades deal 0 damage" bug reports trace to
    // the FF gate in W_ApplyDamage swallowing teammate hits while
    // mp_friendlyfire is off.  One line in the trust_clienthits debug
    // channel makes the cause obvious without per-weapon prints.
    if (cvar("sv_debug_hitclaim"))
        dprint(sprintf("[radexp] center=%v r=%g peak=%g atk=%s ff=%g\n",
            center, radius, peak_damage,
            (attacker && attacker.classname == "player") ? attacker.netname
                                                         : attacker.classname,
            cvar("mp_friendlyfire")));

    entity e = findradius(center, radius);
    while (e)
    {
        // LATCH THE LINK BEFORE ANYTHING REENTRANT RUNS.
        //
        // .chain is ONE shared temporary field, rebuilt in place by every
        // findradius / findchain in the progs.  W_ApplyDamage below is an
        // arbitrarily deep call — it reaches monster pain handlers, breakable
        // chain reactions, trigger fires and, through a killed player, the
        // whole death path — and any findradius reached from there rewrites
        // .chain out from under this walk.  Reading e.chain after the damage
        // (which is what this loop used to do) therefore truncated the blast
        // at the first victim whose damage happened to run another radius
        // query, or diverted it onto that query's list.  Players sort LAST in
        // a findradius chain here, so the entity most likely to be skipped is
        // the one the blast was aimed at.
        entity nxt = e.chain;

        float dist = vlen(e.origin - center);
        float push_scale = max(0, 1 - dist / radius);

        // Apply push BEFORE damage so the velocity bump is on the
        // entity at the moment W_ApplyDamage potentially kills them
        // and Player_VisualProxy_DetachAsCorpse snapshots their
        // velocity into the corpse.  The previous order (damage then
        // push, gated on health > 0) silently dropped the knockback
        // for any blast that killed the player — corpses from
        // grenade kills landed exactly where the live player stood
        // instead of being thrown by the explosion.
        if (e.classname == "player" && push_scale > 0
            && (push_force != 0 || push_uplift != 0))
        {
            // Center-of-explosion at exact e.origin (dist == 0) → no
            // direction; pick straight up.  Same edge-case the per-
            // weapon code already handled implicitly via normalize on
            // a near-zero vector (which FTE's normalize returns 0 for).
            vector push_dir;
            if (dist > 0.0001)
                push_dir = normalize(e.origin - center);
            else
                push_dir = '0 0 1';
            e.velocity   += push_dir * push_force * push_scale;
            e.velocity_z += push_uplift * push_scale;
        }

        if (W_CanDamageTarget(e))
        {
            float dmg = W_LinearDamageFalloff(dist, peak_damage, min_damage, radius);
            sv_dmg_bits = DMG_BLAST;
            W_ApplyDamage(attacker, e, dmg);
        }

        e = nxt;
    }

    // Brushmodel scan — findradius uses entity.origin which is (0,0,0)
    // for func_breakable / func_door / func_button (the actual brush
    // geometry lives in absmin/absmax, not at origin).  So the loop
    // above silently misses every breakable in the map and grenades /
    // GL / Gauss / RPG never destroyed them.  Walk the entity list
    // by classname and use the brushmodel's bbox center + the minimum
    // distance from `center` to the brush AABB so an explosion right
    // next to a breakable wall actually peaks the damage.
    //
    // sv_in_radius_explosion tells W_ApplyDamage to bypass the
    // sv_trust_clientbreak deferral — clients never predict
    // explosions, so deferring would silently drop the hit.
    sv_in_radius_explosion = TRUE;
    // Spawnflag 4 == BREAKABLE_ONLY_EXPLOSION (defined in sv_breakable.qc
    // which is compiled later in sv_progs.src — inlined here so the
    // explosion path can recognise the flag).
    float SF_ONLY_EXPLOSION = 4;
    entity b = nextent(world);
    while (b)
    {
        // takedamage == DAMAGE_YES is the normal "shootable" gate;
        // BREAKABLE_ONLY_EXPLOSION brushes are spawned with
        // takedamage = DAMAGE_NO (so hitscan can't touch them) but
        // explicitly want to be damageable BY explosions — accept
        // them here regardless of the flag setting.
        if (Brush_IsBreakableClass(b)
            && (b.takedamage == DAMAGE_YES
                || (b.spawnflags & SF_ONLY_EXPLOSION)))
        {
            // Closest-point distance: clamp `center` into the brush
            // AABB component-by-component, then measure to the clamp
            // result.  Returns 0 if center is inside the bbox.
            vector clamped;
            clamped_x = bound(b.absmin_x, center_x, b.absmax_x);
            clamped_y = bound(b.absmin_y, center_y, b.absmax_y);
            clamped_z = bound(b.absmin_z, center_z, b.absmax_z);
            float bdist = vlen(center - clamped);
            if (bdist < radius)
            {
                float bdmg = W_LinearDamageFalloff(bdist, peak_damage,
                                                   min_damage, radius);
                sv_dmg_bits = DMG_BLAST;
                W_ApplyDamage(attacker, b, bdmg);
            }
        }
        b = nextent(b);
    }
    sv_in_radius_explosion = FALSE;

    // Wake + shove every nearby physics drop / prop in one pass.
    // Internal cvar gate (sv_physprop_explosion_force) so admins can
    // tune blast force without touching individual weapons.
    PhysProp_TryRadiusPush(center, radius, peak_damage);
};

// Returns TRUE when the server should DEFER player-damage to the attacker's
// incoming hitclaim. Conditions: sv_trust_clienthits >= 1 (admin opted in)
// AND the attacker's userinfo says cl_predict_hits is on (so a claim is
// actually expected). Lets us skip the server's own lag-comped player-damage
// path, which would otherwise race the claim and silently drop the claim's
// visually-accurate hit via the dedup gate. World/breakable/prop damage
// still applies server-side as today — only the player branch is gated.
float(entity attacker) W_ShouldDeferToClaim =
{
    if (cvar("sv_trust_clienthits") < 1) return 0;
    if (!attacker || attacker.classname != "player") return 0;
#ifdef SSQC
    // Bots have no client to send a `cmd cs` hitclaim, so deferring would drop
    // their damage entirely.  Always apply a bot's player-damage server-side.
    if (attacker.is_bot) return 0;
#endif
    // Default cl_predict_hits to ON when the userinfo key is missing
    // (legacy clients that haven't pushed it yet).
    string s = infokey(attacker, "cl_predict_hits");
    if (s == "") return 1;
    return stof(s) != 0;
};

// Mirror of W_ShouldDeferToClaim but for func_breakable targets.  When
// ON, the server skips its own W_ApplyDamage call on breakables and
// trusts the client's `cmd breakclaim` to deliver the damage value.
// Same cl_predict_hits userinfo gate so a player who opts out of
// prediction still gets server-auth breakables.
float(entity attacker) W_ShouldDeferBreakToClaim =
{
    if (cvar("sv_trust_clientbreak") < 1) return 0;
    if (!attacker || attacker.classname != "player") return 0;
    string s = infokey(attacker, "cl_predict_hits");
    if (s == "") return 1;
    return stof(s) != 0;
};

// Send debug impact marker to the shooter only.
// Includes the shooter's eye position, damage, and hitgroup.
void(vector hit_pos, float damage, float hitgroup) W_DebugImpact =
{
#ifdef SSQC
    // When trust_clienthits is active and the bullet just landed on a
    // player, the shooter's CSQC already drew a yellow client-side
    // marker with the predicted damage (see sh_weapon_logic.qc's
    // CSQC_PredictedImpact).  Sending the server's red marker on
    // top would double-report and could conflict with the client's
    // own number — suppress for that case.  Non-player hits and the
    // no-trust path still get the server-auth marker.  Best-effort
    // check: read trace_ent.classname directly; W_DebugImpact is
    // always called right after a trace so the global hasn't been
    // overwritten yet.
    if (cvar("sv_trust_clienthits") >= 1
        && trace_ent && trace_ent.classname == "player")
        return;

    // Dropped / map weapons replicate as oversized AABBs around the
    // mesh; the server's bullet trace registers a hit on those
    // bboxes (SOLID_TRIGGER / SOLID_BBOX for pickup detection) even
    // when the bullet visually flies clear of the gun.  Sending a
    // debug marker on those would spam the user's screen with red
    // dots floating next to every weapon on the ground.  Identify
    // them by having a .weapon set without being a player.
    if (trace_ent && trace_ent.weapon != 0 && trace_ent.classname != "player")
        return;
#endif
    float saved_dim = dimension_send;
    vector eye = self.origin + self.view_ofs;
    dimension_send = self.dimension_seen;
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_DEBUG_IMPACT);
    WriteCoord(MSG_MULTICAST, hit_pos_x);
    WriteCoord(MSG_MULTICAST, hit_pos_y);
    WriteCoord(MSG_MULTICAST, hit_pos_z);
    WriteCoord(MSG_MULTICAST, eye_x);
    WriteCoord(MSG_MULTICAST, eye_y);
    WriteCoord(MSG_MULTICAST, eye_z);
    WriteByte(MSG_MULTICAST, bound(0, floor(damage), 255));
    WriteByte(MSG_MULTICAST, hitgroup);
    multicast(hit_pos, MULTICAST_PVS);
    dimension_send = saved_dim;
};

// Generic lag-compensated hitscan with spread and linear damage falloff.
void(float base_spread, float move_spread, float full_spread_speed,
     float close_dmg, float min_dmg, float falloff_range) W_StandardHitscanShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    flat_vel   = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = base_spread + (move_speed / full_spread_speed) * move_spread;
    spread = min(spread, base_spread + move_spread);
    spread = spread * SH_GetSpreadScale() + sh_spread_flat;

    if (spread > 0)
    {
        float seed = SH_SpreadSeed();
        sx  = SH_SpreadJitter(seed, 0) * spread;
        sy  = SH_SpreadJitter(seed, 1) * spread;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
    }
    else
        dir = v_forward;
    end = src + dir * 8192;

    // Expand all players' bbox so MOVE_HITMODEL can reach outstretched limbs.
    W_PlayersExpandHitboxes();

#ifdef SSQC
    // Open a rewound window around the trace so trace + debug emit
    // both observe the historical positions.  MOVE_LAGGED is gone:
    // the engine path only forward-extrapolates, which leaves
    // ping/2 + cl_interp_time of motion uncorrected at high ping.
    // Lagcomp_BeginRewind handles origin AND animation pose; the
    // trace runs against the position the shooter actually saw.
    Lagcomp_BeginRewind(self);
    W_ServerTraceLineWithPhysDrops(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
#else
    traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
#endif

    W_PlayersRestoreHitboxes();

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        // Apply hitgroup damage multiplier.  W_HitgroupClassify falls
        // back to a Z-height bin when the bone-name lookup whiffs, so
        // headshots register on any rig regardless of bone naming
        // convention (legacy MDL or new IQM with renamed bones).
        float hitgroup = W_HitgroupClassify(trace_ent, trace_endpos, trace_bone_id);
        // Prop Hunt: a disguised hider is a PROP — no head to headshot.  Flatten
        // the multiplier BEFORE it's applied (shared code, so trust-0 server
        // damage AND trust-1 client claim damage stay identical; the CSQC proxy
        // carries the same ph_disguise_modelindex via the IDENTITY section).
        if (trace_ent.ph_disguise_modelindex)
            hitgroup = HITGROUP_GENERIC;
        damage = damage * W_HitgroupDamageMultiplier(hitgroup);

        if (W_CanDamageTarget(trace_ent))
        {
            // Per-shot debug overlay (sv_debug_hitboxes 1): emit the rewound
            // hitbox snapshot for ANY player hit, regardless of trust mode.  The
            // !defer_player damage block below is SKIPPED when sv_trust_clienthits 1
            // defers the hit to the client's claim, so the send must sit OUTSIDE it
            // or mode-1 never spawns in trust-1.  Players are still rewound here
            // (Lagcomp_EndRewind is at function end), so it matches where the trace
            // actually hit.  Self-gates on the cvar + player classname.  SSQC-only:
            // it's a server multicast (undefined on CSQC).
#ifdef SSQC
            W_SendServerHitboxes(trace_ent);
#endif

            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            // Breakable defer is handled INSIDE W_ApplyDamage (single
            // gate covers all weapon paths — shotgun pellets, melee,
            // projectiles); we don't need to early-out here, just call
            // through and let the gate skip the damage application
            // itself while keeping the impact effect / hitbox debug.
            if (!defer_player)
            {
                trace_ent.death_hitgroup = hitgroup;
                W_ApplyDamage(self, trace_ent, damage);
            }
            // Players: every hit uses the spark-splash lethal variant
            // (the cool "head-pop" look the team liked on headshot kills,
            // promoted to apply on all body shots too).
            // Breakables: auto-classify by material; if a flesh-style
            // breakable just took its killing blow, upgrade to the lethal
            // variant so it sparks like a player kill.
            if (trace_ent.classname == "player")
            {
                W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
            }
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
            // (Prop Hunt missfire lives INSIDE PhysProp_TryPushFromTrace — the one
            // chokepoint every weapon's prop-hit branch calls, custom shotgun loops
            // and melee included.)
            PhysProp_TryPushFromTrace(dir, damage);
#ifdef SSQC
            // corpses are pass-through (RAGDOLL_DIM), so the shot reached trace_endpos through
            // any corpse in the way — shove it (Ragdoll_TryShove saves/restores the trace globals).
            Ragdoll_TryShove(src, trace_endpos, dir, damage);
#endif
            W_ImpactEffect(trace_endpos);
        }

        W_DebugImpact(trace_endpos, damage, hitgroup);
    }

#ifdef SSQC
    Lagcomp_EndRewind();
#endif
};

// Lag-compensated hitscan with spread, linear falloff, AND wall penetration.
// pen_power = max wall thickness the bullet can pierce (0 = no penetration).
// pen_dmg_mult = damage retained per unit of wall thickness (exponential decay).
// kick_pitch / kick_variance feed sv_gunkick: the per-shot impulse is
// applied first, then the trace direction uses v_angle + the resulting
// integrated kick offset, so bullets land where the kicked crosshair
// is currently aiming (not where the input angle is pointing).
void(float base_spread, float move_spread, float full_spread_speed,
     float close_dmg, float min_dmg, float falloff_range,
     float pen_power, float pen_dmg_mult,
     float kick_pitch, float kick_variance,
     float kick_strength) W_PenetratingHitscanShoot =
{
    vector src, dir, end, flat_vel;
    float spread, sx, sy, move_speed, dist, damage;
    float pen_remaining, wall_thick;
    vector entry_pos, nudge_pos, exit_pos;
    float pen_count;

    // Reset the per-shot decal counter so cl_bulletholes_per_shot is
    // applied to THIS shot only — penetration may spawn entry + exit
    // decals across multiple targets, but the cap is per-shot.
    // CSQC-only; SSQC stub is a no-op.
#ifdef CSQC
    CSQC_BulletHoles_ResetShot();
    CSQC_Impact_ResetShot();
#endif

    // Apply the per-shot kick impulse FIRST so the makevectors call
    // below sees the kick this shot is contributing. Restore v_angle
    // afterward — the kick is tracked separately in view_kick_*; the
    // player's underlying input angle must stay unmutated so the
    // engine reports the same camera direction the user is pointing.
    SH_ApplyViewKick(kick_pitch, kick_variance, kick_strength);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    flat_vel   = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = base_spread + (move_speed / full_spread_speed) * move_spread;
    spread = min(spread, base_spread + move_spread);
    spread = spread * SH_GetSpreadScale() + sh_spread_flat;

    if (spread > 0)
    {
        float seed = SH_SpreadSeed();
        sx  = SH_SpreadJitter(seed, 0) * spread;
        sy  = SH_SpreadJitter(seed, 1) * spread;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
    }
    else
        dir = v_forward;
    end = src + dir * 8192;

    pen_remaining = pen_power;
    pen_count = 0;

    // Expand player bboxes for MOVE_HITMODEL reach on outstretched limbs.
    // Only needed for the initial hitmodel trace; penetration re-traces use
    // MOVE_NORMAL (static BSP only) so we restore immediately after.
    W_PlayersExpandHitboxes();

    // First trace uses lag compensation + hitmodel; subsequent traces
    // (after wall penetration) use MOVE_NORMAL but stay inside the
    // rewound window so a bullet that punches a wall and hits a
    // SECOND rewound player still registers correctly.
#ifdef SSQC
    Lagcomp_BeginRewind(self);
    W_ServerTraceLineWithPhysDrops(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
#else
    traceline(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
#endif

    W_PlayersRestoreHitboxes();

    while (trace_fraction < 1.0 && pen_count < 4)
    {
        dist = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, close_dmg, min_dmg, falloff_range);

        // Apply hitgroup damage multiplier.  W_HitgroupClassify falls
        // back to a Z-height bin when the bone-name lookup whiffs, so
        // headshots register on any rig regardless of bone naming
        // convention (legacy MDL or new IQM with renamed bones).
        float hitgroup = W_HitgroupClassify(trace_ent, trace_endpos, trace_bone_id);
        // Prop Hunt: no headshot multiplier on a disguised hider (see W_HitscanShoot).
        if (trace_ent.ph_disguise_modelindex)
            hitgroup = HITGROUP_GENERIC;
        damage = damage * W_HitgroupDamageMultiplier(hitgroup);

        if (W_CanDamageTarget(trace_ent))
        {
            // Per-shot debug overlay: emit regardless of trust mode (see
            // W_HitscanShoot) — the !defer_player block is skipped in trust-1.
#ifdef SSQC
            W_SendServerHitboxes(trace_ent);
#endif

            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            // Breakable defer is centralized inside W_ApplyDamage.
            if (!defer_player)
            {
                trace_ent.death_hitgroup = hitgroup;
                W_ApplyDamage(self, trace_ent, damage);
            }
            // Players: every hit uses the spark-splash lethal variant.
            // Breakables: auto-classify; flesh breakables get the lethal
            // upgrade on their killing blow. Shooter is excluded from the
            // multicast — CSQC_PredictedPenetratingImpact handles every
            // entry/exit decal locally, including post-pen hits.
            if (trace_ent.classname == "player")
            {
                W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
            }
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
            // (Prop Hunt missfire lives inside PhysProp_TryPushFromTrace.)
            PhysProp_TryPushFromTrace(dir, damage);
#ifdef SSQC
            Ragdoll_TryShove(src, trace_endpos, dir, damage);   // shove a pass-through corpse in the shot's path
#endif
            W_ImpactEffect(trace_endpos);
        }

        W_DebugImpact(trace_endpos, damage, hitgroup);

        // --- Penetration logic ---
        if (pen_remaining <= 0)
            break;

        // Only penetrate world geometry and func_ entities (not players)
        if (trace_ent != world && W_CanDamageTarget(trace_ent))
            break;

        // Capture before the back-trace below overwrites trace_ent so
        // the exit decal multicast can be skipped when the bullet
        // pierced a phys prop (barrel/can).  The prop tips/rolls under
        // ODE, so an exit decal pinned to world space would slide off.
        // CSQC_PredictedPenetratingImpact mirrors this skip locally.
        float entry_was_physprop =
            (trace_ent.classname == "phys_barrel" ||
             trace_ent.classname == "phys_can" ||
             (trace_ent.weapon && (trace_ent.movetype == MOVETYPE_PHYSICS || trace_ent.weapon_physdrop_sleeping)));

        entry_pos = trace_endpos;

        // Find the exit point: trace backwards from max-depth to entry.
        nudge_pos = entry_pos + dir * pen_remaining;
        traceline(nudge_pos, entry_pos, MOVE_NORMAL, self);

        if (trace_fraction >= 1.0)
            break;  // no back face found (open sky or void)

        exit_pos = trace_endpos;
        // Save the actual wall surface normal for the exit decal
        vector exit_normal = trace_plane_normal;
        wall_thick = vlen(exit_pos - entry_pos);

        if (wall_thick < 1)
            wall_thick = 1;  // minimum 1 unit

        if (wall_thick > pen_remaining)
            break;  // wall too thick

        // Reduce penetration budget and damage
        pen_remaining -= wall_thick;
        close_dmg *= pow(pen_dmg_mult, wall_thick);
        min_dmg   *= pow(pen_dmg_mult, wall_thick);

        if (close_dmg < 1)
            break;  // bullet spent

        // Exit impact — uses the ACTUAL wall normal from the reverse trace,
        // not the bullet direction, so the decal sits flat on the surface.
        // Shooter is excluded — CSQC_PredictedPenetratingImpact predicts
        // the same reverse trace and renders the exit decal locally.
        if (!entry_was_physprop)
            W_ImpactEffectAll(exit_pos, exit_normal);

        // Continue from exit point
        src = exit_pos + dir * 1;
        pen_count++;
#ifdef SSQC
        W_ServerTraceLineWithPhysDrops(src, end, MOVE_NORMAL, self);
#else
        traceline(src, end, MOVE_NORMAL, self);
#endif
    }

#ifdef SSQC
    Lagcomp_EndRewind();
#endif
};

// World-entity setup for GoldSrc-format MDLs.  Their pivot sits on a
// hand/grip bone, not the geometric center — setmodel + setsize alone
// puts the dropped/pickup weapon visibly off the surface it should
// land on.  This helper compensates: setmodel, compute the model's
// natural center, then origin and size relative to that center so the
// visible mesh sits at the desired drop point.
//
// Same pattern that knife / csusp / butterfly inline today.
//
// `self` is the entity being set up (a dropped pickup or a map-spawned
// world weapon).  `self.origin` is read as the desired drop point and
// rewritten to compensate.  hull_mins / hull_maxs are the touch trigger
// bounds the weapon should expose AFTER the pivot shift.
void(string worldmodel, vector hull_mins, vector hull_maxs) SH_GoldSrcSetupWorld =
{
    vector desired = self.origin;
    setmodel(self, worldmodel);

    vector mdl_center = (self.mins + self.maxs) * 0.5;

    setorigin(self, desired - mdl_center);
    setsize(self, hull_mins + mdl_center, hull_maxs + mdl_center);
};

// Common equip setup — sets draw state, model, and timing.
// Call this first in each weapon's Equip function, then set
// the weapon-specific function pointers and crosshair profile.
void(string viewmodel, string wep_name, float draw_start,
     float frame_interval, float attack_anim) W_StandardEquipSetup =
{
    self.weaponmodel             = viewmodel;
    self.weapon_name             = wep_name;
    self.weapon_draw_start_frame = draw_start;
    self.weapon_player_attack_anim = attack_anim;
    self.weaponstate             = WS_DRAW;
    self.wep_action_id          += 1;
    self.wep_anim_start          = time;
    self.weaponframe             = draw_start;
    self.wep_nextframe           = time + frame_interval;

    // Clear optional function pointers — weapon sets the ones it uses
    self.altfire    = __NULL__;
    self.altrelease = __NULL__;
    self.shoot      = __NULL__;
    self.special    = __NULL__;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — display frame helper
// ============================================================

#ifdef CSQC

// Generic display frame for standard draw/fire/reload weapons.
// Pass reload_start == reload_end to skip the reload branch.
float(float elapsed, float frame_interval,
      float draw_start, float draw_end,
      float fire_start, float fire_end,
      float reload_start, float reload_end,
      float idle_frame) CSQC_StandardDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = draw_start + elapsed / frame_interval;
        return bound(draw_start, frame, draw_end - 1);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        frame = fire_start + elapsed / frame_interval;
        return bound(fire_start, frame, fire_end - 1);
    }
    if (reload_start != reload_end && predicted_player.weaponstate == WS_RELOAD)
    {
        frame = reload_start + elapsed / frame_interval;
        return bound(reload_start, frame, reload_end - 1);
    }
    return idle_frame;
};

#endif // CSQC
