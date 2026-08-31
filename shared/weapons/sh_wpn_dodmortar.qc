// ============================================================
//  shared/weapons/sh_wpn_dodmortar.qc  -  DoD 3-inch / 8cm mortar
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : one bomb in the tube, 8 in reserve, high-arc indirect fire
//  Fire  : server-spawned projectile + radius explosion
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  NO ASSET SHIPS WITH THIS WEAPON — models/v_mortar.mdl, models/w_mortar.mdl
//  and models/p_mortar.mdl all come from the mounted dod gamedir.
//
//  TWO NAMING TRAPS, BOTH SILENT:
//
//   1. weapons/mortar.wav IS THE WRONG SOUND.  It is the obvious-looking name,
//      it exists, and it resolves to HALF-LIFE's 25 KB mortar whump — dod is the
//      lowest GoldSrc mount, and this mod already precaches that path for
//      func_mortar_field.  DoD's own 110 KB sample is weapons/mortar_shoot.wav,
//      which is DoD-exclusive and therefore reachable.  Same class of collision
//      as the bazooka's rocket1.wav (see sh_wpn_dodat.qc), except that this one
//      has a clean way out.
//   2. SEQUENCE 0 IS NOT AN IDLE on this model.  Index 0 is `round_up`, a 2.5 s
//      loading animation.  The usual `0` fallback would leave the mortar playing
//      a load loop whenever the view model has not been precached yet, so every
//      fallback below is named explicitly.
//
//  MEASURED FROM dod/models/v_mortar.mdl — 9 sequences, 53 bones.  Durations are
//  (frames-1)/fps; event marks are FRACTIONS of their own sequence.
//
//   [0] round_up    40fps 101f 2.500s   <- the reload: a bomb comes UP to the muzzle
//   [1] round_down  20fps  16f 0.750s
//   [2] idle_ready  30fps   2f 0.033s   <- LOADED idle: the bomb held over the tube
//   [3] fire        18fps  21f 1.111s
//         f1  mortar_load.wav      frac 0.050   <- the bomb dropping onto the pin
//         f10 5001 muzzleflash 71  frac 0.500   <- and THEN it leaves the tube
//   [4] idle_up     30fps   2f 0.033s   <- EMPTY idle: tube up, both hands free
//   [5] up_to_down  30fps  38f 1.233s
//   [6] idle_down   30fps   2f 0.033s
//   [7] down_to_up  17fps  41f 2.353s
//   [8] draw        30fps  31f 1.000s
//
//  THE MODEL HAS TWO IDLES AND THE DIFFERENCE IS THE WHOLE READ OF THE WEAPON.
//  round_up ENDS holding the bomb over the muzzle; idle_ready IS that pose held;
//  fire STARTS from it and drops the bomb in.  Pointing every idle at idle_up
//  broke the chain at both ends — see SH_DodMortarIdleFor.
//
//  THE BOMB LEAVES AT HALF THE FIRE TAKE, not at the trigger, and this file
//  honours that: the load sound plays on the press and the projectile is spawned
//  from the frame function at frac 0.5, where the model puts the flash.  It is
//  the only weapon in the tree that does that, and it is why the shot is NOT
//  predicted client-side — same call the AT launchers make for their rockets.
//
//  THE up/down PAIR IS NOW WIRED, and the weapon is EMPLACED the way DoD's is.
//  +attack2 AND weapon-special (impulse 7) both work — see the note on .special
//  in W_DodMortarEquip:
//
//      draw -> idle_up          standing, tube on the shoulder, cannot fire
//      +attack2 -> up_to_down   planting it, 1.233 s, cannot be interrupted.
//                               REQUIRES A CROUCH, and holds you crouched after —
//                               sh_pmove.qc forces PM_BTN_DUCK for the whole stance.
//      round_up -> idle_ready   a bomb comes up and is held over the muzzle.
//                               Runs AUTOMATICALLY once the plant lands, as the
//                               prepare take; it is not only the reload.
//      +attack  -> fire         the bomb drops in and leaves at frac 0.5
//      +attack2 -> round_down   the bomb goes back in the bag, 0.750 s (skipped
//                               when the tube is already empty)
//                -> down_to_up  1.235 s back to standing, movement returns
//
//  EMPTY TUBE, EMPLACED: the idle is idle_down and the auto-reload runs round_up
//  by itself the moment there is ammo for it.
//
//  The stance lives in .wep_deployed, and it is a REAL movement lock, not a
//  slow-down: SH_DodMortarSpeedFactor returns 0 while emplaced and is composed
//  into Weapon_SpeedFactor_Smooth beside the tactical shield's, which is the
//  existing precedent for a per-stance movement penalty in this tree.
//
//  The flag rides the prediction proxy's weapon-state section (v29) next to
//  satchel_state, for the same reason that one does: both sides predict it off
//  +attack2, so a client whose copy drifted would predict the wrong one of two
//  very different actions — and here a stuck flag would leave the player unable
//  to move at all.  It is reconciled UNCONDITIONALLY, outside trust_server_ammo,
//  beside ammo_cfc4: there is no client-side decrement to protect, and a stance
//  that could latch is a trap rather than a cosmetic error.
//
//  `round_down` IS wired now — see DODMORTAR_UNLOAD_F_CLEAR.  The note that used
//  to sit here said it stayed unwired because "this weapon keeps its round when
//  you stand up rather than unloading it", which confused the ROUND with the
//  ANIMATION: the bomb is held over the muzzle in the emplaced idle, not inside
//  the tube, so packing up with mag > 0 has to put it somewhere.  It does not
//  cost the round — mag_dodmortar is untouched across the whole transition.

// --- Ammo fields ---
.float mag_dodmortar;
.float ammo_dodmortar;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name, and see
//     the header: index 0 is round_up, NOT an idle) ---
const float DODMORTAR_SEQ_IDLE   = 4;   // idle_up    — standing, tube at rest
const float DODMORTAR_SEQ_READY  = 2;   // idle_ready — bomb poised over the muzzle
const float DODMORTAR_SEQ_FIRE   = 3;
const float DODMORTAR_SEQ_RELOAD = 0;   // round_up
const float DODMORTAR_SEQ_DRAW   = 8;
const float DODMORTAR_SEQ_DOWN   = 6;   // idle_down  — emplaced, tube on the ground
const float DODMORTAR_SEQ_PLANT  = 5;   // up_to_down — planting it
const float DODMORTAR_SEQ_LIFT   = 7;   // down_to_up — picking it back up
const float DODMORTAR_SEQ_UNLOAD = 1;   // round_down — the bomb back out of the muzzle

const float DODMORTAR_FRAME_INTERVAL = 0.0333334;
const float DODMORTAR_FIRE_DELAY     = 1.60;
const float DODMORTAR_DRYFIRE_DELAY  = 0.35;

const float DODMORTAR_FIRE_F_LOAD   = 0.050;   // bomb onto the pin
const float DODMORTAR_FIRE_F_LAUNCH = 0.500;   // and out of the tube
const float DODMORTAR_RELOAD_F_LOAD = 0.600;   // the new bomb goes in
// The plant take carries no event of its own; the baseplate lands near the end
// of it, so the thump goes there rather than on the button press.
const float DODMORTAR_PLANT_F_THUMP = 0.800;

// THE LIFT TAKE IS HALF PADDING, and that was the reported "unmounting takes a
// really long time".  Decoded frame by frame out of v_mortar.mdl and compared
// against idle_up (RMS over all 53 bones, local pose):
//
//     down_to_up  f0  15.42u / 49.01deg from idle_up   <- fully emplaced
//                 f11  0.70u / 15.34deg
//                 f21  0.00u /  0.00deg   t=1.235s  frac 0.525   <- ARRIVES
//                 f26..f40  0.00u / 0.00deg          <- BIT-IDENTICAL, 1.118s
//
// The viewmodel finishes standing up at 1.235 s and then holds that exact pose
// for another 1.118 s while the movement lock, the crouch and the fire block all
// run on.  Cutting the state at the frac makes the pair symmetric, which is what
// the artist actually authored: up_to_down is 1.233 s of motion and the live part
// of down_to_up is 1.235 s.  Expressed as a fraction, not a time, so a different
// v_mortar.mdl re-derives it from its own take length.
const float DODMORTAR_LIFT_F_LIVE = 0.525;

// PACKING THE BOMB AWAY.  round_down is the bomb coming back DOWN out of the
// muzzle and it is seamless at the loaded end — idle_ready[0] -> round_down[0]
// measures 0.000u / 0.00deg — so a loaded tube now stows the round before the
// tube comes up off the baseplate, instead of the bomb vanishing out of the
// gunner's hand.  Reported as "needs to put the mortar away when you unmount".
// The round is NOT lost: mag_dodmortar is untouched, the bomb just goes back in
// the bag and comes out again on the next round_up.
const float DODMORTAR_UNLOAD_F_CLEAR = 0.550;   // the bomb clears the muzzle

const float DODMORTAR_IDLE_REARM_MIN = 10;
const float DODMORTAR_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODMORTAR  = 1;
const float MAX_AMMO_DODMORTAR = 8;

// --- Balance ---
//
// The heaviest single warhead in the mod and the slowest delivery, which is the
// trade.  150 peak over a 340-unit radius against the Panzerschreck's 130/310 —
// a mortar bomb is a bigger charge than a shaped anti-tank round — but it is
// LOBBED at 900 with full gravity, so it takes a visible second to arrive and
// cannot be aimed directly at anything you can see moving.  One in the tube, a
// 2.5 s reload, eight bombs total.
const float DODMORTAR_DAMAGE     = 150;
const float DODMORTAR_MIN_DAMAGE = 30;
const float DODMORTAR_RADIUS     = 340;
const float DODMORTAR_SPEED      = 900;

// Minimum launch elevation, degrees above horizontal.  See W_DodMortarLaunch —
// 45 is the maximum-range ballistic angle, so a level view is the longest shot
// and elevating shortens it, which is how a mortar's range table actually
// works.  It also means the weapon can never be fired flat, which was the
// complaint.  Raise it for a steeper, shorter-ranged weapon.
//
// CONSEQUENCE WORTH KNOWING: indoors the bomb goes UP.  Under a low ceiling it
// detonates overhead and the 340-unit blast comes back down on the firer.  That
// is what a mortar does in a corridor and the tube in your hands is pointing at
// the ceiling while you do it, so it is left honest rather than special-cased.
const float DODMORTAR_MIN_ELEVATION = 45;

const float DODMORTAR_KNOCKBACK_PUSH   = 520;
const float DODMORTAR_KNOCKBACK_UPLIFT = 260;

const float DODMORTAR_MUZZLE_FORWARD = 30;
const float DODMORTAR_MUZZLE_RIGHT   = 0;
const float DODMORTAR_MUZZLE_DOWN    = -6;

const string DODMORTAR_VIEWMODEL    = "models/v_mortar.mdl";
const string DODMORTAR_WORLDMODEL   = "models/w_mortar.mdl";
const string DODMORTAR_DEPLOY_SOUND = "";
const string DODMORTAR_DISPLAY_NAME = "MORTAR";

.float dodmortar_snd_stage;

// The emplaced stance lives in the SHARED .wep_deployed (sh_weapons.qc), which
// the three machine guns and the BAR use too — see the note there.

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodMortarSeqIdle   = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "idle_up",    DODMORTAR_SEQ_IDLE); };
float() SH_DodMortarSeqReady  = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "idle_ready", DODMORTAR_SEQ_READY); };
float() SH_DodMortarSeqFire   = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "fire",     DODMORTAR_SEQ_FIRE); };
float() SH_DodMortarSeqReload = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "round_up", DODMORTAR_SEQ_RELOAD); };
float() SH_DodMortarSeqDraw   = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "draw",     DODMORTAR_SEQ_DRAW); };
float() SH_DodMortarSeqDown   = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "idle_down",  DODMORTAR_SEQ_DOWN); };
float() SH_DodMortarSeqPlant  = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "up_to_down", DODMORTAR_SEQ_PLANT); };
float() SH_DodMortarSeqLift   = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "down_to_up", DODMORTAR_SEQ_LIFT); };
float() SH_DodMortarSeqUnload = { return SH_SeqForName(DODMORTAR_VIEWMODEL, "round_down", DODMORTAR_SEQ_UNLOAD); };

// WHICH IDLE DEPENDS ON WHETHER THERE IS A BOMB IN THE HAND, and the model is
// explicit about it: `idle_up` is the tube on the shoulder with both hands
// empty, `idle_ready` is the bomb held POISED OVER THE MUZZLE — which is
// exactly the pose `round_up` finishes on and exactly the pose `fire` begins
// from.  The two are 0.033 s stills, so they are held poses, not animations.
//
// Using idle_up for both is what produced the reported "you press reload, he
// holds a mortar over the barrel, and then it jumps/resets to the mortar
// pointing up ... but when you fire, he jumps to holding the mortar over the
// barrel and drops it in and fires immediately".  Two snaps per shot, one at
// each end of the idle, and both of them are the same mistake: the idle was the
// wrong half of a pair.  Keying it on the magazine joins the poses up — a
// loaded tube HOLDS the bomb, firing releases it into the tube, and only an
// empty tube rests, until round_up brings the next one up to the ready pose.
//
// Takes the magazine as a PARAMETER rather than reading self: SSQC runs this on
// the player and the CSQC display path runs it on predicted_player, and the two
// are not the same entity.
// STANDING is a third pose, and it comes first: a tube on the shoulder is not
// loaded and cannot be.  Only once the mortar is planted does the loaded/empty
// pair above apply.
float(float deployed, float mag) SH_DodMortarIdleFor =
{
    if (!deployed)
        return SH_DodMortarSeqIdle();
    return (mag > 0) ? SH_DodMortarSeqReady() : SH_DodMortarSeqDown();
};

float() SH_DodMortarDrawDuration   = { return SH_SeqDuration(DODMORTAR_VIEWMODEL, SH_DodMortarSeqDraw(),   1.000); };
float() SH_DodMortarFireDuration   = { return SH_SeqDuration(DODMORTAR_VIEWMODEL, SH_DodMortarSeqFire(),   1.111); };
float() SH_DodMortarReloadDuration = { return SH_SeqDuration(DODMORTAR_VIEWMODEL, SH_DodMortarSeqReload(), 2.500); };
float() SH_DodMortarPlantDuration  = { return SH_SeqDuration(DODMORTAR_VIEWMODEL, SH_DodMortarSeqPlant(),  1.233); };
float() SH_DodMortarUnloadDuration = { return SH_SeqDuration(DODMORTAR_VIEWMODEL, SH_DodMortarSeqUnload(), 0.750); };
// Only the LIVE part of the take — see DODMORTAR_LIFT_F_LIVE.
float() SH_DodMortarLiftDuration   =
{
    return SH_SeqDuration(DODMORTAR_VIEWMODEL, SH_DodMortarSeqLift(), 2.353) * DODMORTAR_LIFT_F_LIVE;
};

// The stance change runs in WS_SPECIAL, so the take that is playing is decided
// by the stance we are LEAVING — planting from standing, lifting from emplaced.
//
// PACKING UP IS TWO TAKES, not one: round_down stows the bomb and then
// down_to_up brings the tube up.  Takes the magazine as a parameter for the same
// reason SH_DodMortarIdleFor does — the display path runs on predicted_player and
// the state machine runs on self, and they are not the same entity.
// Returns the take the transition STARTS on, which is what the server needs for
// its initial .weaponframe; the client's display path re-picks per frame because
// the packing case switches take part way through.
float(float deployed, float mag) SH_DodMortarSeqStance =
{
    if (!deployed)
        return SH_DodMortarSeqPlant();
    if (mag > 0)
        return SH_DodMortarSeqUnload();
    return SH_DodMortarSeqLift();
};
float(float deployed, float mag) SH_DodMortarStanceDuration =
{
    if (!deployed)
        return SH_DodMortarPlantDuration();
    if (mag > 0)
        return SH_DodMortarUnloadDuration() + SH_DodMortarLiftDuration();
    return SH_DodMortarLiftDuration();
};

// The MOVEMENT LOCK is the shared SH_DeploySpeedFactor (sh_weapons.qc), armed by
// weapon_deployable in W_DodMortarEquip below.

// ============================================================
//  SHARED — state machine
// ============================================================

// Defined below — SH_DodMortarTickState calls it for the auto-reload.
float(float now) SH_DodMortarTryReload;

// One bomb in the tube means every shot ends empty, so the reload is the normal
// case.  Same poll (not edge), same SSQC-only rule and the same reasons as
// sh_wpn_dodat.qc and sh_wpn_hlrpg.qc — the fire animation ends at 1.111 s and
// the debounce runs to 1.60 s, so an edge test would always be half a second
// early; and predicting it double-reloads a one-round magazine.
float(float now) SH_DodMortarWantsAutoReload =
{
    // A shouldered tube is not loaded.  round_up brings a bomb up to a muzzle
    // that is pointing at the sky over a baseplate on the ground; it makes no
    // sense from the standing pose and its end pose (idle_ready) is an emplaced
    // one, so loading is gated on the stance.
    if (!self.wep_deployed)    return FALSE;
    if (self.mag_dodmortar > 0)      return FALSE;
    if (self.ammo_dodmortar <= 0)    return FALSE;
    // GATE ON THE FIRE ANIMATION, NOT ON attack_finished — this line was the
    // reported "it jumps to a strange position, then jumps again, and then
    // resets the reload".
    //
    // attack_finished is fire-time + DODMORTAR_FIRE_DELAY (1.60 s), but `fire`
    // is 1.111 s.  SH_StandardTickState retired the weapon to WS_IDLE the moment
    // the take ended, and then this held the reload back for another 0.489 s.
    // On this model the empty idle is a DIFFERENT POSE — SH_DodMortarIdleFor
    // hands back idle_up once the tube is empty — so that window spliced idle_up
    // into a loop the artist authored closed.  Measured on v_mortar.mdl, max
    // world-space bone displacement:
    //     fire end -> idle_up      66.4 u      <- jump one
    //     idle_up  -> round_up f0  56.1 u      <- jump two
    //     fire end -> round_up f0  17.6 u      <- what the model was built for
    //     round_up end -> idle_ready and idle_ready -> fire are both 0.00 u
    // Two ~60-unit snaps in place of one 17-unit transition, exactly as reported.
    //
    // SH_StandardTickState runs FIRST inside SH_DodMortarTickState, so on the
    // very tick `fire` ends weaponstate is already WS_IDLE and the reload starts
    // in that same tick — no idle frame is ever rendered.
    //
    // NOT simply deleted: SH_StandardTryReload refuses during WS_RELOAD and
    // WS_DRAW but NOT during WS_FIRE, and the magazine is already 0 by then, so
    // an ungated poll would start the reload on the tick of the shot and `fire`
    // would never play at all.
    if (self.weaponstate != WS_IDLE) return FALSE;
    return TRUE;
};

// The stance toggle.  Both sides run it off +attack2, exactly as the shield's
// SH_ShieldToggle does, so the flag stays predicted rather than waiting a round
// trip before the player can move again.  Returns TRUE if the take started.
float(float now) SH_DodMortarTryStance =
{
    // RISING EDGE — see SH_StanceAltEdge in sh_weapons.qc.  Without it a held
    // +attack2 re-toggles the instant the take ends, so the tube plants and
    // immediately picks itself back up.  Called by BOTH the SSQC alt-fire and the
    // CSQC predictor, and the release half is wired at .altrelease / the else arm.
    if (!SH_StanceAltEdge(TRUE)) return FALSE;

    if (Weapon_LowerBlocksFire()) return FALSE;
    // YOU HAVE TO BE CROUCHED TO SET IT DOWN.  A mortar is emplaced on the ground
    // by a kneeling crew, and the baseplate thump in the plant take is authored
    // for it.  Both sides read the same replicated FL_DUCKING (proxied as part of
    // .flags and re-derived by replay from the buffered DUCK bit), so this gate is
    // prediction-exact with no divergence window and needs no wire work.
    //
    // The !wep_deployed guard is load-bearing: standing back UP must never require
    // a crouch, or a player who somehow stood while emplaced is trapped forever.
    if (!self.wep_deployed
        && !((self.flags & FL_DUCKING) && (self.flags & FL_ONGROUND)))
        return FALSE;
    // Not mid-draw, mid-fire, mid-load or already changing stance: planting a
    // mortar takes both hands and every one of those states is using them.
    if (self.weaponstate != WS_IDLE) return FALSE;
    if (now < self.attack_finished)  return FALSE;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SH_DodMortarStanceDuration(self.wep_deployed,
                                                            self.mag_dodmortar);
    return TRUE;
};

float(float now) SH_DodMortarTickState =
{
    // WS_SPECIAL is the plant/lift take.  Handled before the standard driver
    // because that driver has no arm for it and would fall through returning 0,
    // leaving the player emplaced in an animation that never ends.
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodMortarStanceDuration(self.wep_deployed, self.mag_dodmortar))
        {
            self.wep_deployed = !self.wep_deployed;
            SH_WeaponEnterIdle();

            // PREPARE THE TUBE.  A planted mortar with a bomb still in the bag
            // has to bring it UP to the muzzle before it can be dropped in, and
            // round_up is that take — it is the only thing in the model that ends
            // on idle_ready (round_up[end] -> idle_ready measures 0.000u/0.00deg,
            // and idle_ready -> fire[0] is 0.000u too, so the three join up).
            //
            // Without this the plant retired straight to WS_IDLE, the idle picker
            // saw mag > 0 and handed back idle_ready, and the bomb APPEARED in the
            // gunner's hand in one frame: "doesn't do prepare mortar animation
            // (round_up), just jumps to the hand above the barrel".
            //
            // Reuses WS_RELOAD rather than inventing a state: the load take, the
            // load sound at DODMORTAR_RELOAD_F_LOAD, the fire block and the
            // display arm all already exist for it, and SH_StandardTickState's
            // top-up is a no-op on a full one-round magazine (needed == 0).
            //
            // The EMPTY case needs nothing — SH_DodMortarWantsAutoReload polls for
            // exactly this and starts the same take on the next tick.
            if (self.wep_deployed && self.mag_dodmortar > 0)
            {
                self.weaponstate         = WS_RELOAD;
                self.wep_action_id      += 1;
                self.wep_anim_start      = now;
                self.wep_state_dur       = SH_DodMortarReloadDuration();
                self.attack_finished     = now + self.wep_state_dur;
                self.dodmortar_snd_stage = 0;
#ifdef SSQC
                self.weaponframe   = SH_DodMortarSeqReload();
                self.wep_nextframe = now + DODMORTAR_FRAME_INTERVAL;
#endif
                // RETURN 0, NOT 1 — bit 0 means "went idle", and we did not: we
                // went to WS_RELOAD.  Claiming the idle bricked the weapon
                // outright, and this is the "unmounting is impossible ... and
                // nothing fires from the gun" report.  W_DodMortarFrame's
                // `if (result & 1)` arm retires the frame function whenever the
                // magazine is non-empty, so the prepare take stopped being
                // ticked on the very frame it started: SH_DodMortarTickState was
                // never called again, WS_RELOAD never retired, and the server sat
                // in it forever.  SH_DodMortarTryStance refuses on
                // `weaponstate != WS_IDLE` and SH_StandardTryFireSemiAuto refuses
                // during a reload, so BOTH buttons went dead after the first
                // plant — and the tube always plants loaded, so it was every time.
                //
                // The client kept its own copy ticking (CSQC_PredictDodMortarCommand
                // calls the tick unconditionally, with no wep_nextframe gate), so it
                // predicted the stand-up and the shot and reconcile yanked both back
                // — which is why it read as "nothing happens" rather than as a freeze.
                return 0;
            }
            return 1;
        }
        return 0;
    }

    float rel = SH_DodMortarReloadDuration();
    float r   = SH_StandardTickState(now, mag_dodmortar, ammo_dodmortar, MAX_MAG_DODMORTAR,
                                     SH_DodMortarDrawDuration(), SH_DodMortarFireDuration(),
                                     rel, rel * DODMORTAR_RELOAD_F_LOAD);

    // BOTH SIDES, not #ifdef SSQC — see the long note in sh_wpn_dodat.qc.  The
    // server owning the only copy of WS_RELOAD meant the tube reloaded with no
    // animation at all: reconcile stopped writing fire-decision state back
    // (client/cl_player.qc:1022) and sv_confirmed_weaponstate is written and
    // never read, so CSQC_DodMortarDisplayFrame never saw the reload and held
    // the idle pose through the whole 2.5 s while the round appeared by itself.
    if (SH_DodMortarWantsAutoReload(now) && SH_DodMortarTryReload(now))
    {
#ifdef SSQC
        self.weaponframe         = SH_DodMortarSeqReload();
        self.wep_nextframe       = now + DODMORTAR_FRAME_INTERVAL;
        self.dodmortar_snd_stage = 0;
#endif
        r = r & ~1;
    }
    return r;
};

// Semi-auto: with one bomb in the tube, a held trigger through the reload would
// otherwise fire again the instant it finished, which is not a decision.
float(float now) SH_DodMortarTryFire =
{
    // You cannot fire a mortar off your shoulder.  Returns 0 (not -1) so the
    // standing player gets no dry-fire click and no animation for an action that
    // is not going to happen — the same "do not animate a no-op" rule the medkit
    // and the tripmine follow.  The bomb is still in the tube; +attack2 plants it
    // and then it fires.
    if (!self.wep_deployed) return 0;
    return SH_StandardTryFireSemiAuto(now, mag_dodmortar, DODMORTAR_FIRE_DELAY, DODMORTAR_DRYFIRE_DELAY);
};

float(float now) SH_DodMortarTryReload =
{
    if (!self.wep_deployed) return 0;
    return SH_StandardTryReload(now, mag_dodmortar, ammo_dodmortar, MAX_MAG_DODMORTAR,
        SH_DodMortarReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodMortarPickupCopy =
{
    player.mag_dodmortar  = self.mag_dodmortar;
    player.ammo_dodmortar = self.ammo_dodmortar;
};

void() W_DodMortarExplode =
{
    te_explosion(self.origin + '0 0 8');

    W_RadiusExplode(self.origin, DODMORTAR_RADIUS,
                    DODMORTAR_DAMAGE, DODMORTAR_MIN_DAMAGE,
                    DODMORTAR_KNOCKBACK_PUSH, DODMORTAR_KNOCKBACK_UPLIFT, self.owner);

    remove(self);
};

void() W_DodMortarBombTouch =
{
    if (other == self.owner)
        return;
    W_DodMortarExplode();
};

void() W_DodMortarBombThink =
{
    // Pulse SendFlags so cl_tosssmooth.qc gets a fresh sample each tick.
    self.SendFlags |= 1;
    // Inert for rendering — DodAT_SendEntity does not transmit angles — but kept
    // correct for any server-side reader, and routed through the shared helper so
    // it cannot drift from the client's copy again.
    self.angles = Projectile_FlightAngles(self.proj_type, self.velocity);
    self.nextthink = time + Toss_NextThinkInterval();
};

// MOVETYPE_TOSS — not FLYMISSILE, and not BOUNCEMISSILE.
//
// It must detonate on contact rather than bounce, which rules out BOUNCEMISSILE.
// FLYMISSILE is the trap, and this weapon fell straight into it: sv_phys.c:1399
// EXCLUDES MOVETYPE_FLYMISSILE from WPhys_AddGravity, so .gravity is never read
// for it.  The bomb flew a perfectly straight 45-degree line — "it should be
// arched, not fly straight" — while the CSQC extrapolator curved it downward
// between samples (cl_tosssmooth.qc:145 applies Projectile_TypeGravity) and every
// new server sample yanked it back up, so it stuttered as well as flying flat.
//
// TOSS is the arcing pattern already used in this tree (sh_wpn_opsporelauncher.qc:379,
// sh_wpn_hlsmg.qc:405) and it makes .gravity live, so server and client finally
// integrate the same curve.  Contact detonation still holds: WPhys_PushEntity
// calls WPhys_Impact for any trace.ent including the world edict
// (sv_phys.c:684), and the post-impact bounce/stop tail is skipped once the touch
// has remove()d us (the ED_ISFREE test at sv_phys.c:1438).
//
// One real behavioural delta: MOVE_MISSILE is added to the traceflags only for
// FLYMISSILE (WPhys_PushEntity:618), and that governs the ENTITY clip pass
// (world.c:2907) — so the bomb loses a de-facto +/-15 proximity fuse against
// players and monsters and must now intersect their actual bbox.  Brush contact
// is unchanged.  Against DODMORTAR_RADIUS 340 this is not material.
//
// Only after this does DODMORTAR_MIN_ELEVATION mean what its comment says: 45
// degrees is the maximum-range BALLISTIC angle, and until now there was no
// ballistic arc for it to be the maximum of.
//
// THE BOMB LEAVES THE TUBE, NOT THE CROSSHAIR.  This used to launch straight
// along v_angle, which is what "this gun fires forwards when clearly based on
// how he holds it, the mortar should be like an upwards lob" was describing:
// aim at the horizon and a 900-unit-per-second bomb with full gravity left
// horizontally and buried itself in the floor a short way ahead.  A mortar is
// not a rifle — the bomb leaves a tube that points steeply up, and the gunner
// elevates to pick RANGE.
//
// So the launch pitch is the VIEW pitch clamped to at least
// DODMORTAR_MIN_ELEVATION above horizontal.  Yaw is untouched, so aiming still
// aims; look level (or down) and you get the flattest lob the tube allows,
// which is also the LONGEST, because 45 degrees is the maximum-range angle for
// a ballistic shot — the same reason the real weapon's range tables run
// downwards from there.  Looking further up shortens it.  At DODMORTAR_SPEED
// against the default gravity that is a band of roughly 1000 units at the
// minimum elevation down to about 350 at 80 degrees.
//
// The MUZZLE still comes off the view vectors.  The bomb has to appear where
// the player is standing, and spawning it 18 units along a 45-degree ray would
// push it into the ceiling of any room that has one.
void() W_DodMortarLaunch =
{
    makevectors(self.v_angle);
    vector muzzle = self.origin + self.view_ofs
                    + v_forward * 18 + v_right * 2 + v_up * 2;

    vector launch_ang = self.v_angle;
    // QC pitch is POSITIVE DOWN, so elevating is a subtraction and the floor on
    // elevation is a ceiling on the number.
    if (launch_ang_x > -DODMORTAR_MIN_ELEVATION)
        launch_ang_x = -DODMORTAR_MIN_ELEVATION;
    launch_ang_z = 0;   // roll steers nothing; it would only tilt v_right
    makevectors(launch_ang);

    entity bomb = spawn();
    bomb.owner        = self;
    bomb.classname    = "dod_mortar_bomb";
    bomb.movetype     = MOVETYPE_TOSS;   // NOT FLYMISSILE — see above, it gets no gravity
    bomb.solid        = SOLID_BBOX;
    bomb.proj_type    = PROJ_TYPE_DOD_MORTAR;
    bomb.gravity      = Projectile_TypeGravity(bomb.proj_type);
    setmodel(bomb, Projectile_TypeModel(bomb.proj_type));
    setsize(bomb, '0 0 0', '0 0 0');
    setorigin(bomb, muzzle);

    bomb.velocity = v_forward * DODMORTAR_SPEED
                  + v_forward * (self.velocity * v_forward);
    bomb.angles   = Projectile_FlightAngles(bomb.proj_type, bomb.velocity);

    bomb.touch      = W_DodMortarBombTouch;
    bomb.SendEntity = DodAT_SendEntity;   // shooter sees the REAL bomb — see sh_wpn_dodat.qc
    bomb.SendFlags  = 1;
    bomb.think      = W_DodMortarBombThink;
    bomb.nextthink  = time + Toss_NextThinkInterval();
};

void() W_DodMortarFire =
{
    float r = SH_DodMortarTryFire(time);

    if (r == 1)
    {
        self.weaponframe         = SH_DodMortarSeqFire();
        self.wep_nextframe       = time + DODMORTAR_FRAME_INTERVAL;
        self.dodmortar_snd_stage = 0;
        // The bomb is NOT spawned here — it leaves at frac 0.5 of the take.
        // W_DodMortarFrame does it.  See the header.
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodMortarReload =
{
    if (SH_DodMortarTryReload(time))
    {
        self.weaponframe         = SH_DodMortarSeqReload();
        self.wep_nextframe       = time + DODMORTAR_FRAME_INTERVAL;
        self.dodmortar_snd_stage = 0;
    }
};

// The button-up half of the rising-edge latch.  sv_weapons.qc calls .altrelease on
// EVERY frame the button is up, which is exactly what is needed to clear it.
void() W_DodMortarAltRelease =
{
    SH_StanceAltEdge(FALSE);
};

// +attack2 — plant the tube, or pick it back up.
void() W_DodMortarAltFire =
{
    if (SH_DodMortarTryStance(time))
    {
        self.weaponframe         = SH_DodMortarSeqStance(self.wep_deployed,
                                                         self.mag_dodmortar);
        self.wep_nextframe       = time + DODMORTAR_FRAME_INTERVAL;
        self.dodmortar_snd_stage = 0;
    }
};

// SECOND ENTRY POINT: weapon-special (impulse 7) does the same thing as +attack2.
// Reported as "none of the machine guns up_to_down work? I try weapon special and
// nothing?" — and it was literally nothing: the five deployables bound only
// .altfire, so impulse 7 reached W_CheckImpulses, found .special unset and
// returned.  Every OTHER deployable in the tree (Bren, both FG42s) is on impulse 7
// because +attack2 is taken on those, so "weapon special deploys" is the rule the
// player had already learned.  Both buttons work now on all six.
void() W_DodMortarSpecial =
{
    SH_StanceAltArmForImpulse();
    W_DodMortarAltFire();
};

void() W_DodMortarFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODMORTAR_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        // The model gives the draw no event of its own; the tube coming up onto
        // the shoulder gets the standard select click so it is not silent.
        if (elapsed >= SH_DodMortarDrawDuration() * 0.05 && self.dodmortar_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodmortar_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        float fd = SH_DodMortarFireDuration();
        if (elapsed >= fd * DODMORTAR_FIRE_F_LOAD && self.dodmortar_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/mortar_load.wav", 1, ATTN_NORM);
            self.dodmortar_snd_stage = 1;
        }
        if (elapsed >= fd * DODMORTAR_FIRE_F_LAUNCH && self.dodmortar_snd_stage < 2)
        {
            self.dodmortar_snd_stage = 2;
            sound(self, CHAN_WEAPON, "weapons/mortar_shoot.wav", 1, ATTN_NORM);
            W_DodMortarLaunch();
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SH_DodMortarReloadDuration() * DODMORTAR_RELOAD_F_LOAD
            && self.dodmortar_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/mortar_load.wav", 1, ATTN_NORM);
            self.dodmortar_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        // The baseplate hitting the ground, on the plant only — picking the tube
        // back up is a lift, not an impact.
        if (!self.wep_deployed
            && elapsed >= SH_DodMortarPlantDuration() * DODMORTAR_PLANT_F_THUMP
            && self.dodmortar_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/mortar_load.wav", 1, ATTN_NORM);
            self.dodmortar_snd_stage = 1;
        }
    }

    float result = SH_DodMortarTickState(time);
    if (result & 1)
    {
        self.weaponframe         = SH_DodMortarIdleFor(self.wep_deployed, self.mag_dodmortar);
        self.dodmortar_snd_stage = 0;
        // Retire only when there is nothing left to poll for — the auto-reload
        // above lives inside the tick, and this function is the only thing that
        // calls it server-side.  See the same note in sh_wpn_dodat.qc.  A tube
        // that is not planted has nothing to load either, so it can retire too.
        if (self.mag_dodmortar > 0 || !self.wep_deployed)
            self.wep_nextframe = 0;
    }
};

void() W_DodMortarEquip =
{
    W_SetADSProfile(FALSE, "", SCOPE_CLASS_NONE);   // no iron sights on a mortar
    W_StandardEquipSetup(DODMORTAR_VIEWMODEL, DODMORTAR_DISPLAY_NAME, SH_DodMortarSeqDraw(),
        DODMORTAR_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodMortarFire;
    self.reload   = W_DodMortarReload;
    self.wepframe = W_DodMortarFrame;
    self.altfire    = W_DodMortarAltFire;      // plant / pick up
    self.altrelease = W_DodMortarAltRelease;   // clears the rising-edge latch
    self.special    = W_DodMortarSpecial;      // impulse 7 does the same thing
    self.wep_stance_alt_held = 0;
    self.shoot    = __NULL__;      // no hitscan — the bomb IS the shot
    self.dodmortar_snd_stage = 0;
    // ALWAYS COMES OUT STANDING.  The draw take starts and ends on the shouldered
    // pose, so a mortar that remembered being planted would draw into a stance
    // its own animation does not depict — and, worse, would hand the player a
    // movement lock they did not ask for on a weapon switch.  Switching away is
    // therefore the third way to stand up, alongside +attack2 and dying.
    self.wep_deployed = 0;
    self.weapon_deployable = TRUE;   // arms the shared SH_DeploySpeedFactor lock
    // THE ONLY WEAPON THAT SETS THIS.  A mortar is served from a kneel — see
    // weapon_deploy_crouched in sh_weapons.qc for why the four bipod guns
    // deliberately do not.
    self.weapon_deploy_crouched = TRUE;
    W_SetCrosshairProfile(0.02, 0.06, 300, 1.4, FALSE);
};

void() W_DodMortarDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodmortar  = self.mag_dodmortar;
    tgt.ammo_dodmortar = self.ammo_dodmortar;

    self.mag_dodmortar  = 0;
    self.ammo_dodmortar = 0;

    setmodel(tgt, DODMORTAR_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_mortar";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODMORTAR;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodMortarEquip;
    tgt.weap_drop_func = W_DodMortarDrop;
    tgt.pickupcopy     = W_DodMortarPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_mortar =
{
    setmodel(self, DODMORTAR_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_mortar";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODMORTAR;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodMortarEquip;
    self.weap_drop_func = W_DodMortarDrop;
    self.pickupcopy     = W_DodMortarPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodmortar  = MAX_MAG_DODMORTAR;
    self.ammo_dodmortar = MAX_AMMO_DODMORTAR;
    W_RegisterMapWeapon(weapon_mortar);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodmortar_snd_stage;
float csqc_dodmortar_snd_action;

void() CSQC_PredictDodMortarCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodmortar_snd_action)
    {
        csqc_dodmortar_snd_action = predicted_player.wep_action_id;
        csqc_dodmortar_snd_stage  = 0;
    }

    // +attack2 — plant the tube or pick it back up.  Predicted on both sides so
    // the movement lock lifts the instant the take ends rather than a round trip
    // later; SH_DodMortarTickState flips the flag identically here and on the
    // server, and the proxy reconciles it if they ever disagree.
    if (input_buttons & 4)
    {
        if (SH_DodMortarTryStance(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_dodmortar_snd_stage  = 0;
            csqc_dodmortar_snd_action = predicted_player.wep_action_id;
        }
    }
    else
    {
        // The clearing half of the rising-edge latch, mirroring the server's
        // .altrelease.  Both sides must run it every frame the button is up or the
        // toggle can never re-arm.
        SH_StanceAltEdge(FALSE);
    }

    if (input_buttons & 1)
    {
        r = SH_DodMortarTryFire(csqc_pred_time);
        if (r == 1)
        {
            // The magazine and the animation are predicted; the BOMB is not — it
            // is a slow, high-arc projectile fired at things far away, where a
            // round trip is imperceptible and a client-side fake that drifted
            // from the real one would be very visible.  Same call as the AT
            // launchers.  So this branch marks the ack and stops.
            CSQC_MarkPendingWeaponAck();
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_dodmortar_snd_stage < 1
                && elapsed >= SH_DodMortarDrawDuration() * 0.05)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmortar_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_FIRE)
        {
            float fd = SH_DodMortarFireDuration();
            if (csqc_dodmortar_snd_stage < 1 && elapsed >= fd * DODMORTAR_FIRE_F_LOAD)
            {
                localsound("weapons/mortar_load.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmortar_snd_stage = 1;
            }
            if (csqc_dodmortar_snd_stage < 2 && elapsed >= fd * DODMORTAR_FIRE_F_LAUNCH)
            {
                localsound("weapons/mortar_shoot.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_MuzzleFlashAtMuzzle(DODMORTAR_MUZZLE_FORWARD, DODMORTAR_MUZZLE_RIGHT,
                    DODMORTAR_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODMORTAR_MUZZLE_FORWARD, DODMORTAR_MUZZLE_RIGHT,
                    DODMORTAR_MUZZLE_DOWN, self.wep_action_id, 5);
                csqc_dodmortar_snd_stage = 2;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_dodmortar_snd_stage < 1
                && elapsed >= SH_DodMortarReloadDuration() * DODMORTAR_RELOAD_F_LOAD)
            {
                localsound("weapons/mortar_load.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmortar_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_SPECIAL)
        {
            if (!self.wep_deployed
                && csqc_dodmortar_snd_stage < 1
                && elapsed >= SH_DodMortarPlantDuration() * DODMORTAR_PLANT_F_THUMP)
            {
                localsound("weapons/mortar_load.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmortar_snd_stage = 1;
            }
            // Packing up: the same handling sample where the bomb clears the
            // muzzle, so stowing the round is audible rather than silent.
            if (self.wep_deployed
                && self.mag_dodmortar > 0
                && csqc_dodmortar_snd_stage < 1
                && elapsed >= SH_DodMortarUnloadDuration() * DODMORTAR_UNLOAD_F_CLEAR)
            {
                localsound("weapons/mortar_load.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodmortar_snd_stage = 1;
            }
        }
    }

    // Mark the ack at the stance FLIP as well as at the press, or reconcile stomps
    // the predicted flip for a full RTT — see the long note at the same place in
    // sh_wpn_dodbar.qc.  It bites hardest here: SH_DodMortarTryFire opens with
    // `if (!self.wep_deployed) return 0`, so +attack in that window did nothing at
    // all on the client.
    float mor_pre_dep = self.wep_deployed;
    SH_DodMortarTickState(csqc_pred_time);
    if (self.wep_deployed != mor_pre_dep)
        CSQC_MarkPendingWeaponAck();
};

// Weapon-special (impulse 7), the second entry point to the stance toggle.  Must
// be on the hand-written else-if chain under WEAPON_IMPULSE_SPECIAL in
// client/cl_weapons.qc or the plant happens server-side and the viewmodel never
// moves — see W_DodMortarSpecial and [[impulse7-dispatch-is-a-hand-list]].
void() CSQC_PredictDodMortarSpecial =
{
    SH_StanceAltArmForImpulse();
    if (SH_DodMortarTryStance(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        csqc_dodmortar_snd_stage  = 0;
        csqc_dodmortar_snd_action = predicted_player.wep_action_id;
    }
};

void() CSQC_PredictDodMortarReload =
{
    if (SH_DodMortarTryReload(csqc_pred_time))
    {
        csqc_dodmortar_snd_stage  = 0;
        csqc_dodmortar_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodMortarDisplayFrame =
{
    // Both halves of the pair go to SH_SeqIdleDisplay, so the fidget roll cannot
    // hand back the empty-handed pose while a bomb is being held (or the other
    // way round).  It re-reads seq_a on the non-idle -> idle EDGE, which is
    // exactly when the magazine has just changed — fire ends empty, the reload
    // ends loaded — so the pose is always the current one.
    float pose = SH_DodMortarIdleFor(predicted_player.wep_deployed,
                                     predicted_player.mag_dodmortar);

    // The stance is folded into the latch key — see the note at the same call in
    // sh_wpn_dodbar.qc.
    float idle = SH_SeqIdleDisplay(cltime,
                                   WEP_DODMORTAR + (predicted_player.wep_deployed ? 4096 : 0),
                                   predicted_player.weaponstate,
                                   pose, pose,
                                   DODMORTAR_IDLE_REARM_MIN, DODMORTAR_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodMortarSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodMortarSeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodMortarSeqFire();
    // WS_SPECIAL is the stance change.  The flag has NOT flipped yet — it flips
    // when the take ends — so the take that belongs here is the one leaving the
    // current stance.
    //
    // BOTH ARMS DRIVE THE SEQUENCE TIME EXPLICITLY AND CLAMP IT.  The elapsed the
    // dispatcher hands us is `cltime - wep_anim_start`, and cltime runs ahead of
    // the last predicted tick, so for a render frame or two after the take should
    // have ended it keeps counting past the end.  On a take FTE reads as looping
    // that wraps frame2 back to frame 0 and lerps toward the pose at the far end —
    // a one-frame flash of the wrong stance.  min() against the take's own length
    // makes that unreachable regardless of what the model's flags say.
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        csqc_viewmodel_sequence_time_override = TRUE;

        if (!predicted_player.wep_deployed)
        {
            csqc_viewmodel_sequence_time = min(elapsed, SH_DodMortarPlantDuration());
            return SH_DodMortarSeqPlant();
        }

        // Packing up is round_down (only with a bomb in hand) and then the live
        // part of down_to_up — see DODMORTAR_LIFT_F_LIVE and DODMORTAR_UNLOAD_F_CLEAR.
        float ud = (predicted_player.mag_dodmortar > 0) ? SH_DodMortarUnloadDuration() : 0;
        if (elapsed < ud)
        {
            csqc_viewmodel_sequence_time = elapsed;
            return SH_DodMortarSeqUnload();
        }
        csqc_viewmodel_sequence_time = min(elapsed - ud, SH_DodMortarLiftDuration());
        return SH_DodMortarSeqLift();
    }

    return pose;
};

void() CSQC_DodMortarDropClear =
{
    self.mag_dodmortar  = 0;
    self.ammo_dodmortar = 0;
};

void() CSQC_DodMortarEquip =
{
    W_SetADSProfile(FALSE, "", SCOPE_CLASS_NONE);
    self.weapon_name         = DODMORTAR_DISPLAY_NAME;
    self.weapon_viewmodel    = DODMORTAR_VIEWMODEL;
    self.weapon_worldmodel   = DODMORTAR_WORLDMODEL;
    self.weapon_deploy_sound = DODMORTAR_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodMortarCommand;
    self.csqc_predict_reload = CSQC_PredictDodMortarReload;
    self.csqc_display_frame  = CSQC_DodMortarDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodMortarDropClear;
    self.weapon_uses_sequences = TRUE;
    // Arms the shared movement lock on the client's copy too — CSQC runs
    // Weapon_SpeedFactor_Smooth in its own pmove, so an unset flag here would
    // predict the player walking while the server held them planted.
    //
    // NOT accompanied by a wep_deployed reset: CSQC_WeaponEquip re-runs on every
    // reconcile (client/cl_player.qc:1051), so zeroing the stance here would
    // unplant the mortar 20 times a second.  The SERVER's W_DodMortarEquip is the
    // one that clears it, on a real weapon switch, and the proxy carries that
    // across.  Same reason csqc_dodmortar_snd_stage is not reset here.
    self.weapon_deployable = TRUE;
    // Both VMs run PM_PlayerMoveStep, so the held crouch has to be armed on both
    // or the client predicts a standing player against a kneeling server.
    self.weapon_deploy_crouched = TRUE;
};

#endif // CSQC
