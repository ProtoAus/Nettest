// ============================================================
//  shared/weapons/sh_wpn_opsaw.qc  -  Opposing Force M249 SAW
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 200-round belt, 200 reserve, full-auto, 5.56mm
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: gearbox/sprites/weapon_m249.txt names it as one of Opposing
//  Force's ten weapons; gearbox/models/{v,p,w}_saw.mdl plus w_saw_clip.mdl, and
//  gearbox/sound/weapons/saw_fire1-3.wav + saw_reload.wav + saw_reload2.wav.
//
//  WHAT WAS HERE BEFORE: nothing.  WEP_M249 is the COUNTER-STRIKE M249
//  (sh_wpn_csm249.qc, tagged WMF_GAME_CS), so an Opposing Force or Sven map
//  placing `weapon_m249` handed you the CS gun -- a different model, a different
//  sound set and a 50-round magazine instead of a 200-round belt.  This file now
//  owns that classname and the CS gun moved to `weapon_csm249`.
//
//  EVERY SYMBOL IN HERE IS Saw/SAW_ PREFIXED because QC has ONE global
//  namespace and sh_wpn_csm249.qc already owns W_M249Fire, SH_M249TickState,
//  MAX_MAG_M249 and the rest.
//
//  BEHAVIOUR SOURCE.  There is no Opposing Force source on disk, so the numbers
//  come from Sven Co-op's manual (svencoop/manual/weapons.html), which covers
//  this weapon directly:
//      "The M249 SAW (squad automatic weapon) is a powerful yet portable machine
//       gun with a high firing rate and damage. ... It has a belt of 200 5.56 mm
//       rounds, but suffers high reload time."
//  Belt size, calibre, rate and the long reload are all from that quote.

// --- Ammo fields ---
.float mag_saw;
.float ammo_saw;

// Which of the two reload drills is running.  1 = the dry-belt one.  Only
// meaningful on a model whose two reload takes are ALTERNATIVES — see
// SH_SawReloadIsTwoPart.
.float saw_reload_long;
// How many reload event sounds have been played this drill.  A COUNTER, not a
// flag: svencoop's belt change carries seven of them.
.float saw_reload_snd_stage;

// --- Sequence indices, read out of gearbox/models/v_saw.mdl (9 seqs) ---------
// Dumped rather than recalled.  .frame is a SEQUENCE INDEX for a GoldSrc model
// (gl_hlmdl.c:780); durations are (numframes-1)/fps, what frameduration()
// reports (gl_hlmdl.c:1542).
//
// NOTE THE TWO IDENTICALLY LABELLED PAIRS.  Sequences 2 and 3 are BOTH labelled
// "reload1" and 6/7/8 are all labelled "shoot" -- the labels are just what the
// animator typed.  Their studio events are what tell them apart: 2 fires
// saw_reload.wav and 3 fires saw_reload2.wav, and they are 1.5 s against 2.444 s,
// which is the short top-up and the long dry-belt drill.  All three shoot takes
// carry event 5001 (muzzleflash, attachment 0) and are the same 0.2 s.
//
// The model declares ZERO attachments, so that muzzleflash event has nothing to
// hang on; the CSQC muzzle here is placed from camera-local offsets the way the
// UZI's is, not from a tag.
const float SAW_SEQ_SLOWIDLE = 0;   // slowidle, 5.000 s (101f @ 20)  LOOPING  <- resting
const float SAW_SEQ_IDLE2    = 1;   // idle2,    6.160 s (155f @ 25)  LOOPING
const float SAW_SEQ_RELOAD1  = 2;   // reload1,  1.500 s  (61f @ 40)  <- event saw_reload.wav
const float SAW_SEQ_RELOAD2  = 3;   // reload1,  2.444 s (111f @ 45)  <- event saw_reload2.wav
const float SAW_SEQ_HOLSTER  = 4;   // holster,  0.933 s  (29f @ 30)  no holster state here
const float SAW_SEQ_DRAW     = 5;   // draw,     1.000 s  (31f @ 30)
const float SAW_SEQ_SHOOT1   = 6;   // shoot,    0.200 s   (7f @ 30)
const float SAW_SEQ_SHOOT2   = 7;   // shoot,    0.200 s
const float SAW_SEQ_SHOOT3   = 8;   // shoot,    0.200 s

const float SAW_FRAME_INTERVAL = 0.05;   // wepframe tick rate, not an anim rate

// ~800 rpm.  "High firing rate" per the manual, and faster than the mod's other
// 5.56 weapons: the M16 runs 0.0857 (700 rpm) and the minigun 0.05 (1200).
const float SAW_FIRE_DELAY    = 0.075;
const float SAW_DRYFIRE_DELAY = 0.2;

const float MAX_MAG_SAW  = 200;   // "a belt of 200 5.56 mm rounds"
const float MAX_AMMO_SAW = 200;

// --- Balance ---
// Inside the mod's existing 5.56 family rather than invented: the Sven M16 is
// 18/9 over 3072 and the minigun is 9/5.  The SAW sits just under the rifle per
// bullet and well over it per second, which is what a belt-fed support weapon
// should feel like against a rifle, and it is the reading of "powerful ... high
// firing rate and damage" that does not simply beat everything.
//
// Accuracy is the trade: a 3-degree base cone against the M16's 2, and a wider
// move penalty, so it wants to be fired from a stop.
const float SAW_BASE_SPREAD          = 0.02618;   // VECTOR_CONE_3DEGREES
const float SAW_MOVE_SPREAD          = 0.10;
const float SAW_FULL_SPREAD_SPEED    = 320;
const float SAW_CLOSE_DAMAGE         = 16;
const float SAW_MIN_DAMAGE           = 8;
const float SAW_DAMAGE_FALLOFF_RANGE = 3072;
const float SAW_KICK_PITCH    = 1.3;    // LMG — heavy sustained kick
const float SAW_KICK_VARIANCE = 2.2;
const float SAW_KICK_STRENGTH = 1.6;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Placed from
// camera-local offsets because the model has no attachment; long barrel, so
// further forward than the UZI's 30.
const float SAW_MUZZLE_FORWARD = 40;
const float SAW_MUZZLE_RIGHT   = 6.0;
const float SAW_MUZZLE_DOWN    = 4.0;

// --- State durations ---
//
// FALLBACKS ONLY.  These are gearbox's numbers and gearbox's model is NOT the one
// that loads: svencoop ships its own v_saw.mdl (17 sequences, 2.7 MB against
// gearbox's 248 KB) and sits above gearbox in fs_addons.txt, so every one of
// these was measured against a file the engine never opens.  Asked of the model
// that actually wins:
//
//     draw      1.000 -> 1.100      shoot     0.200 -> 0.750
//     reload1   1.500 -> 3.567      reload2   2.444 -> 3.067
//
// The reload was the visible one — the state retired at 42 % of the take and the
// animation was cut off mid-drill with the ammo box still out.  Everything below
// now asks the live model through SH_SeqDuration and only falls back to these if
// the view model is not precached yet.
const float SAW_DRAW_DURATION    = 1.000;
const float SAW_FIRE_DURATION    = 0.200;
const float SAW_RELOAD1_DURATION = 1.500;
const float SAW_RELOAD2_DURATION = 2.444;

// --- Sven's reload events, fractions of their own take -----------------------
// The two models disagree about what sequences 2 and 3 MEAN, not just how long
// they are.  Gearbox labels both "reload1" and they are ALTERNATIVES: a short
// top-up (saw_reload.wav) and a long dry-belt drill (saw_reload2.wav).  Sven
// names them reload_start / reload1_2 and they are HALVES of one drill —
// reload_start ends with the cover open and the ammo box OUT, and reload1_2 puts
// the box in, feeds the belt and closes the cover.  Playing only one of Sven's
// halves leaves the gun visibly in pieces, which is why the two-part case below
// runs both back to back for the full 6.634 s.  "It has a belt of 200 5.56 mm
// rounds, but suffers high reload time" — svencoop/manual/weapons.html.
const float SAW_R1_F_BOLT      = 0.121;
const float SAW_R1_F_COVEROPEN = 0.449;
const float SAW_R1_F_BELTOUT   = 0.654;
const float SAW_R1_F_BOXOUT    = 0.841;
const float SAW_R2_F_BOXIN     = 0.217;
const float SAW_R2_F_BELTIN    = 0.370;
const float SAW_R2_F_COVERDOWN = 0.783;

const string SAW_VIEWMODEL    = "models/v_saw.mdl";
const string SAW_WORLDMODEL   = "models/w_saw.mdl";
const string SAW_DEPLOY_SOUND = "";
const string SAW_DISPLAY_NAME = "M249 SAW";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// Three shoot takes and three fire samples, cycled off wep_action_id rather than
// rolled so the predicted sound and animation agree with the server's.
// `x - floor(x/n)*n` is this codebase's fmod idiom (sh_pmove.qc:2578); there is
// no `%` operator.
float(float shot_id) SH_SawPickShootSeq =
{
    float n = shot_id - floor(shot_id / 3) * 3;
    if (n == 0) return SAW_SEQ_SHOOT1;
    if (n == 1) return SAW_SEQ_SHOOT2;
    return SAW_SEQ_SHOOT3;
};

string(float shot_id) SH_SawShootSound =
{
    float n = shot_id - floor(shot_id / 3) * 3;
    if (n == 0) return "weapons/saw_fire1.wav";
    if (n == 1) return "weapons/saw_fire2.wav";
    return "weapons/saw_fire3.wav";
};

// THE RESTING IDLE, BY NAME.  Sequence 0 is `slowidle` on gearbox's model and
// `idle_fidget` on Sven's — and Sven's index 0 does NOT carry STUDIO_LOOPING,
// so holding it meant feeding a non-looping 4 s fidget absolute cltime and
// freezing on its last frame (the trap written up in sh_wpn_thspanner.qc).  Both
// models have a looping resting pose; they just spell it differently.
float() SH_SawSeqIdle =
{
    float s = SH_SeqTryName(SAW_VIEWMODEL, "idle");       // svencoop, index 1, LOOPING
    if (s >= 0) return s;
    return SH_SeqForName(SAW_VIEWMODEL, "slowidle", SAW_SEQ_SLOWIDLE);   // gearbox
};

float() SH_SawSeqDraw = { return SH_SeqForName(SAW_VIEWMODEL, "draw", SAW_SEQ_DRAW); };

// TRUE when the loaded model splits the belt change into two consecutive takes
// rather than offering two alternative drills — see the note beside SAW_R1_F_*.
float() SH_SawReloadIsTwoPart =
{
    return SH_SeqTryName(SAW_VIEWMODEL, "reload_start") >= 0
        && SH_SeqTryName(SAW_VIEWMODEL, "reload1_2")    >= 0;
};

float() SH_SawReload1Duration =
{
    return SH_SeqDuration(SAW_VIEWMODEL, SAW_SEQ_RELOAD1, SAW_RELOAD1_DURATION);
};
float() SH_SawReload2Duration =
{
    return SH_SeqDuration(SAW_VIEWMODEL, SAW_SEQ_RELOAD2, SAW_RELOAD2_DURATION);
};

// Which drill is running.  Latched into a field at reload START rather than
// derived here, because the magazine is refilled part-way through and deriving
// it live would flip the answer mid-animation and retire the state early.
float() SH_SawReloadDuration =
{
    if (SH_SawReloadIsTwoPart())
        return SH_SawReload1Duration() + SH_SawReload2Duration();
    if (self.saw_reload_long)
        return SH_SawReload2Duration();
    return SH_SawReload1Duration();
};

float() SH_SawReloadSeq =
{
    if (SH_SawReloadIsTwoPart())
        return SAW_SEQ_RELOAD1;   // the display frame swaps to part two on time
    if (self.saw_reload_long)
        return SAW_SEQ_RELOAD2;
    return SAW_SEQ_RELOAD1;
};

float(float now) SH_SawTickState =
{
    float rel = SH_SawReloadDuration();
    return SH_StandardTickState(now, mag_saw, ammo_saw, MAX_MAG_SAW,
        SH_SeqDuration(SAW_VIEWMODEL, SH_SawSeqDraw(), SAW_DRAW_DURATION),
        // The fire STATE runs the whole shoot take, not one refire period.  It
        // gates nothing — SH_StandardTryFire and SH_StandardTryReload both refuse
        // only during WS_RELOAD and WS_DRAW — so the rate and the reload are
        // untouched; it just lets the gun finish settling after the last round
        // instead of snapping to idle at 27 % of the animation.
        SH_SeqDuration(SAW_VIEWMODEL, SAW_SEQ_SHOOT1, SAW_FIRE_DURATION),
        rel, rel);
};

// --- Reload event ladder ------------------------------------------------------
// How many of the belt change's event sounds should have fired by `elapsed`.
// Shared so the predicted client ladder and the server's cannot drift, and driven
// off the LIVE take lengths so it follows whichever v_saw.mdl won the mount.
// Only meaningful in the two-part case; the alternatives case has one sample.
float(float elapsed) SH_SawReloadSndStage =
{
    float d1 = SH_SawReload1Duration();
    float d2 = SH_SawReload2Duration();

    if (elapsed >= d1 + d2 * SAW_R2_F_COVERDOWN) return 7;
    if (elapsed >= d1 + d2 * SAW_R2_F_BELTIN)    return 6;
    if (elapsed >= d1 + d2 * SAW_R2_F_BOXIN)     return 5;
    if (elapsed >= d1 * SAW_R1_F_BOXOUT)         return 4;
    if (elapsed >= d1 * SAW_R1_F_BELTOUT)        return 3;
    if (elapsed >= d1 * SAW_R1_F_COVEROPEN)      return 2;
    if (elapsed >= d1 * SAW_R1_F_BOLT)           return 1;
    return 0;
};

string(float stage) SH_SawReloadSndName =
{
    switch (stage)
    {
    case 1: return "weapons/saw_bolt.wav";
    case 2: return "weapons/saw_coveropen.wav";
    case 3: return "weapons/saw_beltout.wav";
    case 4: return "weapons/saw_boxout.wav";
    case 5: return "weapons/saw_boxin.wav";
    case 6: return "weapons/saw_beltin.wav";
    case 7: return "weapons/saw_coverdown.wav";
    }
    return "";
};

float(float now) SH_SawTryFire =
{
    return SH_StandardTryFire(now, mag_saw, SAW_FIRE_DELAY, SAW_DRYFIRE_DELAY);
};

float(float now) SH_SawTryReload =
{
    // Pick the drill BEFORE starting it.  Both sides compute this from the same
    // replicated magazine count, so client and server land on the same duration
    // and the same sequence.
    self.saw_reload_long = (self.mag_saw <= 0);
    return SH_StandardTryReload(now, mag_saw, ammo_saw, MAX_MAG_SAW,
                                SH_SawReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_SawPickupCopy =
{
    player.mag_saw  = self.mag_saw;
    player.ammo_saw = self.ammo_saw;
};

void() W_SawShoot =
{
    W_PenetratingHitscanShoot(SAW_BASE_SPREAD, SAW_MOVE_SPREAD, SAW_FULL_SPREAD_SPEED,
        SAW_CLOSE_DAMAGE, SAW_MIN_DAMAGE, SAW_DAMAGE_FALLOFF_RANGE, 48, 0.97,
        SAW_KICK_PITCH, SAW_KICK_VARIANCE, SAW_KICK_STRENGTH);
};

void() W_SawFire =
{
    float r = SH_SawTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_SawPickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + SAW_FRAME_INTERVAL;

        W_SawShoot();

        sound(self, CHAN_WEAPON, SH_SawShootSound(self.wep_action_id), 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_SawReload =
{
    if (SH_SawTryReload(time))
    {
        self.weaponframe         = SH_SawReloadSeq();
        self.wep_nextframe       = time + SAW_FRAME_INTERVAL;
        self.saw_reload_snd_stage = 0;
    }
};

void() W_SawFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += SAW_FRAME_INTERVAL;

    // FTE does not run view-model studio events, so the reload's samples are
    // played from here.  Two shapes, because the two candidate models are two
    // different weapons: gearbox hangs ONE sample on each of its two alternative
    // drills, and svencoop's single two-part drill carries SEVEN — and the pairing
    // has to match, or the short drill gets the long sample and runs a second past
    // its own animation.
    if (self.weaponstate == WS_RELOAD)
    {
        float rel_el = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

        if (SH_SawReloadIsTwoPart())
        {
            // Jump straight to the newest stage rather than walking the ladder, so
            // a server hitch plays one sample instead of stacking four.
            float want = SH_SawReloadSndStage(rel_el);
            if (want > self.saw_reload_snd_stage)
            {
                self.saw_reload_snd_stage = want;
                sound(self, CHAN_AUTO, SH_SawReloadSndName(want), 1, ATTN_NORM);
            }
        }
        else if (!self.saw_reload_snd_stage)
        {
            self.saw_reload_snd_stage = 1;
            if (self.saw_reload_long)
                sound(self, CHAN_AUTO, "weapons/saw_reload2.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_AUTO, "weapons/saw_reload.wav", 1, ATTN_NORM);
        }
    }

    result = SH_SawTickState(time);
    if (result & 1)
    {
        // SH_SawSeqIdle, not a hardcoded 0: sequence 0 is the LOOPING `slowidle`
        // on gearbox's model but the NON-looping `idle_fidget` on svencoop's, and
        // a non-looping idle is fed absolute cltime and freezes on its last frame
        // (the trap is written up in sh_wpn_thspanner.qc).
        self.weaponframe = SH_SawSeqIdle();
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).
        self.wep_nextframe = 0;
    }
};

void() W_SawEquip =
{
    W_StandardEquipSetup(SAW_VIEWMODEL, SAW_DISPLAY_NAME, SH_SawSeqDraw(),
        SAW_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_SawFire;
    self.reload   = W_SawReload;
    self.wepframe = W_SawFrame;
    self.shoot    = W_SawShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(SAW_BASE_SPREAD, SAW_MOVE_SPREAD, SAW_FULL_SPREAD_SPEED, 5, TRUE);
};

void() W_SawDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_saw  = self.mag_saw;
    tgt.ammo_saw = self.ammo_saw;
    self.mag_saw  = 0;
    self.ammo_saw = 0;

    setmodel(tgt, SAW_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_m249";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_OPSAW;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_SawEquip;
    tgt.weap_drop_func = W_SawDrop;
    tgt.pickupcopy     = W_SawPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// THE GoldSrc CLASSNAME — see the handover note in sh_wpn_csm249.qc.
void() weapon_m249 =
{
    setmodel(self, SAW_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_m249";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_OPSAW;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_SawEquip;
    self.weap_drop_func = W_SawDrop;
    self.pickupcopy     = W_SawPickupCopy;
    self.touch          = weapon_touch;
    self.mag_saw        = MAX_MAG_SAW;
    self.ammo_saw       = MAX_AMMO_SAW;
    W_RegisterMapWeapon(weapon_m249);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_saw_reload_snd_stage;

void() CSQC_PredictSawCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_SawTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound(SH_SawShootSound(self.wep_action_id));
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(SAW_BASE_SPREAD, SAW_MOVE_SPREAD, SAW_FULL_SPREAD_SPEED,
                    SAW_CLOSE_DAMAGE, SAW_MIN_DAMAGE, SAW_DAMAGE_FALLOFF_RANGE, 48, 0.97,
                    SAW_KICK_PITCH, SAW_KICK_VARIANCE, SAW_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(SAW_MUZZLE_FORWARD, SAW_MUZZLE_RIGHT,
                    SAW_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(SAW_MUZZLE_FORWARD, SAW_MUZZLE_RIGHT,
                    SAW_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
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

    // Same two shapes as the server's ladder in W_SawFrame, and predicted for the
    // same reason every other reload sample here is: the shooter should hear it on
    // the frame they pressed reload, not a round-trip later.
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds)
    {
        float rel_el = (self.wep_anim_start > 0) ? (csqc_pred_time - self.wep_anim_start) : 0;

        if (SH_SawReloadIsTwoPart())
        {
            float want = SH_SawReloadSndStage(rel_el);
            if (want > csqc_saw_reload_snd_stage)
            {
                csqc_saw_reload_snd_stage = want;
                localsound(SH_SawReloadSndName(want));
                CSQC_RecordPredictedAutoSound();
            }
        }
        else if (!csqc_saw_reload_snd_stage)
        {
            csqc_saw_reload_snd_stage = 1;
            if (self.saw_reload_long)
                localsound("weapons/saw_reload2.wav");
            else
                localsound("weapons/saw_reload.wav");
            CSQC_RecordPredictedAutoSound();
        }
    }

    SH_SawTickState(csqc_pred_time);
};

void() CSQC_PredictSawReload =
{
    if (SH_SawTryReload(csqc_pred_time))
    { csqc_saw_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_SawDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_SawSeqDraw();
    if (predicted_player.weaponstate == WS_FIRE)
        // Driven by the RENDERED entity's own counter, so a spectated player's
        // viewmodel cycles off their shot count rather than ours
        // (cl_weapons.qc:1805 calls this with predicted_player pointed at a
        // scratch entity).
        return SH_SawPickShootSeq(predicted_player.wep_action_id);
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        // TWO HALVES OF ONE DRILL on svencoop's model: part one ends with the ammo
        // box out and the cover open, so stopping there leaves the gun visibly in
        // pieces.  Split on the live take length and rebase the second half's
        // sequence clock — the same shape the mortar's pack-up uses.
        if (SH_SawReloadIsTwoPart())
        {
            float d1 = SH_SawReload1Duration();
            if (elapsed < d1)
                return SAW_SEQ_RELOAD1;
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = min(elapsed - d1, SH_SawReload2Duration());
            return SAW_SEQ_RELOAD2;
        }
        return predicted_player.saw_reload_long ? SAW_SEQ_RELOAD2 : SAW_SEQ_RELOAD1;
    }
    return SH_SawSeqIdle();   // LOOPING on both candidate models — safe to hold
};

void() CSQC_SawDropClear =
{
    self.mag_saw  = 0;
    self.ammo_saw = 0;
};

void() CSQC_SawEquip =
{
    self.weapon_name         = SAW_DISPLAY_NAME;
    self.weapon_viewmodel    = SAW_VIEWMODEL;
    self.weapon_worldmodel   = SAW_WORLDMODEL;
    self.weapon_deploy_sound = SAW_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSawCommand;
    self.csqc_predict_reload = CSQC_PredictSawReload;
    self.csqc_display_frame  = CSQC_SawDisplayFrame;
    self.csqc_drop_clear     = CSQC_SawDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
