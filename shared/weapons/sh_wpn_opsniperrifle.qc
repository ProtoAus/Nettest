// ============================================================
//  shared/weapons/sh_wpn_opsniperrifle.qc  -  Opposing Force M40A1 sniper rifle
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-round magazine, 20 reserve, bolt-action, 7.62
//  Fire  : lag-compensated hitscan, no falloff, scoped
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6969 (weapon_sniperrifle, "Sniper Rifle"),
//  svencoop/models/{v,p,w}_m40a1.mdl and the eleven svencoop/sound/weapons/
//  sniper_*.wav.
//
//  Previously an alias onto WEP_CSAWP carrying w_m40a1.mdl
//  (sv_goldsrc_pickups.qc:183) — a Counter-Strike AWP, which is a different
//  rifle with a different magazine and a different scope behaviour, wearing an
//  M40A1 on the ground.  It shares CAL_762 with the AWP and always did, so the
//  ammo side needs nothing new.
//
//  THE RELOAD IS TWO STAGES OF ONE DRILL, NOT TWO ALTERNATIVE FORMS.
//
//  This note has now been wrong in both directions, so here is the evidence
//  rather than the conclusion.  Parsed from the mstudioseqdesc_t/mstudioevent_t
//  tables of both mounted copies:
//
//    seq             gearbox                              svencoop
//    reload1  2.353  first_seq @0.029             2.700   first_seq  @0.017
//    reload2  1.815  second_seq @0.037            1.267   bolt1      @0.250
//    reload3  2.353  first_seq @0.029             2.700   first_seq  @0.017
//
//  reload3 is byte-identical to reload1 on both mounts — a duplicate slot, not a
//  third stage.  That part was right.  What was wrong was reading reload1 and
//  reload2 as EITHER/OR:
//
//    * The samples are named first_seq and second_seq.  They are the first and
//      second sequence of one reload, not the "full" and "short" versions of
//      two.  Nothing in either model names a short drill.
//    * reload2 starts with the bolt already back.  Played on its own it opens on
//      a pose the previous animation was supposed to leave it in, which in play
//      reads as "the bolt jumps back magically, then he pushes it forward, and
//      then I have full ammo with no clip removal" — reported verbatim.  The
//      clip change is in reload1, which under the either/or reading only ran
//      when the magazine happened to be empty.
//    * Both mounts agree structurally even though svencoop re-cut the audio:
//      Sven's stage 2 is a bolt cycle with a bolt sample, gearbox's is a longer
//      movement with second_seq.  Same two-stage shape, different foley.
//
//  So the reload runs reload1 -> reload2 as one drill of reload1+reload2
//  seconds, every time, and the magazine is credited at the end of stage 2.
//  Stage 2 restarts its animation clock through
//  csqc_viewmodel_sequence_time_override (the sh_wpn_csgrenades.qc:1227 idiom)
//  rather than by re-stamping wep_anim_start, because wep_anim_start is what
//  SH_StandardTickState measures the whole reload against — moving it would
//  restart the drill instead of advancing it.
//
//  Nothing branches on the magazine any more, so the sniper_reload_empty latch
//  this file used to carry is gone with the branch it existed to stabilise, and
//  so is the per-equip reset that only existed to clear it.

// --- Ammo fields ---
.float mag_sniper;
.float ammo_sniper;

// --- Sequence indices: FALLBACKS ONLY --------------------------------------
// Every one of these is now resolved by NAME at runtime (SH_SniperSeq*), and
// these constants are what SH_SeqForName falls back to when the model is not
// precached yet.  They must stay, and they must stay correct, but nothing reads
// them directly any more.
//
// WHY, and it is not theoretical: models/v_m40a1.mdl ships in TWO mounted
// gamedirs — gearbox and svencoop — with the SAME nine labels in the SAME order
// at DIFFERENT fps.  Which one wins depends on addon mount order, and that is
// not fixed: fs_addons.txt file order under a full remount, arrival order under
// fs_lazyaddons (which defaults to 1).  Measured:
//
//     seq              svencoop   gearbox
//     draw               0.5167    1.0000   <- 2x
//     slowidle           6.4250    4.3480
//     fire               1.7333    1.7632
//     firelastround      1.7333    1.7632
//     reload1            2.6833    2.3235
//     reload2            1.2500    1.7778   <- 1.4x the other way
//     slowidle2          4.2833    4.2833
//     holster            3.0000    1.1500
//
// Hardcoding either mount's seconds desyncs the animation on the other, which is
// why every duration below comes from SH_SeqDuration instead.
const float SNIPER_SEQ_DRAW      = 0;   // draw
const float SNIPER_SEQ_IDLE      = 1;   // slowidle       LOOPING
const float SNIPER_SEQ_FIRE      = 2;   // fire
const float SNIPER_SEQ_FIRE_LAST = 3;   // firelastround
const float SNIPER_SEQ_RELOAD1   = 4;   // reload1 — the full/empty drill
const float SNIPER_SEQ_RELOAD2   = 5;   // reload2 — the short/top-up drill

const float SNIPER_FRAME_INTERVAL = 0.05;

// Bolt-action: the fire animation IS the bolt cycle, so the refire delay is the
// animation and not a separate number.  There used to be a SNIPER_FIRE_DELAY
// 1.733 here; it is gone because SH_SniperFireDuration() resolves the same value
// from whichever model loaded, and a second hardcoded copy could only drift.
const float SNIPER_DRYFIRE_DELAY = 0.5;

const float MAX_MAG_SNIPER  = 5;
const float MAX_AMMO_SNIPER = 20;

// Bolt sound partway through the fire animation — the second half of that shot
// is the shooter working the action, and silence through it reads as a stutter.
//
// A FRACTION of the resolved sequence, not a hardcoded 0.75 s, for the mount
// reason above.  Both models put the bolt event at almost exactly the same
// fraction even though the sequences are different lengths:
//     svencoop frame 50/104 = 0.4808     gearbox frame 32/67 = 0.4776
const float SNIPER_FIRE_F_BOLT = 0.48;

// ONE SOUND PER STAGE, EACH AT ITS OWN STAGE'S t=0.  Every reload event on both
// mounts sits on frame 1, so there is no fraction to compute, and each sample
// fits inside the sequence that carries it:
//
//     stage              seq len   sample                     len     margin
//     reload1 svencoop    2.6833   sniper_reload_first_seq    2.595   +0.088
//     reload1 gearbox     2.3235   sniper_reload_first_seq    2.082   +0.242
//     reload2 svencoop    1.2500   (model event is bolt1)     1.107   +0.143
//     reload2 gearbox     1.7778   sniper_reload_second_seq   1.107   +0.671
//
// Stage 2 plays second_seq on both mounts.  On gearbox — the copy that wins on
// this install — that IS the model's own event.  On svencoop the model asks for
// sniper_bolt1.wav instead; substituting there is a deliberate simplification,
// because QC can read a sequence's NAME and LENGTH but not its event list, and
// branching on a duration threshold to guess the mount would be worse than the
// mismatch it fixes.
//
// The old SNIPER_RELOAD_SND1_TIME 0.40 / SNIPER_RELOAD_SND2_TIME 1.60 are gone.
// Both were inventions: the real boundary is the end of reload1, which is a
// resolved duration and differs by 0.36 s between the two mounts.

// --- Balance ---
// A dedicated anti-personnel rifle, so: no falloff worth the name (a sniper
// round that weakens at range is not a sniper round), a base cone of zero, and a
// move spread severe enough that firing on the move is pointless.
const float SNIPER_BASE_SPREAD          = 0;
const float SNIPER_MOVE_SPREAD          = 0.14;
const float SNIPER_FULL_SPREAD_SPEED    = 200;
const float SNIPER_CLOSE_DAMAGE         = 90;
const float SNIPER_MIN_DAMAGE           = 70;
const float SNIPER_DAMAGE_FALLOFF_RANGE = 8192;
// KICK_PITCH 4.0 matches the AWP exactly, which is the right class for a
// bolt-action sniper and is left alone.  KICK_STRENGTH was 5.0 — the single
// highest value in the mod, above the Barrett .50 (2.0) and the AWM (1.8) and
// five times the AWP's 1.0.  Nothing about a 7.62 sniper rifle justifies being
// the hardest-kicking weapon in the game; it read as the view being thrown at
// the ceiling on every shot.  1.8 puts it level with the AWM.
const float SNIPER_KICK_PITCH    = 4.0;
const float SNIPER_KICK_VARIANCE = 0.2;
const float SNIPER_KICK_STRENGTH = 1.8;

const float SNIPER_MUZZLE_FORWARD = 46;
const float SNIPER_MUZZLE_RIGHT   = 4.0;
const float SNIPER_MUZZLE_DOWN    = 6.0;

// --- State durations: FALLBACKS ONLY, same as the sequence indices above ---
const float SNIPER_DRAW_DURATION    = 0.517;
const float SNIPER_FIRE_DURATION    = 1.733;
const float SNIPER_RELOAD_DURATION  = 2.683;   // reload1 — stage 1 of the drill
const float SNIPER_RELOAD2_DURATION = 1.250;   // reload2 — stage 2 of the drill

const string SNIPER_VIEWMODEL    = "models/v_m40a1.mdl";
const string SNIPER_WORLDMODEL   = "models/w_m40a1.mdl";
const string SNIPER_DEPLOY_SOUND = "";
const string SNIPER_DISPLAY_NAME = "SNIPER RIFLE";

// ============================================================
//  SHARED — sequence + duration resolution
// ============================================================
// Same shape as sh_wpn_csglock.qc / sh_wpn_csg3sg1.qc: resolve by NAME with the
// old hardcoded index as the fallback, and take every duration from the model
// that actually loaded.  Both mounted copies use identical labels, so the
// single-name form is enough — no SH_SeqForName2 needed here.

float() SH_SniperSeqDraw     = { return SH_SeqForName(SNIPER_VIEWMODEL, "draw",          SNIPER_SEQ_DRAW); };
float() SH_SniperSeqIdle     = { return SH_SeqForName(SNIPER_VIEWMODEL, "slowidle",      SNIPER_SEQ_IDLE); };
float() SH_SniperSeqFire     = { return SH_SeqForName(SNIPER_VIEWMODEL, "fire",          SNIPER_SEQ_FIRE); };
float() SH_SniperSeqFireLast = { return SH_SeqForName(SNIPER_VIEWMODEL, "firelastround", SNIPER_SEQ_FIRE_LAST); };
float() SH_SniperSeqReload1  = { return SH_SeqForName(SNIPER_VIEWMODEL, "reload1",       SNIPER_SEQ_RELOAD1); };
float() SH_SniperSeqReload2  = { return SH_SeqForName(SNIPER_VIEWMODEL, "reload2",       SNIPER_SEQ_RELOAD2); };

float() SH_SniperDrawDuration    = { return SH_SeqDuration(SNIPER_VIEWMODEL, SH_SniperSeqDraw(),    SNIPER_DRAW_DURATION); };
float() SH_SniperFireDuration    = { return SH_SeqDuration(SNIPER_VIEWMODEL, SH_SniperSeqFire(),    SNIPER_FIRE_DURATION); };
float() SH_SniperReload1Duration = { return SH_SeqDuration(SNIPER_VIEWMODEL, SH_SniperSeqReload1(), SNIPER_RELOAD_DURATION); };
float() SH_SniperReload2Duration = { return SH_SeqDuration(SNIPER_VIEWMODEL, SH_SniperSeqReload2(), SNIPER_RELOAD2_DURATION); };

// ============================================================
//  SHARED — state machine
// ============================================================

// The whole drill: stage 1 then stage 2, back to back, resolved from whichever
// copy of the model is mounted.  2.35 + 1.81 = 4.17 s on gearbox, 2.70 + 1.27 =
// 3.97 s on svencoop.  Long, and deliberately so — it is what the animators
// built, and a bolt-action rifle that reloads in a second and a quarter was the
// thing that looked wrong.
//
// Nothing here reads the magazine.  That matters beyond tidiness:
// SH_StandardTickState credits the magazine at reload_apply_time, which for this
// weapon IS the full duration, so any magazine-dependent duration flips at the
// exact moment the rounds land — the elapsed time is then already past the new
// value and the reload terminates early on its own state machine.  A constant
// duration cannot do that.
float() SH_SniperReloadDuration =
{
    return SH_SniperReload1Duration() + SH_SniperReload2Duration();
};

float(float now) SH_SniperTickState =
{
    float rel = SH_SniperReloadDuration();
    return SH_StandardTickState(now, mag_sniper, ammo_sniper, MAX_MAG_SNIPER,
        SH_SniperDrawDuration(), SH_SniperFireDuration(), rel, rel);
};

float(float now) SH_SniperTryFire =
{
    // The fire ANIMATION is the bolt cycle, so the refire delay is the sequence
    // rather than a separate number — resolved, not the hardcoded 1.733.
    return SH_StandardTryFire(now, mag_sniper, SH_SniperFireDuration(), SNIPER_DRYFIRE_DELAY);
};

float(float now) SH_SniperTryReload =
{
    // Drop the scope on reload, as SH_AWPTryReload does.  A SCOPE_CLASS_SNIPER_BOLT
    // weapon that stays zoomed through a reload leaves the player looking down a
    // scope at an animation they cannot see, with no input that clears it.
    float r = SH_StandardTryReload(now, mag_sniper, ammo_sniper, MAX_MAG_SNIPER,
                                   SH_SniperReloadDuration());
    if (r == 1)
    {
        self.zoomstage = 0;
#ifdef SSQC
        self.sv_zoomstage = 0;
#endif
    }
    return r;
};

// Scope.  The M40A1 is a scoped bolt rifle and this was never implemented at
// all - no zoomstage, no altfire, no ADS profile - so right-click did nothing.
// Modelled on SH_AWPTryAltFire (sh_wpn_csawp.qc), which drives the same
// two-stage zoom that .zoomstage already carries over the wire.
float(float now) SH_SniperTryAltFire =
{
    // sv_codscopes short-circuit: in CoD mode cl_codscope.qc owns the scope
    // visuals entirely, exactly as it does for the scout and the AWP.
    if (PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (self.weaponstate != WS_IDLE)
        return 0;
    if (now < self.altfire_finished)
        return 0;

    if (self.zoomstage >= 2)
        self.zoomstage = 0;
    else
        self.zoomstage = self.zoomstage + 1;

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

.float sniper_snd_stage;

void(entity player) W_SniperPickupCopy =
{
    player.mag_sniper  = self.mag_sniper;
    player.ammo_sniper = self.ammo_sniper;
};

void() W_SniperShoot =
{
    W_PenetratingHitscanShoot(SNIPER_BASE_SPREAD, SNIPER_MOVE_SPREAD, SNIPER_FULL_SPREAD_SPEED,
        SNIPER_CLOSE_DAMAGE, SNIPER_MIN_DAMAGE, SNIPER_DAMAGE_FALLOFF_RANGE, 20, 0.85,
        SNIPER_KICK_PITCH, SNIPER_KICK_VARIANCE, SNIPER_KICK_STRENGTH);
};

void() W_SniperFire =
{
    float r = SH_SniperTryFire(time);

    if (r == 1)
    {
        // firelastround on the LAST round — a different animation because the
        // bolt is not worked when there is nothing to chamber.
        self.weaponframe   = (self.mag_sniper > 0) ? SH_SniperSeqFire() : SH_SniperSeqFireLast();
        self.wep_nextframe = time + SNIPER_FRAME_INTERVAL;
        self.sniper_snd_stage = 0;

        W_SniperShoot();

        if (self.mag_sniper > 0)
            sound(self, CHAN_WEAPON, "weapons/sniper_fire.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "weapons/sniper_fire_last_round.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_SniperReload =
{
    if (SH_SniperTryReload(time))
    {
        self.weaponframe   = SH_SniperSeqReload1();   // stage 1; W_SniperFrame advances
        self.wep_nextframe = time + SNIPER_FRAME_INTERVAL;
        self.sniper_snd_stage = 0;
    }
};

void() W_SniperFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += SNIPER_FRAME_INTERVAL;

    if (self.wep_anim_start > 0)
    {
        float el = time - self.wep_anim_start;

        // Bolt, partway through the fire animation.  Only when there was a
        // round left to chamber — firelastround does not cycle the action.
        if (self.weaponstate == WS_FIRE && self.sniper_snd_stage < 1
            && el >= SH_SniperFireDuration() * SNIPER_FIRE_F_BOLT && self.mag_sniper > 0)
        {
            sound(self, CHAN_AUTO, "weapons/sniper_bolt1.wav", 1, ATTN_NORM);
            self.sniper_snd_stage = 1;
        }

        // The two-stage reload drill.  Stage 1 at t=0, stage 2 at the end of
        // reload1 — where the animation ALSO has to change, or the second half
        // of the drill plays as a still frame of the first.  Both edges are
        // driven off the same resolved boundary the client uses, so the halves
        // cannot drift apart the way the old weaponframe-vs-magazine pair did.
        if (self.weaponstate == WS_RELOAD)
        {
            if (self.sniper_snd_stage < 1)
            {
                sound(self, CHAN_AUTO, "weapons/sniper_reload_first_seq.wav", 1, ATTN_NORM);
                self.sniper_snd_stage = 1;
            }
            else if (self.sniper_snd_stage < 2 && el >= SH_SniperReload1Duration())
            {
                sound(self, CHAN_AUTO, "weapons/sniper_reload_second_seq.wav", 1, ATTN_NORM);
                self.weaponframe      = SH_SniperSeqReload2();
                self.sniper_snd_stage = 2;
            }
        }
    }

    result = SH_SniperTickState(time);
    if (result & 1)
    {
        // slowidle carries STUDIO_LOOPING, so the resting pose is safe to hold.
        self.weaponframe   = SH_SniperSeqIdle();
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_SniperAltFire =
{
    if (SH_SniperTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        // No sniper_zoom sample exists on the mount (the OpFor set is bolt /
        // fire / reload only), so this borrows the AWP's shipped mod-local
        // zoom click rather than a Sven path that would resolve to nothing.
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

// W_SetADSProfile goes before the standard setup, as the AWP does - the scope
// class drives cl_codscope.qc's overlay and the FOV curve.
void() W_SniperEquip =
{
    W_SetADSProfile(FALSE, "cl_ads_sniperrifle", SCOPE_CLASS_SNIPER_BOLT);
    W_StandardEquipSetup(SNIPER_VIEWMODEL, SNIPER_DISPLAY_NAME, SH_SniperSeqDraw(),
        SNIPER_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_SniperFire;
    self.altfire  = W_SniperAltFire;
    self.reload   = W_SniperReload;
    self.wepframe = W_SniperFrame;
    self.shoot    = W_SniperShoot;
    self.weapon_uses_sequences = TRUE;
    W_ClearZoom();
    W_SetCrosshairProfile(SNIPER_BASE_SPREAD, SNIPER_MOVE_SPREAD, SNIPER_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_SniperDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_sniper  = self.mag_sniper;
    tgt.ammo_sniper = self.ammo_sniper;
    self.mag_sniper  = 0;
    self.ammo_sniper = 0;

    setmodel(tgt, SNIPER_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_sniperrifle";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_SNIPERRIFLE;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_SniperEquip;
    tgt.weap_drop_func = W_SniperDrop;
    tgt.pickupcopy     = W_SniperPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_sniperrifle =
{
    setmodel(self, SNIPER_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_sniperrifle";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_SNIPERRIFLE;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_SniperEquip;
    self.weap_drop_func = W_SniperDrop;
    self.pickupcopy     = W_SniperPickupCopy;
    self.touch          = weapon_touch;
    self.mag_sniper     = MAX_MAG_SNIPER;
    self.ammo_sniper    = MAX_AMMO_SNIPER;
    W_RegisterMapWeapon(weapon_sniperrifle);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_sniper_snd_stage;

void() CSQC_PredictSniperCommand =
{
    float r;

    // Predicted zoom toggle.  The server half of this (W_SniperAltFire) was wired
    // without this branch, which is why right-click still did nothing: the ADS
    // profile, the scope overlay and the FOV all key off the CLIENT's .zoomstage,
    // and nothing on the client was ever writing it.  SH_SniperTryAltFire is the
    // shared gate, so predicting it here cannot disagree with the server.
    if (input_buttons & 4)
    {
        if (SH_SniperTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_SniperTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (self.mag_sniper > 0)
                    localsound("weapons/sniper_fire.wav");
                else
                    localsound("weapons/sniper_fire_last_round.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(SNIPER_BASE_SPREAD, SNIPER_MOVE_SPREAD, SNIPER_FULL_SPREAD_SPEED,
                    SNIPER_CLOSE_DAMAGE, SNIPER_MIN_DAMAGE, SNIPER_DAMAGE_FALLOFF_RANGE, 20, 0.85,
                    SNIPER_KICK_PITCH, SNIPER_KICK_VARIANCE, SNIPER_KICK_STRENGTH);
                CSQC_MuzzleFlashAtMuzzle(SNIPER_MUZZLE_FORWARD, SNIPER_MUZZLE_RIGHT,
                    SNIPER_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(SNIPER_MUZZLE_FORWARD, SNIPER_MUZZLE_RIGHT,
                    SNIPER_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
            csqc_sniper_snd_stage = 0;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/dryfire1.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float el = csqc_pred_time - self.wep_anim_start;
        if (self.weaponstate == WS_FIRE && csqc_sniper_snd_stage < 1
            && el >= SH_SniperFireDuration() * SNIPER_FIRE_F_BOLT && self.mag_sniper > 0)
        { localsound("weapons/sniper_bolt1.wav"); CSQC_RecordPredictedAutoSound(); csqc_sniper_snd_stage = 1; }

        // Identical predicate to W_SniperFrame's, including the stage boundary.
        // These two used to disagree (server: weaponframe == RELOAD1, client:
        // mag_sniper <= 0), which is how the halves could pick different sounds.
        if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_sniper_snd_stage < 1)
            {
                localsound("weapons/sniper_reload_first_seq.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sniper_snd_stage = 1;
            }
            else if (csqc_sniper_snd_stage < 2 && el >= SH_SniperReload1Duration())
            {
                localsound("weapons/sniper_reload_second_seq.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sniper_snd_stage = 2;
            }
        }
    }

    SH_SniperTickState(csqc_pred_time);
};

void() CSQC_PredictSniperReload =
{
    if (SH_SniperTryReload(csqc_pred_time))
    { csqc_sniper_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_SniperDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_SniperSeqDraw();
    // The FIRE branch keeps its magazine test on purpose: SH_StandardTryFire
    // decrements before the display reads it, so "mag now 0" genuinely means
    // "that was the last round", which is what firelastround is for.
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_sniper > 0) ? SH_SniperSeqFire() : SH_SniperSeqFireLast();
    // The RELOAD branch must NOT read the magazine.  It used to, and the value
    // can move under it mid-reload — from the state machine crediting the mag,
    // and from a reconcile writing a stale slot_primary_mag — which flipped the
    // viewmodel part-way through.  The stage boundary is a resolved duration
    // and cannot move.
    //
    // Stage 2 needs its OWN animation clock: `elapsed` counts from the start of
    // the whole drill, so handing it to reload2 unchanged would sample that
    // sequence past its end and hold the final pose for 1.8 s.  The override is
    // the mechanism for exactly this (sh_wpn_csgrenades.qc:1227); the
    // dispatcher clears it before every call, so setting it only on this path
    // leaves every other branch alone.
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        float d1 = SH_SniperReload1Duration();
        if (elapsed < d1)
            return SH_SniperSeqReload1();
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time          = max(0, elapsed - d1);
        return SH_SniperSeqReload2();
    }
    return SH_SniperSeqIdle();   // LOOPING — safe to hold
};

void() CSQC_SniperDropClear =
{
    self.mag_sniper  = 0;
    self.ammo_sniper = 0;
};

void() CSQC_SniperEquip =
{
    // THE CLIENT HALF OF THE SCOPE DECLARATION, and the reason right-click did
    // nothing even after the server side was wired.
    //
    // CSQC_WeaponEquip (cl_weapons.qc) hard-resets weapon_scope_class to
    // SCOPE_CLASS_NONE and weapon_ads_prefix to "" before dispatching here, so
    // every scoped weapon in this tree calls W_SetADSProfile TWICE — once in its
    // SSQC equip and again here — and this file was the only one in the tree
    // with a single call.  With scope_class stuck at 0 on the client, both
    // CodScope_Eligible (cl_codscope.qc) and the ADS envelope in cl_viewfx.qc
    // return early, so the CoD scope path could never engage.
    //
    // That path is the live one: sv_codscopes defaults to 0 but cfg/server.cfg
    // sets it to 1, and SH_SniperTryAltFire short-circuits to the CoD scope in
    // that case.  So the legacy zoomstage branch below is the FALLBACK, and this
    // line is what makes the shipped configuration work.
    W_SetADSProfile(FALSE, "cl_ads_sniperrifle", SCOPE_CLASS_SNIPER_BOLT);

    self.weapon_name         = SNIPER_DISPLAY_NAME;
    self.weapon_viewmodel    = SNIPER_VIEWMODEL;
    self.weapon_worldmodel   = SNIPER_WORLDMODEL;
    self.weapon_deploy_sound = SNIPER_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSniperCommand;
    self.csqc_predict_reload = CSQC_PredictSniperReload;
    self.csqc_display_frame  = CSQC_SniperDisplayFrame;
    self.csqc_drop_clear     = CSQC_SniperDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
