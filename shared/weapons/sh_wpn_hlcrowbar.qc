// ============================================================
//  shared/weapons/sh_wpn_hlcrowbar.qc  -  HL Crowbar (melee)
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo, melee swing with cycling hit/miss anims
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Sequence indices, read out of valve/models/v_crowbar.mdl (11 seqs) ---
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/
// wpn_hlcrowbar/v_crowbar.mdl, a flat frame bake whose idle alone spanned
// frames 106..192) by frame number.  It now drives Half-Life's own IDST
// model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index —
// gl_hlmdl.c:780 sets mod->numframes = numseq — so every one of the old
// constants was meaningless against it: CROWBAR_IDLE_START was 106 and this
// model has eleven sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// CAREFUL with the names.  The SDK enum (crowbar.cpp:33-43) and the model's
// own $sequence labels disagree for attack2/attack3 — the enum is the truth
// about MEANING, the label is just what the animator typed:
//     idx  model label   SDK enum name
//      3   attack1       CROWBAR_ATTACK1HIT
//      4   attack1miss   CROWBAR_ATTACK1MISS
//      5   attack2       CROWBAR_ATTACK2MISS   <- "attack2" is the MISS
//      6   attack2hit    CROWBAR_ATTACK2HIT
//      7   attack3       CROWBAR_ATTACK3MISS   <- "attack3" is the MISS
//      8   attack3hit    CROWBAR_ATTACK3HIT
// The constants are named after the SDK enum so the crowbar.cpp citations
// below read straight across.
//
// The quoted lengths are what the ENGINE reports, i.e. (numframes-1)/fps —
// gl_hlmdl.c:1542 `*duration = (sequence->numframes-1)/sequence->timing;` —
// because an N-frame animation spans N-1 intervals.  The SDK hardcodes the
// same convention (python.cpp:254 writes (70.0/30.0) for a 71-frame 30 fps
// sequence).  They were first written down as numframes/fps, one frame period
// too long across the board, which put every constant here at odds with what
// SH_SeqDuration()/frameduration() hands the code that asks the model.
// Only sequences 9 and 10 carry the LOOP flag.
const float CROWBAR_SEQ_IDLE1         = 0;   // idle1,       2.692 s  (NOT looping)
const float CROWBAR_SEQ_DRAW          = 1;   // draw,        0.500 s  (crowbar.cpp:91)
const float CROWBAR_SEQ_HOLSTER       = 2;   // holster,     0.500 s  (crowbar.cpp:97 — no holster state exists here yet)
const float CROWBAR_SEQ_ATTACK1HIT    = 3;   // attack1,     0.455 s  (never reached — see SH_CrowbarPickSwingSeq)
const float CROWBAR_SEQ_ATTACK1MISS   = 4;   // attack1miss, 0.455 s
const float CROWBAR_SEQ_ATTACK2MISS   = 5;   // attack2,     0.591 s
const float CROWBAR_SEQ_ATTACK2HIT    = 6;   // attack2hit,  0.591 s
const float CROWBAR_SEQ_ATTACK3MISS   = 7;   // attack3,     0.750 s
const float CROWBAR_SEQ_ATTACK3HIT    = 8;   // attack3hit,  0.750 s
const float CROWBAR_SEQ_IDLE2         = 9;   // idle2,       5.333 s, LOOPING  <- the resting idle
const float CROWBAR_SEQ_IDLE3         = 10;  // idle3,       5.333 s, LOOPING

const float CROWBAR_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate
// crowbar.cpp:209 — a swing that MISSES refires in 0.5 s.
const float CROWBAR_FIRE_DELAY        = 0.5;
// crowbar.cpp:312 — a swing that CONNECTS refires in 0.25 s.  This weapon used a
// flat 0.5 for both, i.e. a connecting crowbar ran at exactly HALF of
// Half-Life's cadence: 2 hits/sec where HL does 4.  That is the reported "I
// believe it's supposed to be quicker", and it is the whole of it.
//
// Note where this line sits in the SDK: OUTSIDE the `#ifndef CLIENT_DLL` that
// wraps crowbar.cpp:230-311, so Half-Life predicts the shortened cadence on the
// client too.  That is why it has to be shared here rather than server-only.
const float CROWBAR_HIT_DELAY         = 0.25;
// crowbar.cpp:240 — the `+ 1.0f` in the charge test.  Measured from the PREVIOUS
// swing's cooldown expiry, not from the swing, so the real recharge is 1.25 s
// after a landed hit and 1.5 s after a whiff.
const float CROWBAR_RECHARGE_TIME     = 1.0;
// crowbar.cpp:248 — `gSkillData.plrDmgCrowbar / 2`.
const float CROWBAR_HALF_SCALE        = 0.5;

// --- Balance ---
const float CROWBAR_DAMAGE            = 25;
const float CROWBAR_RANGE             = 72;

// --- State durations, taken from the sequences themselves ---
const float CROWBAR_DRAW_DURATION     = 0.500;  // draw
// FALLBACK ONLY.  The five reachable swings are three different lengths
// (attack1* 0.455, attack2* 0.591, attack3* 0.750) and SH_CrowbarSwingDuration
// asks the model for whichever one is actually playing; this value is used
// only when no swing could be attributed to the FIRE state.  It is the LONGEST
// swing, so an unattributed swing is over-held rather than cut off.
const float CROWBAR_FIRE_MAX_DURATION = 0.750;

// The mounted Half-Life originals (crowbar.cpp:59-61).  Lowercase basenames
// are the on-disk spelling and FTE's VFS is case-sensitive against real
// files on Linux.
const string CROWBAR_VIEWMODEL    = "models/v_crowbar.mdl";
const string CROWBAR_WORLDMODEL   = "models/w_crowbar.mdl";
const string CROWBAR_DEPLOY_SOUND = "";
const string CROWBAR_DISPLAY_NAME = "CROWBAR";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// How long the FIRE state lasts, for the swing that is actually playing.
// A single worst-case duration for all five reachable swings left the short
// ones frozen on their last pose: FTE clamps a non-looping sequence to its
// final frame (gl_hlmdl.c:1076-1082) while cl_weapons.qc:1697 keeps feeding
// frame1time, so an attack1miss finished animating at 0.455 s and then stood
// still for the remaining 0.295 s before WS_FIRE retired.  The pre-migration
// code retired per-variant off its deleted `max_frame` block and had no hold.
//
// Asked of the model rather than hardcoded so this can never drift from what
// the engine plays — SH_SeqDuration (sh_weapon_standard.qc:399) wraps
// frameduration(), which returns (numframes-1)/fps (gl_hlmdl.c:1542).
// This does NOT touch the rate of fire: refire is gated by attack_finished /
// CROWBAR_FIRE_DELAY in SH_CrowbarTryFire, not by the FIRE state.
float(float swing_seq) SH_CrowbarSwingDuration =
{
    // Outside the swing range means no swing was attributed to this FIRE
    // state — it arrived from the server without ever being predicted here,
    // or a reconcile dropped the local pick.  Falling through would ask for
    // sequence 0 and hold the state for idle1's 2.692 s.
    if (swing_seq < CROWBAR_SEQ_ATTACK1HIT || swing_seq > CROWBAR_SEQ_ATTACK3HIT)
        return CROWBAR_FIRE_MAX_DURATION;
    return SH_SeqDuration(CROWBAR_VIEWMODEL, swing_seq, CROWBAR_FIRE_MAX_DURATION);
};

// Which swing sequence plays.  The SDK CYCLES these rather than rolling
// them, so this does too — and cycling off wep_action_id (bumped once per
// swing by SH_CrowbarTryFire, on both sides, and REWOUND to the server's
// value at reconcile — sh_customdefs.qc:454) is what finally makes the
// client and the server agree on the variant.  The pre-migration code rolled
// random() independently in W_CrowbarSwing and in CSQC_PredictCrowbarCommand,
// so the local viewmodel and the server's .weaponframe routinely disagreed.
//
// DELIBERATE DEVIATION, hit branch only.  HL's m_iSwing (crowbar.cpp:217)
// sits inside the `else` of `if ( tr.flFraction >= 1.0 )` at crowbar.cpp:215,
// so ONLY a connecting swing advances it — a miss never touches it and
// Deploy never resets it.  wep_action_id counts every swing and every equip
// (sh_weapon_standard.qc:1161, cl_weapons.qc:67), so hit->miss->hit repeats
// one hit animation where HL would alternate, and switching weapons between
// two hits flips the parity.  Reproducing m_iSwing exactly needs a hit-only
// counter, and the only one this file can keep is private to each side:
// nothing replicates it, so one mispredicted hit/miss verdict would desync it
// permanently instead of for a single swing.  A shared counter that is wrong
// about parity beats a private counter that is wrong forever.  Fixing this
// properly means replicating a hit counter, which is a cross-file change.
// The MISS branch has no such problem — ev_hldm.cpp:1177's g_iSwing really
// does advance on every swing event.
//
// No `%` operator is used anywhere in this codebase; `x - floor(x/n)*n` is
// the established fmod idiom (sh_pmove.qc:2578).
float(float swing_id, float did_hit) SH_CrowbarPickSwingSeq =
{
    float n;

    if (did_hit)
    {
        // crowbar.cpp:217 — `switch( ((m_iSwing++) % 2) + 1 )`.  That
        // expression can only ever be 1 or 2, so `case 0: ATTACK1HIT` is
        // dead code and retail Half-Life alternates ONLY attack2hit and
        // attack3hit on a connecting swing.  The two-way alternation is
        // reproduced, dead case and all — CROWBAR_SEQ_ATTACK1HIT is
        // deliberately never returned — but the counter driving it is not
        // m_iSwing; see the deviation note above.
        n = swing_id - floor(swing_id / 2) * 2;
        if (n == 0)
            return CROWBAR_SEQ_ATTACK2HIT;
        return CROWBAR_SEQ_ATTACK3HIT;
    }

    // A miss sends no weapon anim from the server at all (crowbar.cpp:204-214
    // has no SendWeaponAnim); the client's crowbar event picks it, and that
    // one cycles all three — ev_hldm.cpp:1177, `switch( (g_iSwing++) % 3 )`.
    n = swing_id - floor(swing_id / 3) * 3;
    if (n == 0)
        return CROWBAR_SEQ_ATTACK1MISS;
    if (n == 1)
        return CROWBAR_SEQ_ATTACK2MISS;
    return CROWBAR_SEQ_ATTACK3MISS;
};

// `swing_seq` is the sequence this FIRE state is playing, so the state ends
// when the animation does.  The server passes self.weaponframe; the client
// passes its keyed prediction (CSQC_CrowbarSwingSeqFor).  Anything outside
// the swing range falls back to the longest swing — see
// SH_CrowbarSwingDuration.
float(float now, float swing_seq) SH_CrowbarTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CROWBAR_DRAW_DURATION)
        {
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_CrowbarSwingDuration(swing_seq))
        {
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            return 1;
        }
        return 0;
    }

    return 0;
};

// ---------------------------------------------------------------------------
//  The charged swing — dlls/crowbar.cpp:238-249
//
//      if ( ( m_flNextPrimaryAttack + 1.0f <= UTIL_WeaponTimeBase() )
//           || g_pGameRules->IsMultiplayer() )
//          ...full...  else  ...half...
//
//  TWO things about that line matter here.
//
//  1. The `<=` is a FIX, and it is the "broken and fixed in GoldSrc a few
//     times" this was reported as.  With CLIENT_WEAPONS defined — which retail
//     Half-Life is, both projects — UTIL_WeaponTimeBase() returns 0.0
//     (util.cpp:34-41) and m_flNextPrimaryAttack is a COUNTDOWN floored at -1.0
//     (player.cpp:2808, hl_weapons.cpp:993-995).  So the original strict `<`
//     evaluated `-1.0 + 1.0 < 0.0` -> `0.0 < 0.0` -> false, forever: retail
//     singleplayer Half-Life did HALF damage on every single crowbar swing for
//     years.  JoshA's comment at crowbar.cpp:238-239 records the change.  We
//     store absolute times rather than a countdown so the sign trap cannot
//     exist here, but the `<=` is kept so the citation reads straight across.
//
//  2. `|| g_pGameRules->IsMultiplayer()` short-circuits the entire test.  Sven
//     Co-op IS multiplayer, so the LITERAL SDK behaviour for a Sven-alike is
//     "always full damage, never half".  The charged swing is therefore an
//     explicit opt-in, not a faithful port — sv_crowbar_charged_swing picks
//     which of Half-Life's two real rules runs.
//
//  Sustained DPS is unchanged by all this: 25 every 0.5 s and 12.5 every 0.25 s
//  are both 50/sec.  What changes is the feel — a full-damage opener that snaps
//  in twice as fast, then settles.
// ---------------------------------------------------------------------------
float() SH_CrowbarChargedSwingEnabled =
{
#ifdef CSQC
    // The server owns this rule, but CSQC has to agree with it, because the
    // client's hitclaim is what actually carries PvP damage.  serverkey first,
    // local cvar only as the fallback for a listen server or an unpushed key.
    // Tested as a string, not `<= 0`, because 0 is a meaningful value here.
    string s = serverkey("sv_crowbar_charged_swing");
    if (s != "")
        return stof(s) != 0;
#endif
    return cvar("sv_crowbar_charged_swing") != 0;
};

// Must be read BEFORE SH_CrowbarSettleSwing restamps melee_charge_ref.
float(float now) SH_CrowbarSwingIsFull =
{
    if (!SH_CrowbarChargedSwingEnabled())
        return TRUE;
    if (self.melee_charge_ref <= 0)
        return TRUE;                // nothing has been swung since equip
    return (self.melee_charge_ref + CROWBAR_RECHARGE_TIME) <= now;
};

// Called by BOTH sides once the trace verdict is known.  crowbar.cpp:312
// shortens a connecting swing's refire to 0.25; crowbar.cpp:204-214 leaves the
// 0.5 standing on a miss.  Then stamp the charge reference with the resulting
// cooldown — which is exactly what m_flNextPrimaryAttack holds by the time the
// next swing reaches crowbar.cpp:240.
//
// A MISS costs you the charge, same as HL: crowbar.cpp:209 writes
// m_flNextPrimaryAttack on a whiff too, so flailing at nothing spends the full
// swing.
void(float now, float did_hit) SH_CrowbarSettleSwing =
{
    if (did_hit)
        self.attack_finished = now + CROWBAR_HIT_DELAY;
    self.melee_charge_ref = self.attack_finished;
};

// UNCHANGED by the charged-swing work: this keeps arming the 0.5 s miss delay,
// which is precisely what crowbar.cpp:209 does.  SH_CrowbarSettleSwing shortens
// it afterwards, once the trace verdict exists.
float(float now) SH_CrowbarTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + CROWBAR_FIRE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CrowbarPickupCopy =
{
};

// Set by W_CrowbarSwing so W_CrowbarFire can settle the cooldown afterwards.
// A global rather than a return value because `.shoot` is also wired to
// W_CrowbarSwing (see W_CrowbarEquip) and that field type returns void.
float sv_crowbar_last_swing_hit;

void() W_CrowbarSwing =
{
    vector src, end;
    float  swing_dmg;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * CROWBAR_RANGE;

    // Line first, then Half-Life's head-hull fallback — see W_MeleeTrace.
    // NOTE the verdict is read off trace_fraction, NOT off W_MeleeTrace's
    // return value: that returns "the HULL saved it", i.e. FALSE for a swing
    // the line trace had already hit.
    W_MeleeTrace(src, end);
    sv_crowbar_last_swing_hit = (trace_fraction < 1.0);

    // crowbar.cpp:243 vs :248.  Read BEFORE the settle restamps the charge.
    swing_dmg = SH_CrowbarSwingIsFull(time)
              ? CROWBAR_DAMAGE
              : CROWBAR_DAMAGE * CROWBAR_HALF_SCALE;

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, swing_dmg, W_BoneToHitgroup(trace_bone_id));

        // Hit variant, cycled the way crowbar.cpp:217 cycles it.
        self.weaponframe = SH_CrowbarPickSwingSeq(self.wep_action_id, TRUE);

        // crowbar.cpp: a body gets cbar_hitbod1/2/3, the world gets the texture
        // sound plus cbar_hit1/2.  Three-way pick, HL's own RANDOM_LONG(0,2).
        if (W_MeleeHitIsBody(trace_ent))
        {
            float r = random();
            if (r < 0.333)
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitbody1.wav", 1, ATTN_NORM);
            else if (r < 0.666)
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitbody2.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitbody3.wav", 1, ATTN_NORM);
        }
        else if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitwall1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/hitwall2.wav", 1, ATTN_NORM);

        if (W_CanDamageTarget(trace_ent))
        {
            // BREAKABLE_INSTANT_CROWBAR — see sh_wpn_csknife.qc.
            float deal = swing_dmg;
            if (Brush_IsBreakableClass(trace_ent)
                && (trace_ent.spawnflags & BREAKABLE_INSTANT_CROWBAR))
                deal = 9999;
            // Defer player damage to attacker's client hitclaim so
            // damage isn't applied twice (server-auth + hitclaim).
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            // BRACES MATTER HERE.  Without them the guard covered only the
            // sv_dmg_bits line and W_ApplyDamage ran unconditionally, so a
            // crowbar hit on a player was applied TWICE - once server-auth
            // here and once again from the attacker's client hitclaim.
            if (!defer_player)
            {
                sv_dmg_bits = DMG_CLUB;   // a corpse can be broken apart by hand
                W_ApplyDamage(self, trace_ent, deal);
            }
        }
        else
        {
            // Push force deliberately stays on the FULL constant.  HL has no
            // damage-derived prop shove at all, and having a charged and an
            // uncharged swing move a crate differently would be invention.
            PhysProp_TryPushFromTrace(v_forward, CROWBAR_DAMAGE);
            W_ImpactEffect(trace_endpos);
        }
    }
    else
    {
        // Miss variant, cycled the way ev_hldm.cpp:1177 cycles it.
        self.weaponframe = SH_CrowbarPickSwingSeq(self.wep_action_id, FALSE);

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrowbar/miss.wav", 1, ATTN_NORM);
    }
};

void() W_CrowbarFire =
{
    if (SH_CrowbarTryFire(time))
    {
        // Provisional miss sequence — W_CrowbarSwing overwrites it on the
        // very next line if the trace connects.  Kept because .shoot is also
        // wired to W_CrowbarSwing and could in principle be driven from
        // elsewhere without this pre-set; picking through the same helper
        // means the provisional value is the exact sequence the miss branch
        // would land on, not an arbitrary one.
        self.weaponframe = SH_CrowbarPickSwingSeq(self.wep_action_id, FALSE);
        self.wep_nextframe = time + CROWBAR_FRAME_INTERVAL;
        W_CrowbarSwing();
        // Settle lives HERE, not at the end of W_CrowbarSwing, because
        // `.shoot` also points at W_CrowbarSwing (W_CrowbarEquip) — and settle
        // WRITES attack_finished, so an invocation through `.shoot` that never
        // went through SH_CrowbarTryFire would shorten a cooldown it never
        // armed.
        SH_CrowbarSettleSwing(time, sv_crowbar_last_swing_hit);
    }
};

void() W_CrowbarFrame =
{
    float result;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked straight off the end of an eleven-
    // sequence model.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1696), so this function only has to keep
    // the tick alive and let the state machine decide when the swing is over.
    self.wep_nextframe += CROWBAR_FRAME_INTERVAL;

    // The old per-variant `max_frame` block that used to sit here retired the
    // FIRE state early by comparing weaponframe against the end of whichever
    // frame RANGE was playing.  There are no ranges to compare against any
    // more; the elapsed-time check inside SH_CrowbarTickState does the same
    // job per variant — self.weaponframe IS the swing sequence W_CrowbarFire /
    // W_CrowbarSwing picked — and it does it for both sides, which the frame
    // comparison never could.
    result = SH_CrowbarTickState(time, self.weaponframe);
    if (result & 1)
    {
        // The resting pose has to be a LOOPING sequence.  Once idle,
        // wep_anim_start is 0 and cl_weapons.qc:1695 feeds frame1time =
        // cltime — absolute client time, unbounded — so a non-looping
        // sequence gets clamped to its final frame (gl_hlmdl.c:1076-1082)
        // and the viewmodel is a still image for the rest of the map.
        // CROWBAR_SEQ_IDLE1 used to be set here and is the model's one
        // NON-looping idle; only 9 and 10 carry LOOP.  Half-Life never plays
        // any of the three — CCrowbar has no WeaponIdle override, so retail
        // simply holds the last frame of the draw — so which idle rests here
        // is our call, and it has to be one that loops.
        self.weaponframe = CROWBAR_SEQ_IDLE2;
        // Idle retire — the ONLY place a zero here is legal.  sv_weapons.qc:3820
        // only ticks wepframe while wep_nextframe > 0, so a stray zero anywhere
        // else freezes the weapon permanently.
        self.wep_nextframe = 0;
    }
};

void() W_CrowbarEquip =
{
    // Same field-for-field setup this used to do inline; W_StandardEquipSetup
    // (sh_weapon_standard.qc:1153) sets weaponmodel / weapon_name /
    // weapon_draw_start_frame / weapon_player_attack_anim / WS_DRAW /
    // wep_action_id / wep_anim_start / weaponframe / wep_nextframe and clears
    // altfire, altrelease, shoot and special, which are then re-set below.
    // Third argument is the DRAW SEQUENCE, not a start frame.
    W_StandardEquipSetup(CROWBAR_VIEWMODEL, CROWBAR_DISPLAY_NAME, CROWBAR_SEQ_DRAW,
        CROWBAR_FRAME_INTERVAL, PLAYER_ATTACKANIM_MELEE);
    // A freshly drawn crowbar swings full — attack_finished carries across
    // weapon switches (W_StandardEquipSetup does not clear it), so without this
    // the charge clock would inherit whatever the previous weapon left.
    self.melee_charge_ref = 0;
    self.fire     = W_CrowbarFire;
    self.reload   = __NULL__;
    self.wepframe = W_CrowbarFrame;
    self.shoot    = W_CrowbarSwing;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_CrowbarDrop =
{
    entity tgt = weapon_drop_target;
    setmodel(tgt, CROWBAR_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_hlcrowbar"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_HLCROWBAR; tgt.weapon_slot = SLOT_MELEE;
    tgt.weap_draw = W_CrowbarEquip; tgt.weap_drop_func = W_CrowbarDrop;
    tgt.pickupcopy = W_CrowbarPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_hlcrowbar =
{
    setmodel(self, CROWBAR_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_hlcrowbar"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_HLCROWBAR; self.weapon_slot = SLOT_MELEE;
    self.weap_draw = W_CrowbarEquip; self.weap_drop_func = W_CrowbarDrop;
    self.pickupcopy = W_CrowbarPickupCopy; self.touch = weapon_touch;
    W_RegisterMapWeapon(weapon_hlcrowbar);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Track which animation variant the client predicted
float csqc_crowbar_predicted_hit;       // TRUE if predicted trace hit something
// One sequence index replaces the old start/end frame pair — there is no
// range to interpolate across any more, the engine plays the whole sequence.
float csqc_crowbar_anim_seq;
// ...and the two keys saying WHO and WHICH SWING that value belongs to.
// CSQC_CrowbarDisplayFrame is not only called for us: cl_weapons.qc:1805-1807
// points predicted_player at a scratch entity and calls the same
// csqc_display_frame for a spectated / killcam player.  These globals are
// file-scope, so unkeyed they would dress a remote player's viewmodel with the
// LOCAL player's last predicted swing — permanently, since after one swing the
// value never drops back below CROWBAR_SEQ_ATTACK1HIT again.
entity csqc_crowbar_anim_owner;         // entity the swing was predicted for
float  csqc_crowbar_anim_id;            // its wep_action_id at that moment

// The predicted swing sequence for `e`, or 0 when the globals belong to a
// different entity or a different swing.  0 is not a swing sequence (it is
// CROWBAR_SEQ_IDLE1), so both consumers — SH_CrowbarSwingDuration and the
// display path — fall back cleanly on it, and the pre-first-swing value is
// covered by the same test.
float(entity e) CSQC_CrowbarSwingSeqFor =
{
    if (csqc_crowbar_anim_owner != e)
        return 0;
    if (csqc_crowbar_anim_id != e.wep_action_id)
        return 0;
    return csqc_crowbar_anim_seq;
};

void() CSQC_PredictCrowbarCommand =
{
    // Explicitly zeroed: QC locals are not, and this now feeds
    // SH_CrowbarSettleSwing on every pass including replays, where the
    // `!pm_suppress_sounds` block below never runs.
    float did_hit = 0;

    // Skip fire during replay — no ammo to deplete, would cause infinite re-fires
    // The TRY-FIRE runs on replay passes too — it is state, not audio.  With
    // pm_suppress_sounds on the outer test the replay skipped it, so a reconcile
    // reset to the confirmed state and then never re-entered WS_FIRE, and the
    // swing stopped being predicted at all.
    //
    // Everything INSIDE stays gated, and for a stronger reason than sound:
    // CSQC_PredictedMeleeTrace calls CSQC_SendHitclaim, and re-running it on each
    // replay would send the server a duplicate hitclaim per replayed frame.  The
    // anim bookkeeping below stays with it because it is keyed on wep_action_id,
    // which the replayed try-fire walks back to the same value — so the pick made
    // on the live pass is still the right one.
    if (input_buttons & 1)
    {
        if (SH_CrowbarTryFire(csqc_pred_time))
        {
        // Computed BEFORE the settle below restamps the charge, and outside the
        // sound gate so a replay pass agrees with the live pass.  This number is
        // what CSQC_SendHitclaim carries, and the hitclaim is what actually
        // applies crowbar damage to another PLAYER under the default
        // sv_trust_clienthits 1 — so a server-only half-damage rule would miss
        // PvP entirely.  That is why the rule is shared.
        float claim_dmg = SH_CrowbarSwingIsFull(csqc_pred_time)
                        ? CROWBAR_DAMAGE
                        : CROWBAR_DAMAGE * CROWBAR_HALF_SCALE;

        if (!pm_suppress_sounds)
        {
            CSQC_MarkPendingWeaponAck();
            did_hit = CSQC_PredictedMeleeTraceEx(CROWBAR_RANGE, claim_dmg,
                "sounds/weapons/wpn_hlcrowbar/hitwall1.wav",
                "sounds/weapons/wpn_hlcrowbar/hitwall2.wav",
                "sounds/weapons/wpn_hlcrowbar/miss.wav",
                "sounds/weapons/wpn_hlcrowbar/hitbody1.wav",
                "sounds/weapons/wpn_hlcrowbar/hitbody2.wav",
                "sounds/weapons/wpn_hlcrowbar/hitbody3.wav");
            // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
            // Crowbarring a zombie was silent for the attacker until this.
            CSQC_RecordPredictedMeleeSound();

            csqc_crowbar_predicted_hit = did_hit;
            // Same helper, same counter as W_CrowbarSwing on the server — so
            // for the first time the predicted viewmodel and the server's
            // .weaponframe pick the SAME variant instead of two independent
            // random() rolls.  They still part company when the two traces
            // reach different hit/miss verdicts, and NOTHING reconciles that
            // swing: .weaponframe is declared at sh_customdefs.qc:423 but no
            // file under client/ ever reads it, so the server's pick is not
            // visible here and the mispredicted swing plays out wrong to its
            // end.  What does recover is the NEXT swing — a snapshot rewinds
            // wep_action_id to the server's value (sh_customdefs.qc:454) and
            // CSQC_CrowbarSwingSeqFor's key check then drops the stale pick.
            csqc_crowbar_anim_seq   = SH_CrowbarPickSwingSeq(self.wep_action_id, did_hit);
            // self IS predicted_player here (cl_player.qc:1980), which is the
            // entity CSQC_CrowbarDisplayFrame gets handed for the local view.
            csqc_crowbar_anim_owner = self;
            csqc_crowbar_anim_id    = self.wep_action_id;
        }

            // STATE, so it runs on every pass — live and replay — for the same
            // reason the try-fire itself is outside the sound gate.  On a
            // replay `did_hit` is 0, which settles as a miss and leaves the
            // 0.5 s cooldown standing; that is the conservative direction, and
            // the next live swing restamps it anyway.
            SH_CrowbarSettleSwing(csqc_pred_time, did_hit);
        }
    }
    // Retire on the length of the swing we actually predicted, keyed the same
    // way the display path keys it so a stale pick from an earlier swing can
    // never decide when this one ends.
    SH_CrowbarTickState(csqc_pred_time, CSQC_CrowbarSwingSeqFor(self));
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, so the `elapsed`
// argument is no longer used here — it stays in the signature because
// csqc_display_frame is a shared function pointer type.
float(float elapsed) CSQC_CrowbarDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return CROWBAR_SEQ_DRAW;

    if (predicted_player.weaponstate == WS_FIRE)
    {
        // csqc_crowbar_anim_seq is set at swing time by
        // CSQC_PredictCrowbarCommand, and CSQC_CrowbarSwingSeqFor hands it
        // back only when it belongs to THIS entity and THIS swing.  That
        // covers all three ways it goes stale: a spectated player rendered
        // through cl_weapons.qc:1805, a WS_FIRE that arrived from the server
        // without ever being predicted locally (weapon handed over
        // mid-swing), and the pre-first-swing value of 0 — which is
        // CROWBAR_SEQ_IDLE1 and would otherwise render the idle pose.
        float seq = CSQC_CrowbarSwingSeqFor(predicted_player);
        if (seq >= CROWBAR_SEQ_ATTACK1HIT)
            return seq;
        // Fall back to the miss cycle — what a swing looks like when nothing
        // was hit — driven by the rendered entity's OWN counter, so a remote
        // player's viewmodel swings off a remote swing count.
        return SH_CrowbarPickSwingSeq(predicted_player.wep_action_id, FALSE);
    }

    // Looping idle, for the reason spelled out in W_CrowbarFrame: an idle
    // is fed absolute cltime, and a non-looping sequence would freeze on its
    // final frame for the rest of the map.
    return CROWBAR_SEQ_IDLE2;
};

void() CSQC_CrowbarDropClear =
{
    // Drop the swing-prediction keys along with the weapon (cl_weapons.qc:452,
    // drop only — not a per-frame path).  The keys already gate every read, so
    // nothing is broken without this; it just stops a dropped crowbar's last
    // swing outliving it across a pickup, and across the predicted_player
    // respawn in CSQC_ResetPredictionState (cl_player.qc:1386) where the old
    // entity reference would otherwise dangle.
    csqc_crowbar_predicted_hit = 0;
    csqc_crowbar_anim_seq      = 0;
    csqc_crowbar_anim_owner    = world;
    csqc_crowbar_anim_id       = 0;
    self.melee_charge_ref      = 0;
};

void() CSQC_CrowbarEquip =
{
	self.weapon_name         = CROWBAR_DISPLAY_NAME;
	self.weapon_viewmodel    = CROWBAR_VIEWMODEL;
	self.weapon_worldmodel   = CROWBAR_WORLDMODEL;
	self.weapon_deploy_sound = CROWBAR_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictCrowbarCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_CrowbarDisplayFrame;
	self.csqc_drop_clear     = CSQC_CrowbarDropClear;
	self.weapon_uses_sequences = TRUE;
	self.melee_charge_ref    = 0;   // mirrors W_CrowbarEquip
};

#endif // CSQC
