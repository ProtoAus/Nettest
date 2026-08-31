// ============================================================
//  shared/weapons/sh_wpn_opbgrapple.qc  -  Opposing Force Barnacle Grapple
//
//  Slot  : SLOT_PRIMARY
//  Stats : none.  No ammo, no magazine, no reload - the WEP_GRAVITYGUN shape.
//  Fire  : +attack  — launch the tongue.  Pressing again releases it.
//          +attack2 — release.
//
//  15 placements (12 gearbox, 3 pizza_ya_san2).
//
//  THIS FILE IS A SHELL, AND DELIBERATELY SO.  The mod already ships a complete
//  grapple - server/sv_grapple.qc plus client/cl_rope.qc, with a gravity-affected
//  hook, anchor-on-contact, a rope-aligned velocity pull that preserves
//  perpendicular velocity (so you swing rather than being winched), a
//  ground-stick breaker, looping audio, a CSQC-rendered rope visible to
//  everyone, prediction-proxy integration and nine tuning cvars.  All of that
//  was written for the legacy `impulse 9` binding.  Rewriting any of it for a
//  weapon would have been the second implementation of something already good.
//
//  So the weapon calls W_GrappleEngage() and W_GrappleRelease() and does nothing
//  else.  Three details make that safe, and all three were checked rather than
//  assumed:
//
//    * The `sv_grappling` cvar gate (default 0) lives in W_GrappleImpulse and
//      W_GrappleHeldTick - the BUTTON paths - and NOT in W_GrappleEngage.  So
//      carrying the weapon works regardless of the cvar, and the legacy binding
//      keeps its own gate untouched.
//    * W_GrapplePullTick is driven unconditionally from PlayerPreThink
//      (sv_player.qc:1149) and is likewise ungated, so a weapon-fired hook is
//      pulled by exactly the same code as a button-fired one.
//    * Weapon_LowerBlocksFire() returns TRUE whenever grapple_rope_active, which
//      is correct for every OTHER weapon (both hands are on the rope) and fatal
//      here - the grapple could never fire its own tongue.  This weapon
//      therefore omits that one check, on purpose.
//
//  HONEST GAP: Opposing Force's tongue also grabs monsters and drags them to
//  you.  sv_grapple.qc only ever moves the PLAYER, and making it move the target
//  instead needs a second code path and a mass heuristic.  Not done.  Attaching
//  to a monster works; it just reels you to the monster rather than the reverse.
//
//  SECOND GAP: the pull is a velocity servo along a straight line to a fixed
//  anchor, not a length-constrained pendulum, so you cannot swing PAST the
//  anchor and be caught by the rope going taut.  You can arc under gravity while
//  being reeled in, which is most of the feel.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Sequence indices, read out of v_bgrap.mdl (11 sequences) -------------
const float BGRAP_SEQ_BREATHE     = 0;   // breathe,      2.567 s, looping
const float BGRAP_SEQ_LONGIDLE    = 1;   // longidle,    10.000 s
const float BGRAP_SEQ_SHORTIDLE   = 2;   // shortidle,    1.333 s
const float BGRAP_SEQ_COUGH       = 3;   // cough,        4.600 s
const float BGRAP_SEQ_DOWN        = 4;   // down,         1.333 s
const float BGRAP_SEQ_UP          = 5;   // up,           1.000 s
const float BGRAP_SEQ_FIRE        = 6;   // fire,         0.600 s, looping
const float BGRAP_SEQ_FIREWAITING = 7;   // firewaiting,  0.533 s, looping
const float BGRAP_SEQ_FIREREACHED = 8;   // firereached,  4.667 s, looping
const float BGRAP_SEQ_FIRETRAVEL  = 9;   // firetravel,   0.667 s, looping
const float BGRAP_SEQ_FIRERELEASE = 10;  // firerelease,  1.000 s, looping

const float BGRAP_FRAME_INTERVAL = 0.05;
const float BGRAP_DRAW_DURATION  = 1.0;
const float BGRAP_FIRE_DURATION  = 0.6;
const float BGRAP_FIRE_DELAY     = 0.5;

const string BGRAP_VIEWMODEL     = "models/v_bgrap.mdl";
const string BGRAP_WORLDMODEL    = "models/w_bgrap.mdl";
const string BGRAP_DISPLAY_NAME  = "BARNACLE GRAPPLE";
const string BGRAP_DEPLOY_SOUND  = "weapons/bgrapple_cough.wav";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_BGrapTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= BGRAP_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= BGRAP_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// Press edge for +attack, shared so the client can run the identical test — see
// the long note beside W_BGrapFire for why a level-triggered toggle is wrong
// here.  The field used to live inside #ifdef SSQC.
.float bgrap_fire_held;

float(float now) SH_BGrapTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    // NO Weapon_LowerBlocksFire() here.  See the header: it is TRUE for exactly
    // as long as this weapon's own rope is out, so including it would make the
    // grapple the one weapon that can never be fired twice.
    if (self.weaponstate != WS_IDLE && self.weaponstate != WS_FIRE) return 0;
    if (now < self.attack_finished) return 0;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + BGRAP_FIRE_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// server/sv_grapple.qc compiles at position 236, after the weapon files, so both
// are reached forward.
void()             W_GrappleEngage;
void(entity player) W_GrappleRelease;

void(entity player) W_BGrapPickupCopy = { };   // nothing to carry

// Edge latch for +attack.  W_WeaponFrame calls self.fire() on EVERY frame the
// button is held (sv_weapons.qc:3801-3806) - SH_BGrapTryFire's 0.5 s
// attack_finished is a RATE limit, not an edge detector - so a level-triggered
// toggle fired the tongue, released it half a second later, fired again, for as
// long as the button was down.  The legacy binding this weapon deliberately
// mirrors is impulse-driven and therefore edge-triggered by construction
// (W_GrappleImpulse, sv_grapple.qc:186); this restores that.
//
// NOT reusing .pm_grapple_held_last: W_GrappleHeldTick owns that latch for the
// PM_BTN_GRAPPLE bind and zeroes it on every tick that sv_grappling is 0 -
// which is the default - so sharing it would let the two paths eat each other's
// edges.
//
// MOVED OUT OF #ifdef SSQC — the client predicts the same press edge now, see
// CSQC_PredictBGrapCommand.

void() W_BGrapReleaseTongue =
{
    W_GrappleRelease(self);
    self.weaponstate    = WS_FIRE;
    self.weaponframe    = BGRAP_SEQ_FIRERELEASE;
    // Restart the animation clock.  SH_BGrapTickState has been frozen at
    // WS_FIRE for the entire time the rope was out (the grapple_hook branch of
    // W_BGrapFrame returns before it can run), so without this it sees a
    // long-elapsed FIRE on its very next tick and drops straight back to
    // breathe - clipping the release animation to one frame.
    self.wep_anim_start = time;
    self.wep_nextframe  = time + BGRAP_FRAME_INTERVAL;
    sound(self, CHAN_WEAPON, "weapons/bgrapple_release.wav", 1, ATTN_NORM);
};

void() W_BGrapFire =
{
    if (self.bgrap_fire_held) return;      // still the same press
    if (!SH_BGrapTryFire(time)) return;
    self.bgrap_fire_held = TRUE;

    // Press-to-fire, press-again-to-release, matching the legacy binding's
    // toggle so the two entry points behave the same way.
    if (self.grapple_hook)
    {
        W_BGrapReleaseTongue();
        return;
    }

    W_GrappleEngage();
    self.weaponframe   = BGRAP_SEQ_FIRE;
    self.wep_nextframe = time + BGRAP_FRAME_INTERVAL;
    sound(self, CHAN_WEAPON, "weapons/bgrapple_fire.wav", 1, ATTN_NORM);
};

void() W_BGrapAltFire =
{
    if (!self.grapple_hook) return;
    W_BGrapReleaseTongue();
};

void() W_BGrapFrame =
{
    // Keep ticking for as long as the weapon is equipped.  sv_weapons.qc:3820
    // only calls wepframe while wep_nextframe > 0, so the `= 0` this file
    // stored in every one of its five exit paths retired the frame function
    // permanently after a single tick: weaponstate stuck at WS_FIRE, and the
    // four rope sequences below unreachable, because THIS FUNCTION is the only
    // thing that ever selects them.
    //
    // Unlike the gravity gun (sh_wpn_gravitygun.qc:141) there is no safe point
    // to retire at.  The rope is a background state that outlives the fire
    // animation and has to be re-read every tick, so this runs at 20 Hz for as
    // long as the grapple is out - and it has to keep running while idle too,
    // or the latch below never clears.
    self.wep_nextframe = time + BGRAP_FRAME_INTERVAL;

    // The dispatcher gives +attack no release callback (only altfire has
    // .altrelease), so the falling edge is detected here.
    //
    // Releasing the button now RETRACTS the tongue, which is how Opposing Force
    // plays it and what was asked for -- the press-toggle below stays as the
    // fallback for a press that never sees a matching release (a bind swap
    // mid-hook, an impulse-fired grapple), so nothing can strand a rope.
    if (!self.button0)
    {
        if (self.bgrap_fire_held && self.grapple_hook)
            W_BGrapReleaseTongue();
        self.bgrap_fire_held = FALSE;
    }

    // The model was authored for this exact state machine, so the mapping is
    // one-to-one: in flight, attached-and-travelling, arrived, idle.
    if (self.grapple_hook)
    {
        // Discriminated on SPEED rather than on .grapple_attached, which would
        // read better but cannot be reached from here: that field is declared in
        // shared/sh_pmove.qc at compile position 240, long after the weapon
        // files at 42-66, and QC can forward-declare functions but not fields.
        // Speed is a fair proxy - a hook in flight leaves you standing still,
        // and an attached one is either hauling you or has finished.
        float want;
        if (vlen(self.velocity) > 32)        want = BGRAP_SEQ_FIRETRAVEL;
        else if (self.grapple_hook.velocity != '0 0 0') want = BGRAP_SEQ_FIREWAITING;
        else                                 want = BGRAP_SEQ_FIREREACHED;

        if (self.weaponframe != want)
            self.weaponframe = want;
        return;
    }

    if (SH_BGrapTickState(time) & 1)
        self.weaponframe = BGRAP_SEQ_BREATHE;
};

void() W_BGrapEquip =
{
    W_StandardEquipSetup(BGRAP_VIEWMODEL, BGRAP_DISPLAY_NAME, BGRAP_SEQ_UP,
        BGRAP_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_BGrapFire;
    self.altfire  = W_BGrapAltFire;
    self.reload   = __NULL__;
    self.wepframe = W_BGrapFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    W_SetCrosshairProfile(0, 0, 320, 1.2, TRUE);
};

void() W_BGrapDrop =
{
    entity tgt = weapon_drop_target;

    // Dropping the weapon must not leave a rope attached to a player who no
    // longer has anything to hold it with.
    if (self.grapple_hook)
        W_GrappleRelease(self);

    setmodel(tgt, BGRAP_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_grapple";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_BGRAPPLE;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_BGrapEquip;
    tgt.weap_drop_func = W_BGrapDrop;
    tgt.pickupcopy   = W_BGrapPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_grapple =
{
    precache_model(BGRAP_WORLDMODEL);
    precache_model(BGRAP_VIEWMODEL);

    setmodel(self, BGRAP_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_grapple";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_BGRAPPLE;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_BGrapEquip;
    self.weap_drop_func = W_BGrapDrop;
    self.pickupcopy    = W_BGrapPickupCopy;
    self.touch         = weapon_touch;
    W_RegisterMapWeapon(weapon_grapple);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictBGrapCommand =
{
    // THE HOOK stays server-owned — it is a server entity and its anchor arrives
    // through the prediction proxy, so a predicted launch would only have to be
    // corrected.  THE WEAPON STATE does not, and that was the gap: nothing on
    // this side ever entered WS_FIRE, and a weaponstate only the server sets
    // never reaches predicted_player (reconcile does not write fire-decision
    // state back, client/cl_player.qc:1022).  So CSQC_BGrapDisplayFrame's
    // WS_FIRE arm was unreachable and BGRAP_SEQ_FIRE — the tongue actually
    // launching, and the release take on the second press — never drew at all.
    // The rope arms above it worked, because grapple_rope_active IS proxied.
    //
    // Predict the STATE and nothing else: the same shape the DoD bayonets use.
    // The press edge is the shared .bgrap_fire_held, so the two sides consume
    // the same edge and a held button cannot re-toggle.
    if (input_buttons & 1)
    {
        if (!self.bgrap_fire_held)
        {
            if (SH_BGrapTryFire(csqc_pred_time))
            {
                self.bgrap_fire_held = TRUE;
                CSQC_MarkPendingWeaponAck();
            }
        }
    }
    else
        self.bgrap_fire_held = FALSE;

    SH_BGrapTickState(csqc_pred_time);
};

float(float elapsed) CSQC_BGrapDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return BGRAP_SEQ_UP;
    if (predicted_player.grapple_rope_active)
    {
        if (vlen(predicted_player.velocity) > 32) return BGRAP_SEQ_FIRETRAVEL;
        return BGRAP_SEQ_FIREWAITING;
    }
    if (predicted_player.weaponstate == WS_FIRE)
        return BGRAP_SEQ_FIRE;
    return BGRAP_SEQ_BREATHE;
};

void() CSQC_BGrapDropClear = { };

void() CSQC_BGrapEquip =
{
    self.weapon_name         = BGRAP_DISPLAY_NAME;
    self.weapon_viewmodel    = BGRAP_VIEWMODEL;
    self.weapon_worldmodel   = BGRAP_WORLDMODEL;
    self.weapon_deploy_sound = BGRAP_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictBGrapCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_BGrapDisplayFrame;
    self.csqc_drop_clear     = CSQC_BGrapDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
