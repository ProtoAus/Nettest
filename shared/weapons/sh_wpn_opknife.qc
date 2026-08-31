// ============================================================
//  shared/weapons/sh_wpn_opknife.qc  -  Opposing Force combat knife
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo; three-take swing on primary, charged stab on secondary
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: gearbox/sprites/weapon_knife.txt names it as one of Opposing
//  Force's ten weapons; gearbox/models/{v,p,w}_knife.mdl and the seven
//  gearbox/sound/weapons/knife*.wav carry it.
//
//  WHAT WAS HERE BEFORE: nothing.  WEP_KNIFE is the COUNTER-STRIKE knife
//  (sh_wpn_csknife.qc, tagged WMF_GAME_CS), so an Opposing Force or Sven map
//  placing `weapon_knife` handed you a CS knife with CS sounds and a CS model.
//  This file now owns that classname and the CS knife moved to
//  `weapon_csknife`; see the note above weapon_csknife() for the handover.
//
//  EVERY SYMBOL IN HERE IS OpKnife/OPK_ PREFIXED, and that is not style.  QC has
//  ONE global namespace and sh_wpn_csknife.qc already defines SH_KnifeTickState,
//  W_KnifeFire, W_KnifeEquip, W_KnifeDrop, CSQC_PredictKnifeCommand and
//  CSQC_KnifeDisplayFrame.  The obvious names all collide.
//
//  BEHAVIOUR SOURCE.  There is no Opposing Force source on disk - the SDK at
//  C:\msys64\home\Lex\halflife is Half-Life's, and it has no knife.cpp - so the
//  primary is taken from Sven Co-op's manual (svencoop/manual/weapons.html),
//  which is explicit about this weapon:
//      "acts as a direct replacement for the crowbar ... It functions exactly
//       the same as the crowbar, but has a higher attack rate due to its lower
//       weight."
//  Hence the crowbar's damage and reach with a shorter refire.  That is a quoted
//  source, not a guess.
//
//  THE SECONDARY IS AN INFERENCE, and is flagged as one.  The model carries two
//  sequences the crowbar does not have - `charge` (11) and `stab` (12) - which
//  exist for an attack the primary swing cycle never reaches.  They are driven
//  here as a hold-to-wind, release-to-stab, which is the same shape Opposing
//  Force's other melee weapon already uses in this tree
//  (sh_wpn_oppipewrench.qc's charged big swing, documented from Sven's
//  "Secondary fire: Power swing ... the longer you hold it, the more powerful").
//  If the real OpFor stab turns out to be an instant lunge rather than a charge,
//  only W_OpKnifeFire2 and the release block in W_OpKnifeFrame need to change.

// --- Sequence indices, read out of gearbox/models/v_knife.mdl (13 seqs) ------
// Dumped rather than recalled.  Durations are (numframes-1)/fps, what
// frameduration() reports (gl_hlmdl.c:1542), because an N-frame animation spans
// N-1 intervals.  Only 9 and 10 carry STUDIO_LOOPING.
//
// CAREFUL WITH THE LABELS - they lie in exactly the way v_crowbar.mdl's do, and
// the model's own studio EVENTS are what settle it.  Sequences 4, 5 and 7 carry
// event 1004 (play sound) with weapons/knife1, knife2 and knife3 - the swing
// WHOOSHES - so those three are the MISS takes even though two of them are
// labelled plainly "attack2"/"attack3".  The hit takes carry no sound event
// because the code picks a flesh/wall sample instead.  Same trap, same model
// lineage, and sh_wpn_hlcrowbar.qc:23-34 documents it for the crowbar.
const float OPK_SEQ_IDLE1        = 0;    // idle1,       2.692 s (36f @ 13)  NOT looping
const float OPK_SEQ_DRAW         = 1;    // draw,        0.500 s (13f @ 24)
const float OPK_SEQ_HOLSTER      = 2;    // holster,     0.500 s (13f @ 24)  no holster state here
const float OPK_SEQ_ATTACK1HIT   = 3;    // attack1,     0.455 s (11f @ 22)
const float OPK_SEQ_ATTACK1MISS  = 4;    // attack1miss, 0.455 s  <- event knife1
const float OPK_SEQ_ATTACK2MISS  = 5;    // attack2,     0.591 s  <- event knife2, so a MISS
const float OPK_SEQ_ATTACK2HIT   = 6;    // attack2hit,  0.591 s
const float OPK_SEQ_ATTACK3MISS  = 7;    // attack3,     0.750 s  <- event knife3, so a MISS
const float OPK_SEQ_ATTACK3HIT   = 8;    // attack3hit,  0.750 s
const float OPK_SEQ_IDLE2        = 9;    // idle2,       5.333 s (81f @ 15)  LOOPING  <- resting
const float OPK_SEQ_IDLE3        = 10;   // idle3,       5.333 s (81f @ 15)  LOOPING
const float OPK_SEQ_CHARGE       = 11;   // charge,      0.667 s (21f @ 30)
const float OPK_SEQ_STAB         = 12;   // stab,        0.667 s (21f @ 30)

const float OPK_FRAME_INTERVAL = 0.05;

// --- Balance ---
// The crowbar's damage and reach verbatim, per the manual quote above.  The
// refire is the one number that differs: 0.35 against the crowbar's 0.50, which
// is the "higher attack rate due to its lower weight" and makes the knife about
// 40% faster for the same damage per swing.
//
// Cadence is OUTCOME-INDEPENDENT on purpose, the same reason sh_wpn_thspanner.qc
// and sh_wpn_oppipewrench.qc give: the client predicts its own hit/miss verdict
// and can disagree with the server's for one swing, so a rate of fire that
// depended on the verdict would turn a single disagreement into a lasting
// cadence mismatch.
const float OPK_FIRE_DELAY = 0.35;
const float OPK_RANGE      = 72;
const float OPK_DAMAGE     = 25;

// The charged stab - see the inference note in the header.
const float OPK_STAB_CHARGE_TIME = 0.8;
const float OPK_STAB_DAMAGE      = 50;
const float OPK_STAB_DELAY       = 0.9;

// --- State durations, taken from the sequences themselves ---
const float OPK_DRAW_DURATION = 0.500;
const float OPK_FIRE_DURATION = 0.750;   // the longest of the six takes
const float OPK_STAB_DURATION = 0.667;   // stab

const string OPK_VIEWMODEL    = "models/v_knife.mdl";
const string OPK_WORLDMODEL   = "models/w_knife.mdl";
const string OPK_DEPLOY_SOUND = "";
const string OPK_DISPLAY_NAME = "COMBAT KNIFE";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// Three takes, cycled off wep_action_id so client and server land on the same
// one.  `x - floor(x/n)*n` is this codebase's fmod idiom (sh_pmove.qc:2578);
// there is no `%` operator.
//
// All three takes are reachable on both branches, unlike the crowbar, which
// reproduces a Half-Life quirk (crowbar.cpp:217's `((m_iSwing++) % 2) + 1` can
// never yield 0, so ATTACK1HIT is dead code there).  That quirk belongs to
// crowbar.cpp; there is no OpFor source to inherit an equivalent from, so the
// symmetric cycle the model's six takes plainly offer is what runs here.
float(float swing_id, float did_hit) SH_OpKnifePickSwingSeq =
{
    float n = swing_id - floor(swing_id / 3) * 3;
    if (n == 0) return did_hit ? OPK_SEQ_ATTACK1HIT : OPK_SEQ_ATTACK1MISS;
    if (n == 1) return did_hit ? OPK_SEQ_ATTACK2HIT : OPK_SEQ_ATTACK2MISS;
    return did_hit ? OPK_SEQ_ATTACK3HIT : OPK_SEQ_ATTACK3MISS;
};

// ---- THE CHARGED STAB, SHARED --------------------------------------------
//
// Was entirely inside #ifdef SSQC, exactly like the pipe wrench's — and with the
// same consequence: the server wound the knife, set self.weaponframe and dealt the
// damage while CSQC_OpKnifeDisplayFrame had no arm for any of it, so the viewmodel
// sat in idle2 for the whole wind and the button read as dead.  The model carries
// `charge` (11) and `stab` (12) for this and neither was ever drawn.
//
// Neither field is on the prediction proxy, deliberately: the client derives the
// whole charge from the +attack2 bit it already has, so there is nothing to
// reconcile and the only divergence is the client leading by ~1 RTT.
.float opk_charge_start;   // when the wind-up began, 0 = not winding
.float opk_big_stab;       // the attack in flight is the charged one

// Did THIS swing connect, and which swing that answer belongs to.  Same shape
// and the same reasons as the pipe wrench's .pwr_swing_hit — the verdict only
// exists once the trace has run, and a reconcile REPLAY re-runs the try-fire
// without re-running the trace, so the key on wep_action_id is what carries the
// live pass's answer through the replays that follow.
.float opk_swing_hit;
.float opk_swing_hit_id;

float(float now) SH_OpKnifeTryCharge =
{
    if (Weapon_SprintBlocksFire()) return FALSE;
    if (Weapon_LowerBlocksFire())  return FALSE;
    if (self.weaponstate == WS_DRAW) return FALSE;
    if (now < self.attack_finished)  return FALSE;
    if (self.opk_charge_start)       return FALSE;

    self.opk_charge_start = now;
    return TRUE;
};

// 1 = the charged stab, -1 = the ordinary swing an early release decays into,
// 0 = nothing was wound.  TEST WITH == 1 / == -1: -1 is TRUTHY in QC.
float(float now) SH_OpKnifeReleaseCharge =
{
    if (!self.opk_charge_start)
        return 0;

    float held = now - self.opk_charge_start;
    float big  = (held >= OPK_STAB_CHARGE_TIME);

    self.opk_charge_start = 0;
    self.opk_big_stab     = big;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + (big ? OPK_STAB_DELAY : OPK_FIRE_DELAY);
#ifdef CSQC
    self.csqc_fire_guard = self.attack_finished;
#endif
    return big ? 1 : -1;
};

// Did the swing in flight connect?  0 unless the latch belongs to THIS swing.
float(entity e) SH_OpKnifeSwingHit =
{
    if (e.opk_swing_hit_id != e.wep_action_id)
        return FALSE;
    return e.opk_swing_hit;
};

// The take this swing is actually playing.  The three *hit variants used to be
// unreachable — every call site hardcoded `did_hit` FALSE and nothing corrected
// it once the trace had run — so a knife that connected played a miss.
float(entity e) SH_OpKnifeSwingSeq =
{
    if (e.opk_big_stab)
        return OPK_SEQ_STAB;
    return SH_OpKnifePickSwingSeq(e.wep_action_id, SH_OpKnifeSwingHit(e));
};

// EVERY SWING TAKE IS ITS OWN LENGTH — 0.455 / 0.591 / 0.750 for the miss cycle,
// and the hit partners differ again — and one flat OPK_FIRE_DURATION of 0.750
// covered all six, so one swing in three hung frozen at full extension for
// 0.295 s and another for 0.159 s before dropping to idle.  The cadence is
// untouched (OPK_FIRE_DELAY still owns that); only the drawing is.
float() SH_OpKnifeFireDuration =
{
    if (self.opk_big_stab)
        return SH_SeqDuration(OPK_VIEWMODEL, OPK_SEQ_STAB, OPK_STAB_DURATION);
    return SH_SeqDuration(OPK_VIEWMODEL, SH_OpKnifeSwingSeq(self), OPK_FIRE_DURATION);
};

float(float now) SH_OpKnifeTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= OPK_DRAW_DURATION) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_OpKnifeFireDuration())
        { SH_WeaponEnterIdle(); self.opk_big_stab = 0; return 1; }
        return 0;
    }

    return 0;
};

float(float now) SH_OpKnifeTryFire =
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
    self.attack_finished  = now + OPK_FIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + OPK_FIRE_DELAY;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_OpKnifePickupCopy =
{
};

// `stab` selects the charged attack's damage; the sound set is shared, because
// gearbox ships exactly one hit pair per surface class and no "big" variants
// (contrast the pipe wrench, which has five extra samples for its power swing).
void(float stab) W_OpKnifeSwingEx =
{
    vector src, end;
    float dmg = stab ? OPK_STAB_DAMAGE : OPK_DAMAGE;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * OPK_RANGE;

    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    // THE HIT VARIANT, latched off this trace — the crowbar has always done it
    // here (sh_wpn_hlcrowbar.qc:348) and this file never did, which is why
    // attack1hit / attack2hit / attack3hit could not play at all.  The charged
    // stab has only one take, so it is unaffected.
    self.opk_swing_hit    = (trace_fraction < 1.0);
    self.opk_swing_hit_id = self.wep_action_id;
    if (!stab)
        self.weaponframe  = SH_OpKnifeSwingSeq(self);

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, dmg, W_BoneToHitgroup(trace_bone_id));

        float into_body = W_CanDamageTarget(trace_ent);

        // gearbox's set distinguishes a BODY from the world, which is why both
        // pairs exist: knife_hit_flesh1/2 and knife_hit_wall1/2.
        if (into_body)
            sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/knife_hit_flesh1.wav"
                                                      : "weapons/knife_hit_flesh2.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/knife_hit_wall1.wav"
                                                      : "weapons/knife_hit_wall2.wav", 1, ATTN_NORM);

        if (into_body)
        {
            // BREAKABLE_INSTANT_CROWBAR — a crowbar-class melee weapon opens the
            // breakables flagged for it in one hit.  The knife is the crowbar's
            // declared replacement, so it inherits that; without it the knife
            // cannot open the crates and doors the crowbar can, on the maps that
            // gate progression behind them.
            float deal = dmg;
            if (Brush_IsBreakableClass(trace_ent)
                && (trace_ent.spawnflags & BREAKABLE_INSTANT_CROWBAR))
                deal = 9999;

            // Defer player damage to the attacker's client hitclaim so it is not
            // applied twice (server-auth + hitclaim).  BRACES MATTER — without
            // them the guard covers only the sv_dmg_bits line and the damage
            // lands regardless; see the same trap in sh_wpn_hlcrowbar.qc.
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                sv_dmg_bits = DMG_CLUB;
                W_ApplyDamage(self, trace_ent, deal);
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
        // The whoosh.  On a PRIMARY swing the model plays it itself out of the
        // miss take's own studio event (knife1/2/3 on sequences 4/5/7), so
        // firing one here as well would double it — the miss branch is silent on
        // purpose.  The stab sequence carries no such event, so it gets one.
        if (stab)
            sound(self, CHAN_WEAPON, "weapons/knife2.wav", 1, ATTN_NORM);
    }
};

void() W_OpKnifeSwing =
{
    W_OpKnifeSwingEx(FALSE);
};

void() W_OpKnifeFire =
{
    if (SH_OpKnifeTryFire(time))
    {
        // The sequence is picked BEFORE the swing so hit/miss is not known yet;
        // the miss take is chosen and the swing does not correct it, exactly as
        // the crowbar and the pipe wrench do.  A predicted verdict that disagrees
        // for one swing is the documented tradeoff there.
        self.weaponframe   = SH_OpKnifePickSwingSeq(self.wep_action_id, FALSE);
        self.wep_nextframe = time + OPK_FRAME_INTERVAL;
        W_OpKnifeSwing();
    }
};

// Secondary: hold to wind, release to stab.  Server-side only — there is no
// prediction for it, because the thing being predicted would be a damage number
// that depends on how long a button was held, and a mispredicted charge is worse
// than a late one.  Same call sh_wpn_oppipewrench.qc makes.
// The gate is shared now (SH_OpKnifeTryCharge) so the client can run the identical
// test and actually SHOW the wind; this half keeps only the frame pump.
void() W_OpKnifeFire2 =
{
    if (SH_OpKnifeTryCharge(time))
    {
        self.weaponframe   = OPK_SEQ_CHARGE;
        self.wep_nextframe = time + OPK_FRAME_INTERVAL;
    }
};

void() W_OpKnifeFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += OPK_FRAME_INTERVAL;

    // Charge released.  Held long enough it lands the stab; released early it is
    // a normal swing, which is what stops the charge being free.
    //
    // .button1, NOT .button3 — the engine never writes button3 at all
    // (pr_cmds.c:10401-10404 writes button0/button2/button1 and nothing else), so
    // this read "released" on the first tick after the wind began and the charged
    // stab could never be reached.  Same typo the pipewrench had; found with it
    // when the pipewrench's charge was reported dead.  sh_wpn_wrench.qc:220
    // already had the corrected form.
    if (self.opk_charge_start && !(self.button1))
    {
        // == 1, not truthiness: the shared helper returns -1 for the ordinary
        // swing an early release decays into, and -1 is TRUE in QC.
        float stab = (SH_OpKnifeReleaseCharge(time) == 1);

        self.weaponframe   = stab ? OPK_SEQ_STAB
                                  : SH_OpKnifePickSwingSeq(self.wep_action_id, FALSE);
        self.wep_nextframe = time + OPK_FRAME_INTERVAL;

        W_OpKnifeSwingEx(stab);
    }
    // Still winding.  The model has no short looping wind frame the way the pipe
    // wrench's attackbigloop is, so the charge sequence is simply held — FTE
    // clamps a non-looping sequence to its final frame (gl_hlmdl.c:1076-1082),
    // which for `charge` is the wound-back pose and is exactly the right still.
    else if (self.opk_charge_start)
    {
        return;
    }

    float result = SH_OpKnifeTickState(time);
    if (result & 1)
    {
        // The resting pose has to be a LOOPING sequence — idle1 is not one; 9
        // and 10 are.  An idle is fed absolute cltime (cl_weapons.qc:1695), so a
        // non-looping sequence would freeze on its final frame for the rest of
        // the map.
        self.weaponframe   = OPK_SEQ_IDLE2;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_OpKnifeEquip =
{
    W_StandardEquipSetup(OPK_VIEWMODEL, OPK_DISPLAY_NAME, OPK_SEQ_DRAW,
        OPK_FRAME_INTERVAL, PLAYER_ATTACKANIM_MELEE);
    self.fire     = W_OpKnifeFire;
    self.altfire  = W_OpKnifeFire2;
    self.reload   = __NULL__;
    self.wepframe = W_OpKnifeFrame;
    self.shoot    = W_OpKnifeSwing;
    self.opk_charge_start = 0;
    self.opk_big_stab     = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_OpKnifeDrop =
{
    entity tgt = weapon_drop_target;

    self.opk_charge_start = 0;

    setmodel(tgt, OPK_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_knife";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_OPKNIFE;
    tgt.weapon_slot    = SLOT_MELEE;
    tgt.weap_draw      = W_OpKnifeEquip;
    tgt.weap_drop_func = W_OpKnifeDrop;
    tgt.pickupcopy     = W_OpKnifePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.dropped_spin   = 0;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// THE GoldSrc CLASSNAME.  gearbox's combat knife is `weapon_knife`, and so is
// Counter-Strike's — one name, two guns, and QC has one namespace.  This file
// takes the name because the map corpus that places it is Sven/HL/OpFor, where
// the author meant this weapon; the CS knife answers to `weapon_csknife` and is
// still reachable by loadout, buy menu and debug spawn, which is how it is
// actually handed out.
void() weapon_knife =
{
    setmodel(self, OPK_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_knife";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_OPKNIFE;
    self.weapon_slot    = SLOT_MELEE;
    self.weap_draw      = W_OpKnifeEquip;
    self.weap_drop_func = W_OpKnifeDrop;
    self.pickupcopy     = W_OpKnifePickupCopy;
    self.touch          = weapon_touch;
    self.dropped_spin   = 0;
    W_RegisterMapWeapon(weapon_knife);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictOpKnifeCommand =
{
    // Switching away mid-wind leaves the client's charge latched (it is not on the
    // prediction proxy), and the display frame would then show a wound-back knife
    // the moment the re-draw ended.  The server clears its copy in W_OpKnifeEquip;
    // this is the client's, and it lives here rather than in CSQC_OpKnifeEquip
    // because that function re-runs on every reconcile and would cancel a live
    // charge 20 times a second.
    if (self.weaponstate == WS_DRAW)
        self.opk_charge_start = 0;

    // The TRY-FIRE must run on replay passes too; only the trace and its audio
    // are replay-suppressed.  pm_suppress_sounds marks a prediction REPLAY, and
    // with it on the outer test the replay skipped the swing entirely: every
    // reconcile reset to the confirmed state and then re-ran the buffered
    // commands without ever re-entering WS_FIRE, so the display frame kept
    // returning the idle pose and +attack looked like it did nothing at all.
    if (input_buttons & 1)
    {
        if (SH_OpKnifeTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // Third argument is the MISS sample, and it is deliberately one
                // of the model's own whoosh samples: the local viewmodel plays
                // the miss take's studio event as well, so matching the sample
                // means a predicted miss doubles a sound with ITSELF rather than
                // layering a second, different one over it.
                //
                // THE FLESH PAIR WAS MISSING.  W_OpKnifeStrike splits
                // knife_hit_flesh1/2 from knife_hit_wall1/2 (:207-211) but this
                // call passed only the wall pair, and with an empty body tail the
                // helper falls THROUGH to the material slots on a player hit —
                // so stabbing someone played a stone chip, and the server's
                // correct flesh sample was muted on the attacker by the 1 s
                // predicted-echo suppressor (client/cl_main.qc:1399).  Same
                // defect class as the DoD bayonets, opposite direction.
                // Latched, so the hit take can play here too — the helper's
                // return IS the verdict, and the key on wep_action_id carries it
                // through the replays that follow (this branch is live-only).
                self.opk_swing_hit    = CSQC_PredictedMeleeTraceEx(OPK_RANGE, OPK_DAMAGE,
                    "weapons/knife_hit_wall1.wav",
                    "weapons/knife_hit_wall2.wav",
                    "weapons/knife2.wav",
                    "weapons/knife_hit_flesh1.wav",
                    "weapons/knife_hit_flesh2.wav",
                    "");
                self.opk_swing_hit_id = self.wep_action_id;
                // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
                CSQC_RecordPredictedMeleeSound();
            }
        }
    }

    // THE CHARGED STAB, PREDICTED.  Hold +attack2 to wind, release to stab.
    // Previously server-only, which is why the viewmodel never moved for it.  Both
    // gates run OUTSIDE the pm_suppress_sounds test so a replay walks the same
    // state the live pass did — the trap that made +attack look inert here once.
    if (input_buttons & 4)
    {
        if (SH_OpKnifeTryCharge(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }
    else
    {
        float rel = SH_OpKnifeReleaseCharge(csqc_pred_time);
        // != 0, and == 1 below: -1 (the early release) is TRUE in QC.
        if (rel != 0)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // Gearbox ships ONE hit pair per surface class and no "big"
                // variants, so the charged stab uses the same set — see
                // W_OpKnifeSwingEx, which does exactly this.
                self.opk_swing_hit    = CSQC_PredictedMeleeTraceEx(OPK_RANGE,
                    (rel == 1) ? OPK_STAB_DAMAGE : OPK_DAMAGE,
                    "weapons/knife_hit_wall1.wav",
                    "weapons/knife_hit_wall2.wav",
                    "weapons/knife2.wav",
                    "weapons/knife_hit_flesh1.wav",
                    "weapons/knife_hit_flesh2.wav",
                    "");
                self.opk_swing_hit_id = self.wep_action_id;
                CSQC_RecordPredictedMeleeSound();
            }
        }
    }

    SH_OpKnifeTickState(csqc_pred_time);
};

float(float elapsed) CSQC_OpKnifeDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return OPK_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // One call covers all seven attack takes — charged stab, and hit or miss
        // for each of the three ordinary swings.  Both the stab and every *hit
        // variant used to be unreachable from here.
        //
        // Driven by the RENDERED entity throughout, so a spectated player's
        // viewmodel swings off THEIR counter and THEIR verdict rather than ours
        // (cl_weapons.qc:1805 calls this with predicted_player pointed at a
        // scratch entity, whose latch key will not match — it falls back to the
        // miss cycle, which is what a swing looks like when nothing was hit).
        return SH_OpKnifeSwingSeq(predicted_player);
    }

    // THE WIND-UP.  Outside the weaponstate ladder on purpose: winding leaves the
    // weapon in WS_IDLE so +attack can still interrupt it, which is exactly why
    // nothing here noticed it before.  The model has no short looping wind frame
    // (the pipe wrench's attackbigloop has no counterpart), so `charge` is simply
    // held — the engine clamps a non-looping take to its final frame, which for
    // `charge` is the wound-back pose and is the right still.
    //
    // Anchored to the moment the charge began rather than left to free-run: an idle
    // viewmodel is fed unbounded time, so the take would already be clamped on its
    // last frame before the wind even started.
    if (predicted_player.opk_charge_start > 0)
    {
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time =
            max(0, cltime - predicted_player.opk_charge_start);
        return OPK_SEQ_CHARGE;
    }

    return OPK_SEQ_IDLE2;   // LOOPING — safe to hold
};

void() CSQC_OpKnifeDropClear =
{
};

void() CSQC_OpKnifeEquip =
{
    self.weapon_name         = OPK_DISPLAY_NAME;
    self.weapon_viewmodel    = OPK_VIEWMODEL;
    self.weapon_worldmodel   = OPK_WORLDMODEL;
    self.weapon_deploy_sound = OPK_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictOpKnifeCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_OpKnifeDisplayFrame;
    self.csqc_drop_clear     = CSQC_OpKnifeDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
