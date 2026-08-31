// ============================================================
//  shared/weapons/sh_wpn_dodmelee.qc  -  Day of Defeat melee, all four
//
//  Slot  : SLOT_MELEE  (impulse 3 / key 3)
//  Stats : no ammo; two alternating takes on primary, no secondary
//  Fire  : melee trace
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THESE — every model and sound comes from the mounted dod
//  gamedir.  All four names are DoD-exclusive (checked against valve, gearbox,
//  bshift, svencoop, cstrike and czero), which is why they resolve at all from a
//  mount deliberately sitting at the BOTTOM of fs_addons.txt.
//
//  ONE FILE FOR FOUR WEAPONS, the same call sh_wpn_csgrenades.qc makes for the
//  three CS grenades and for the same reason: measured from the models, all four
//  have an IDENTICAL four-sequence layout and differ only in the numbers.
//
//    dod/models/v_amerk.mdl       4 seqs, 27 bones   US M3 trench knife
//       [0] idle    9fps   66f  7.333s
//       [1] slash1 32fps   31f  0.969s
//       [2] slash2 32fps   31f  0.969s
//       [3] draw   25fps   20f  0.800s   f1 5004 "weapons/rifleselect.wav"
//    dod/models/v_fairbairn.mdl   4 seqs, 27 bones   Fairbairn-Sykes commando
//       [0] idle   12fps    2f  0.167s
//       [1] slash1 32fps   31f  0.969s
//       [2] slash2 32fps   31f  0.969s
//       [3] draw   25fps   12f  0.480s   f1 5004 "weapons/rifleselect.wav"
//    dod/models/v_paraknife.mdl   4 seqs, 28 bones   Fallschirmjager gravity knife
//       [0] idle   12fps   81f  6.750s
//       [1] slash1 32fps  101f  3.156s   <- FOUR TIMES the others; see the note
//       [2] slash2 32fps  101f  3.156s      on DODMELEE_FIRE_DURATION below
//       [3] draw   25fps   12f  0.480s   f1 5004 "weapons/rifleselect.wav"
//    dod/models/v_spade.mdl       4 seqs, 27 bones   Wehrmacht entrenching tool
//       [0] idle   12fps   61f  5.083s
//       [1] slash1 45fps   65f  1.444s
//       [2] slash2 45fps   65f  1.444s
//       [3] draw   40fps   31f  0.775s   f1 5004 "weapons/rifleselect.wav"
//
//  THE MODELS CARRY NO SWING OR HIT EVENTS — only the draw's rifleselect.  Every
//  other DoD viewmodel in this tree gets its reload/draw audio out of its own
//  studio events (event 5004 puts the .wav path in options[64]); these four have
//  none, so the whoosh and the impact samples are issued from code here.  The
//  set that exists in dod/sound/weapons is knife_slash1/2, knifeswing, knifeswing2,
//  knife_hit1..4, knife_hitwall1, knife_deploy1 — no per-weapon variants, so the
//  spade swings with the same samples the knives do.  That is DoD's own
//  arrangement, not an approximation.
//
//  EVERY SYMBOL IS DodMelee/DODMELEE_ PREFIXED.  QC has one global namespace and
//  this tree already has SH_KnifeTickState (CS), SH_OpKnifeTickState (OpFor) and
//  a katana; the obvious names are all taken.

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODMELEE_SEQ_IDLE   = 0;
const float DODMELEE_SEQ_SLASH1 = 1;
const float DODMELEE_SEQ_SLASH2 = 2;
const float DODMELEE_SEQ_DRAW   = 3;

const float DODMELEE_FRAME_INTERVAL = 0.0333334;

// Draw-sound latch (server side; the client has its own global pair, because a
// CSQC prediction replay must be able to re-issue nothing).
.float dodmelee_snd_stage;

// The draw's rifleselect event, as a FRACTION of the sequence rather than an
// absolute time, because the four draws are 0.480 s to 0.800 s long and the event
// is at frame 1 of each.
const float DODMELEE_DRAW_F_SELECT = 0.04;

// ============================================================
//  SHARED — per-weapon table
// ============================================================

string(float wep) SH_DodMeleeViewModel =
{
    switch (wep)
    {
    case WEP_DODAMERK:     return "models/v_amerk.mdl";
    case WEP_DODFAIRBAIRN: return "models/v_fairbairn.mdl";
    case WEP_DODPARAKNIFE: return "models/v_paraknife.mdl";
    case WEP_DODSPADE:     return "models/v_spade.mdl";
    }
    return "models/v_amerk.mdl";
};

// w_fairbairn.mdl DOES NOT EXIST in dod/models — the commando dagger has a view
// and a player model but no world pickup, because DoD hands the British kit out
// from a class menu and never drops it.  It borrows the US knife's, which is the
// closest silhouette in the set.
string(float wep) SH_DodMeleeWorldModel =
{
    switch (wep)
    {
    case WEP_DODAMERK:     return "models/w_amerk.mdl";
    case WEP_DODFAIRBAIRN: return "models/w_amerk.mdl";
    case WEP_DODPARAKNIFE: return "models/w_paraknife.mdl";
    case WEP_DODSPADE:     return "models/w_spade.mdl";
    }
    return "models/w_amerk.mdl";
};

string(float wep) SH_DodMeleeDisplayName =
{
    switch (wep)
    {
    case WEP_DODAMERK:     return "TRENCH KNIFE";
    case WEP_DODFAIRBAIRN: return "COMMANDO KNIFE";
    case WEP_DODPARAKNIFE: return "GRAVITY KNIFE";
    case WEP_DODSPADE:     return "SPADE";
    }
    return "KNIFE";
};

string(float wep) SH_DodMeleeClassname =
{
    switch (wep)
    {
    case WEP_DODAMERK:     return "weapon_amerknife";
    case WEP_DODFAIRBAIRN: return "weapon_fairbairn";
    case WEP_DODPARAKNIFE: return "weapon_paraknife";
    case WEP_DODSPADE:     return "weapon_spade";
    }
    return "weapon_amerknife";
};

// --- Balance ---
//
// Anchored on the melee ladder this tree already has: the CS knife is the fast
// one, the crowbar 25 at 72 units on a 0.50 refire, the OpFor knife the same
// damage at 0.35.  These four sit inside that, differentiated the way the real
// weapons differ rather than by inventing numbers:
//
//   trench knife    26 / 0.42  — a fighting knife, near the OpFor knife
//   commando knife  30 / 0.50  — the Fairbairn-Sykes is a stiletto: a thrusting
//                                blade, so more per hit and slower between hits
//   gravity knife   24 / 0.38  — the lightest and quickest of the three blades
//   spade           45 / 0.85  — an entrenching tool is a small axe.  Nearly
//                                double the damage of a knife for double the
//                                time between swings, and the longest reach.
//
// Reach follows the weapon: blades 64, the spade 76 (the crowbar's 72 plus the
// haft).  Nothing here two-shots a full-health player, which is the line the CS
// knife's back-stab already owns and this set should not cross.
float(float wep) SH_DodMeleeDamage =
{
    switch (wep)
    {
    case WEP_DODAMERK:     return 26;
    case WEP_DODFAIRBAIRN: return 30;
    case WEP_DODPARAKNIFE: return 24;
    case WEP_DODSPADE:     return 45;
    }
    return 26;
};

float(float wep) SH_DodMeleeRange =
{
    return (wep == WEP_DODSPADE) ? 76 : 64;
};

float(float wep) SH_DodMeleeFireDelay =
{
    switch (wep)
    {
    case WEP_DODAMERK:     return 0.42;
    case WEP_DODFAIRBAIRN: return 0.50;
    case WEP_DODPARAKNIFE: return 0.38;
    case WEP_DODSPADE:     return 0.85;
    }
    return 0.42;
};

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float(float wep) SH_DodMeleeSeqIdle =
{ return SH_SeqForName(SH_DodMeleeViewModel(wep), "idle", DODMELEE_SEQ_IDLE); };

float(float wep) SH_DodMeleeSeqDraw =
{ return SH_SeqForName(SH_DodMeleeViewModel(wep), "draw", DODMELEE_SEQ_DRAW); };

// Two takes, alternating on the swing counter so client and server land on the
// same one.  `x - floor(x/n)*n` is this tree's fmod idiom (sh_pmove.qc); QC has
// no `%`.
float(float wep, float swing_id) SH_DodMeleePickSwingSeq =
{
    string mdl = SH_DodMeleeViewModel(wep);
    float  n   = swing_id - floor(swing_id / 2) * 2;
    if (n == 0)
        return SH_SeqForName(mdl, "slash1", DODMELEE_SEQ_SLASH1);
    return SH_SeqForName(mdl, "slash2", DODMELEE_SEQ_SLASH2);
};

float(float wep) SH_DodMeleeDrawDuration =
{ return SH_SeqDuration(SH_DodMeleeViewModel(wep), SH_DodMeleeSeqDraw(wep), 0.800); };

// THE ANIMATION IS NOT THE CADENCE — but the STATE is what draws the animation,
// so clamping the state to the cadence truncated every swing.  This function used
// to return min(sequence, fire_delay):
//
//     amerk      slash 0.938 s, delay 0.42  -> cut at 45%
//     fairbairn  slash 0.938 s, delay 0.50  -> cut at 53%
//     paraknife  slash 3.125 s, delay 0.38  -> cut at 12%
//     spade      slash 1.422 s, delay 0.85  -> cut at 60%
//
// At the clamp SH_WeaponEnterIdle fires, the display frame falls to the idle pose
// and the swing SNAPS mid-arc.  Reported as "the DoD knives have attack times too
// short, you can[not] see the full attack animation" — and it was all four of
// them, worst on the paratrooper knife, which showed one eighth of its take.
//
// THE STATED REASON FOR THE CLAMP DOES NOT HOLD.  It said a 3.1 s WS_FIRE would
// "lock the weapon out for over three seconds per swing" — but SH_DodMeleeTryFire
// gates on attack_finished ALONE and does not refuse WS_FIRE (see it below), so a
// long fire state has never blocked the refire.  The cadence is
// SH_DodMeleeFireDelay and it is untouched; only the length of the drawing is.
//
// So the state now runs the take, and a swing started while one is still playing
// simply restarts it from frame 0 — which is exactly the "cut short by the next
// swing" the old comment wanted, and is what GoldSrc does, where SendWeaponAnim
// and m_flNextPrimaryAttack are independent of one another.  Spam the button and
// the paratrooper knife still only ever shows the first 0.38 s of its flick;
// swing once and you see the whole thing.
float(float wep) SH_DodMeleeFireDuration =
{
    return SH_SeqDuration(SH_DodMeleeViewModel(wep),
                          SH_DodMeleePickSwingSeq(wep, 0),
                          SH_DodMeleeFireDelay(wep));
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_DodMeleeTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodMeleeDrawDuration(self.weapon)) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_DodMeleeFireDuration(self.weapon)) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_DodMeleeTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    // A raised tactical shield occupies the swinging arm.  Melee weapons do not
    // go through SH_StandardTryFire, which is where that gate normally lives, so
    // it has to be repeated here — the same omission let a shielded player slash
    // with the CS knife.
    if (SH_ShieldBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished)  return 0;

    float delay = SH_DodMeleeFireDelay(self.weapon);

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + delay;
#ifdef CSQC
    self.csqc_fire_guard  = now + delay;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodMeleePickupCopy =
{
};

void() W_DodMeleeSwing =
{
    vector src, end;
    float  wep = self.weapon;
    float  dmg = SH_DodMeleeDamage(wep);

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * SH_DodMeleeRange(wep);

    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    if (trace_fraction < 1.0)
    {
        W_DebugImpact(trace_endpos, dmg, W_BoneToHitgroup(trace_bone_id));

        float into_body = W_CanDamageTarget(trace_ent);

        // DoD ships four flesh samples and exactly one wall sample.
        if (into_body)
        {
            float r = floor(random() * 4);
            if (r >= 4) r = 3;
            if (r == 0)      sound(self, CHAN_WEAPON, "weapons/knife_hit1.wav", 1, ATTN_NORM);
            else if (r == 1) sound(self, CHAN_WEAPON, "weapons/knife_hit2.wav", 1, ATTN_NORM);
            else if (r == 2) sound(self, CHAN_WEAPON, "weapons/knife_hit3.wav", 1, ATTN_NORM);
            else             sound(self, CHAN_WEAPON, "weapons/knife_hit4.wav", 1, ATTN_NORM);
        }
        else
            sound(self, CHAN_WEAPON, "weapons/knife_hitwall1.wav", 1, ATTN_NORM);

        if (into_body)
        {
            // The spade is an axe and opens crowbar-flagged breakables in one
            // hit, the way every other crowbar-class melee in this tree does.
            // The three knives do not: a stiletto is not a pry bar, and letting
            // every melee weapon do it would make the flag meaningless.
            float deal = dmg;
            if (wep == WEP_DODSPADE
                && Brush_IsBreakableClass(trace_ent)
                && (trace_ent.spawnflags & BREAKABLE_INSTANT_CROWBAR))
                deal = 9999;

            // Defer player damage to the attacker's hitclaim so it is not applied
            // twice.  BRACES MATTER — without them the guard covers only the
            // sv_dmg_bits line and the damage lands anyway; the same trap is
            // documented in sh_wpn_hlcrowbar.qc.
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
        // The whoosh.  Unlike the OpFor knife these takes carry NO studio sound
        // event of their own, so a miss is silent unless we say otherwise.
        sound(self, CHAN_WEAPON, (random() < 0.5) ? "weapons/knife_slash1.wav"
                                                  : "weapons/knife_slash2.wav", 1, ATTN_NORM);
    }
};

void() W_DodMeleeFire =
{
    if (SH_DodMeleeTryFire(time))
    {
        // Picked BEFORE the swing, so hit/miss is not yet known and cannot select
        // the take.  These models have no hit/miss pair anyway — two takes, both
        // used for both outcomes.
        self.weaponframe   = SH_DodMeleePickSwingSeq(self.weapon, self.wep_action_id);
        self.wep_nextframe = time + DODMELEE_FRAME_INTERVAL;
        W_DodMeleeSwing();
    }
};

void() W_DodMeleeFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the engine
    // advances the sub-frame from .frame1time.
    self.wep_nextframe += DODMELEE_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW
        && !self.dodmelee_snd_stage
        && (time - self.wep_anim_start) >= SH_DodMeleeDrawDuration(self.weapon) * DODMELEE_DRAW_F_SELECT)
    {
        sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
        self.dodmelee_snd_stage = 1;
    }

    float result = SH_DodMeleeTickState(time);
    if (result & 1)
    {
        self.weaponframe        = SH_DodMeleeSeqIdle(self.weapon);
        self.wep_nextframe      = 0;   // idle retire
        self.dodmelee_snd_stage = 0;
    }
};

void() W_DodMeleeEquip =
{
    W_StandardEquipSetup(SH_DodMeleeViewModel(self.weapon), SH_DodMeleeDisplayName(self.weapon),
        SH_DodMeleeSeqDraw(self.weapon), DODMELEE_FRAME_INTERVAL, PLAYER_ATTACKANIM_MELEE);
    self.fire     = W_DodMeleeFire;
    self.altfire  = __NULL__;
    self.reload   = __NULL__;
    self.wepframe = W_DodMeleeFrame;
    self.shoot    = W_DodMeleeSwing;
    self.dodmelee_snd_stage = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_DodMeleeDrop =
{
    entity tgt = weapon_drop_target;
    float  wep = self.weapon;

    setmodel(tgt, SH_DodMeleeWorldModel(wep));
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = SH_DodMeleeClassname(wep);
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = wep;
    tgt.weapon_slot    = SLOT_MELEE;
    tgt.weap_draw      = W_DodMeleeEquip;
    tgt.weap_drop_func = W_DodMeleeDrop;
    tgt.pickupcopy     = W_DodMeleePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.dropped_spin   = 0;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Spawn shims.  Day of Defeat delivers all four of these from the class menu and
// never gave them map entities, so these classnames are this mod's spelling, not
// dod.fgd's — the same arrangement the Sten and the Webley already use.  None of
// the four collides with an existing name in this tree.
void(float wep) W_DodMeleeSpawnCommon =
{
    setmodel(self, SH_DodMeleeWorldModel(wep));
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = SH_DodMeleeClassname(wep);
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = wep;
    self.weapon_slot    = SLOT_MELEE;
    self.weap_draw      = W_DodMeleeEquip;
    self.weap_drop_func = W_DodMeleeDrop;
    self.pickupcopy     = W_DodMeleePickupCopy;
    self.touch          = weapon_touch;
    self.dropped_spin   = 0;
};

void() weapon_amerknife = { W_DodMeleeSpawnCommon(WEP_DODAMERK);     W_RegisterMapWeapon(weapon_amerknife); };
void() weapon_fairbairn = { W_DodMeleeSpawnCommon(WEP_DODFAIRBAIRN); W_RegisterMapWeapon(weapon_fairbairn); };
void() weapon_paraknife = { W_DodMeleeSpawnCommon(WEP_DODPARAKNIFE); W_RegisterMapWeapon(weapon_paraknife); };
void() weapon_spade     = { W_DodMeleeSpawnCommon(WEP_DODSPADE);     W_RegisterMapWeapon(weapon_spade); };

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodmelee_snd_stage;
float csqc_dodmelee_snd_action;

void() CSQC_PredictDodMeleeCommand =
{
    if (predicted_player.wep_action_id != csqc_dodmelee_snd_action)
    {
        csqc_dodmelee_snd_action = predicted_player.wep_action_id;
        csqc_dodmelee_snd_stage  = 0;
    }

    // The TRY-FIRE must run on replay passes too; only the trace and its audio
    // are replay-suppressed.  Gating the whole block on pm_suppress_sounds is
    // what made the OpFor knife's +attack look inert — every reconcile replayed
    // the buffered commands without re-entering WS_FIRE, so the display frame
    // never left the idle pose.
    if (input_buttons & 1)
    {
        if (SH_DodMeleeTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                // THE FLESH SET IS NOT OPTIONAL.  With an empty body tail the
                // short form falls through to the MATERIAL slots on a player
                // hit, so stabbing someone played knife_hitwall1 — a stone
                // chip — while W_DodMeleeStrike's correct knife_hit1..4 was
                // muted on the attacker by the 1 s predicted-echo suppressor
                // in CSQC_Event_Sound (client/cl_main.qc:1399).  The mirror of
                // the bayonet bug fixed in sh_wpn_dod98k.qc: there flesh leaked
                // onto walls, here wall leaked onto flesh.
                //
                // Three of the server's four variants; the Ex form takes three
                // and the fourth is cosmetic variance on a sample nobody can
                // tell apart mid-fight.
                CSQC_PredictedMeleeTraceEx(SH_DodMeleeRange(self.weapon),
                    SH_DodMeleeDamage(self.weapon),
                    "weapons/knife_hitwall1.wav",
                    "",
                    "weapons/knife_slash1.wav",
                    "weapons/knife_hit1.wav",
                    "weapons/knife_hit2.wav",
                    "weapons/knife_hit3.wav");
                // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
                CSQC_RecordPredictedMeleeSound();
            }
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0
        && self.weaponstate == WS_DRAW && csqc_dodmelee_snd_stage < 1
        && (csqc_pred_time - self.wep_anim_start)
           >= SH_DodMeleeDrawDuration(self.weapon) * DODMELEE_DRAW_F_SELECT)
    {
        localsound("weapons/rifleselect.wav");
        CSQC_RecordPredictedAutoSound();
        csqc_dodmelee_snd_stage = 1;
    }

    SH_DodMeleeTickState(csqc_pred_time);
};

float(float elapsed) CSQC_DodMeleeDisplayFrame =
{
    float wep = predicted_player.weapon;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodMeleeSeqDraw(wep);
    if (predicted_player.weaponstate == WS_FIRE)
        // Driven by the RENDERED entity's own counter, so a spectated player's
        // viewmodel swings off their swing count rather than ours.
        return SH_DodMeleePickSwingSeq(wep, predicted_player.wep_action_id);

    // NONE of the four idles carries the looping flag — no sequence in any of
    // the 38 DoD viewmodels does — so the idle has to be re-sent on a timer or
    // it freezes on its last frame.  SH_SeqIdleDisplay is that timer.
    float idle = SH_SeqIdleDisplay(cltime, wep, predicted_player.weaponstate,
                                   SH_DodMeleeSeqIdle(wep), SH_DodMeleeSeqIdle(wep),
                                   10, 15);
    if (idle >= 0)
        return idle;
    return SH_DodMeleeSeqIdle(wep);
};

void() CSQC_DodMeleeDropClear =
{
};

void() CSQC_DodMeleeEquipCommon =
{
    self.weapon_name         = SH_DodMeleeDisplayName(self.weapon);
    self.weapon_viewmodel    = SH_DodMeleeViewModel(self.weapon);
    self.weapon_worldmodel   = SH_DodMeleeWorldModel(self.weapon);
    self.weapon_deploy_sound = "";
    self.csqc_predict_cmd    = CSQC_PredictDodMeleeCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_DodMeleeDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodMeleeDropClear;
    self.weapon_uses_sequences = TRUE;
    // DO NOT RESET csqc_dodmelee_snd_stage HERE — see the same note in
    // sh_wpn_dodat.qc.  CSQC_WeaponEquip is re-invoked from
    // CSQC_ResetToConfirmedState (client/cl_player.qc:1051) on every reconcile,
    // so a latch zeroed here is re-armed several times a second and every
    // already-passed sound event replays.  The per-action guard in
    // CSQC_PredictDodMeleeCommand is the correct re-arm point.  Fixed here
    // pre-emptively with the AT and MG cases: the melee weapons carry fewer
    // events so it was less audible, not absent.
};

// CSQC_WeaponEquip dispatches by id and sets self.weapon BEFORE calling these,
// so the common function can read it; the four wrappers exist only to give the
// dispatcher one name apiece.
void() CSQC_DodAmerkEquip     = { CSQC_DodMeleeEquipCommon(); };
void() CSQC_DodFairbairnEquip = { CSQC_DodMeleeEquipCommon(); };
void() CSQC_DodParaknifeEquip = { CSQC_DodMeleeEquipCommon(); };
void() CSQC_DodSpadeEquip     = { CSQC_DodMeleeEquipCommon(); };

#endif // CSQC
