// ============================================================
//  shared/weapons/sh_wpn_thspanner.qc  -  They Hunger spanner (melee)
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo, melee swing with an alternating two-take animation
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_spanner.as and
//  hunger/weapons/spanner/v_spanner.mdl.  Previously a pickup alias onto
//  WEP_WRENCH, which was at least a wrench for a wrench — but it wore
//  Opposing Force's pipe wrench model, not They Hunger's spanner.

// --- Sequence indices, out of hunger/weapons/spanner/v_spanner.mdl (8 seqs) -
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
//
// Indices match spanner_e (weapon_spanner.as:12-22).  Unlike the other seven
// They Hunger viewmodels this one DOES carry STUDIO_LOOPING — on 6 and 7 only,
// which is why the resting pose below is idle2 and not idle.
const float THSPAN_SEQ_IDLE     = 0;   // idle,     2.154 s  (29f @ 13)  NOT looping
const float THSPAN_SEQ_ATTACK   = 1;   // attack,   0.629 s  (23f @ 35)
const float THSPAN_SEQ_ATTACK2  = 2;   // attack2,  0.629 s  (23f @ 35)
const float THSPAN_SEQ_FIXIT    = 3;   // fixit,    0.629 s  (23f @ 35)  see the note below
const float THSPAN_SEQ_DRAW     = 4;   // draw,     0.667 s  (17f @ 24)
const float THSPAN_SEQ_HOLSTER  = 5;   // holster,  0.667 s  (17f @ 24)  no holster state exists here
const float THSPAN_SEQ_IDLE2    = 6;   // idle2,    1.867 s  (29f @ 15)  LOOPING  <- the resting idle
const float THSPAN_SEQ_IDLE3    = 7;   // idle3,    4.000 s  (61f @ 15)  LOOPING

// FIXIT is deliberately unreachable.  It is the repair animation for Sven
// Co-op's damage-a-friendly-machine mechanic, which has no counterpart here;
// weapon_spanner.as never sends it either.  Kept named rather than dropped so
// the index list still reads straight against the model.

const float THSPAN_FRAME_INTERVAL = 0.05;   // wepframe tick rate, not an anim rate

// weapon_spanner.as sets THREE different cooldowns off the swing's outcome —
// 0.66 s on a miss (:169), 0.35 s into a body (:220), 0.30 s into world
// geometry (:254).  One value is used here instead, and deliberately: the
// client predicts its own hit/miss verdict and can disagree with the server's
// for a single swing (sh_wpn_hlcrowbar.qc documents that at length), and an
// outcome-dependent rate of fire would turn that one disagreement into a
// lasting cadence mismatch.  0.5 s is the mod's own melee cadence — what
// WEP_HLCROWBAR uses — and sits between the script's fast and slow cases.
const float THSPAN_FIRE_DELAY     = 0.5;

// --- Balance ---
// :202 is `float flDamage = 10`, which is Half-Life's own sk_plr_crowbar
// value.  This mod already re-scaled that class of weapon upward — its crowbar
// deals 25, its wrench 60 — so the spanner takes the crowbar's number rather
// than the script's, which would leave it doing less than half the damage of
// the crowbar standing next to it in the same menu.
const float THSPAN_DAMAGE         = 25;
// :143 traces 32 units, which is again Half-Life's melee reach.  This mod uses
// 72 for both of its existing melee weapons, and a 32-unit spanner next to a
// 72-unit crowbar is not a trade-off, it is a worse crowbar.
const float THSPAN_RANGE          = 72;

// --- State durations, taken from the sequences themselves ---
const float THSPAN_DRAW_DURATION  = 0.667;   // draw
const float THSPAN_FIRE_DURATION  = 0.629;   // attack / attack2 (both the same length)

const string THSPAN_VIEWMODEL    = "models/hunger/weapons/spanner/v_spanner.mdl";
const string THSPAN_WORLDMODEL   = "models/hunger/weapons/spanner/w_spanner.mdl";
const string THSPAN_DEPLOY_SOUND = "";
const string THSPAN_DISPLAY_NAME = "SPANNER";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// weapon_spanner.as alternates the two takes on `(m_iSwing++) % 2`, and — note
// the difference from Half-Life's crowbar — it does so on the MISS branch
// (:162) and the HIT branch (:189) alike, off the same counter.  So unlike
// CROWBAR, there is no hit/miss split to reproduce and no place for the two
// sides to disagree: this only needs the swing number, and wep_action_id is
// bumped once per swing on both sides and rewound to the server's value at
// reconcile (sh_customdefs.qc:454).
//
// `x - floor(x/n)*n` is this codebase's fmod idiom (sh_pmove.qc:2578); there
// is no `%` operator.
float(float swing_id) SH_THSpannerPickSwingSeq =
{
    float n = swing_id - floor(swing_id / 2) * 2;
    if (n == 0) return THSPAN_SEQ_ATTACK;
    return THSPAN_SEQ_ATTACK2;
};

float(float now) SH_THSpannerTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= THSPAN_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= THSPAN_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

float(float now) SH_THSpannerTryFire =
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
    self.attack_finished  = now + THSPAN_FIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + THSPAN_FIRE_DELAY;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THSpannerPickupCopy =
{
};

void() W_THSpannerSwing =
{
    vector src, end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * THSPAN_RANGE;

    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, THSPAN_DAMAGE, W_BoneToHitgroup(trace_bone_id));

        // THE SAMPLE HAS TO BE PICKED INSIDE THE BODY TEST.  It used to be chosen
        // here, above it and unconditionally, so the WORLD pair rang out on a body
        // hit as well — and unlike every other melee weapon in this tree that got
        // this wrong on the client only, this one is the SERVER, so it was wrong
        // for everyone in earshot rather than just the swinger.
        //
        // Gearbox's set is split for exactly this: pwrench_hit1/2 are metal on the
        // world, pwrench_hitbod1/2/3 are the wet ones.  This weapon's own cited
        // source agrees — svencoop/scripts/maps/hunger/weapons/weapon_spanner.as
        // emits hitbod1/2/3 for a body and only falls to hit1/hit2 for the world.
        float into_body = W_CanDamageTarget(trace_ent);

        if (into_body)
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
            // Defer player damage to the attacker's client hitclaim so it is
            // not applied twice (server-auth + hitclaim).  BRACES MATTER —
            // without them the guard covers only the sv_dmg_bits line and the
            // damage lands regardless; see the same trap in sh_wpn_hlcrowbar.qc.
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                // .as:210 passes DMG_CLUB, which is in DMG_GIB_CORPSE — a body
                // really can be taken apart with this.
                sv_dmg_bits = DMG_CLUB;
                W_ApplyDamage(self, trace_ent, THSPAN_DAMAGE);
            }
        }
        else
        {
            PhysProp_TryPushFromTrace(v_forward, THSPAN_DAMAGE);
            W_ImpactEffect(trace_endpos);
        }
    }
    else
    {
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "weapons/pwrench_miss1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "weapons/pwrench_miss2.wav", 1, ATTN_NORM);
    }
};

void() W_THSpannerFire =
{
    if (SH_THSpannerTryFire(time))
    {
        // Same helper and same counter the client uses, so both sides land on
        // the same take.  The script alternates on hit and miss alike, so
        // unlike the crowbar this pick does not depend on the trace result and
        // there is nothing here that a mispredicted verdict could desync.
        self.weaponframe   = SH_THSpannerPickSwingSeq(self.wep_action_id);
        self.wep_nextframe = time + THSPAN_FRAME_INTERVAL;
        W_THSpannerSwing();
    }
};

void() W_THSpannerFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += THSPAN_FRAME_INTERVAL;

    result = SH_THSpannerTickState(time);
    if (result & 1)
    {
        // The resting pose has to be a LOOPING sequence.  Once idle,
        // wep_anim_start is 0 and cl_weapons.qc:1695 feeds frame1time = cltime
        // — absolute and unbounded — so a non-looping sequence is clamped to
        // its final frame (gl_hlmdl.c:1076-1082) and the viewmodel is a still
        // image for the rest of the map.  THSPAN_SEQ_IDLE is this model's one
        // NON-looping idle; only 6 and 7 carry the flag.
        self.weaponframe = THSPAN_SEQ_IDLE2;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).
        self.wep_nextframe = 0;
    }
};

void() W_THSpannerEquip =
{
    W_StandardEquipSetup(THSPAN_VIEWMODEL, THSPAN_DISPLAY_NAME, THSPAN_SEQ_DRAW,
        THSPAN_FRAME_INTERVAL, PLAYER_ATTACKANIM_MELEE);
    self.fire     = W_THSpannerFire;
    self.reload   = __NULL__;
    self.wepframe = W_THSpannerFrame;
    self.shoot    = W_THSpannerSwing;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_THSpannerDrop =
{
    entity tgt = weapon_drop_target;

    setmodel(tgt, THSPAN_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_spanner";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_THSPANNER;
    tgt.weapon_slot    = SLOT_MELEE;
    tgt.weap_draw      = W_THSpannerEquip;
    tgt.weap_drop_func = W_THSpannerDrop;
    tgt.pickupcopy     = W_THSpannerPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.dropped_spin   = 0;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thspanner =
{
    setmodel(self, THSPAN_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_spanner";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_THSPANNER;
    self.weapon_slot    = SLOT_MELEE;
    self.weap_draw      = W_THSpannerEquip;
    self.weap_drop_func = W_THSpannerDrop;
    self.pickupcopy     = W_THSpannerPickupCopy;
    self.touch          = weapon_touch;
    self.dropped_spin   = 0;
    W_RegisterMapWeapon(weapon_thspanner);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictTHSpannerCommand =
{
    // Skip fire during replay — no ammo to deplete, would cause infinite re-fires.
    // Try-fire outside the replay gate, effects inside — see the fuller note in
    // sh_wpn_oppipewrench.qc.  Gating the swing itself on pm_suppress_sounds
    // meant prediction replays never reproduced WS_FIRE and the viewmodel never
    // swung.
    if (input_buttons & 1)
    {
        if (SH_THSpannerTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // Mirrors W_THSpannerSwing's corrected split — the world pair in
                // the material slots, the body trio in the flesh tail.
                CSQC_PredictedMeleeTraceEx(THSPAN_RANGE, THSPAN_DAMAGE,
                    "weapons/pwrench_hit1.wav",
                    "weapons/pwrench_hit2.wav",
                    "weapons/pwrench_miss1.wav",
                    "weapons/pwrench_hitbod1.wav",
                    "weapons/pwrench_hitbod2.wav",
                    "weapons/pwrench_hitbod3.wav");
                // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
                CSQC_RecordPredictedMeleeSound();
            }
        }
    }

    SH_THSpannerTickState(csqc_pred_time);
};

// Returns a SEQUENCE index.  The engine does the within-sequence advance
// itself from .frame1time, so `elapsed` is unused — it stays in the signature
// because csqc_display_frame is a shared function-pointer type.
float(float elapsed) CSQC_THSpannerDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return THSPAN_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        // Driven by the RENDERED entity's own counter, so a spectated player's
        // viewmodel swings off their swing count rather than ours —
        // cl_weapons.qc:1805 calls this with predicted_player pointed at a
        // scratch entity.  No hit/miss branch to key, so no staleness to guard
        // against: the script alternates on both outcomes.
        return SH_THSpannerPickSwingSeq(predicted_player.wep_action_id);

    // Looping idle, for the reason spelled out in W_THSpannerFrame.
    return THSPAN_SEQ_IDLE2;
};

void() CSQC_THSpannerDropClear =
{
};

void() CSQC_THSpannerEquip =
{
    self.weapon_name         = THSPAN_DISPLAY_NAME;
    self.weapon_viewmodel    = THSPAN_VIEWMODEL;
    self.weapon_worldmodel   = THSPAN_WORLDMODEL;
    self.weapon_deploy_sound = THSPAN_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHSpannerCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_THSpannerDisplayFrame;
    self.csqc_drop_clear     = CSQC_THSpannerDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
