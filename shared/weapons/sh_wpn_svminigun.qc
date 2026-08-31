// ============================================================
//  shared/weapons/sh_wpn_svminigun.qc  -  Sven Co-op minigun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 200-round belt, no reload, spin-up before it fires
//  Fire  : lag-compensated hitscan, very high rate, very poor accuracy
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6955 (weapon_minigun, "Minigun"),
//  svencoop/models/v_minigun.mdl, w_minigun.mdl, p_minigunidle.mdl and
//  p_minigunspin.mdl.
//
//  Previously an alias onto WEP_M249 carrying w_minigun.mdl
//  (sv_goldsrc_pickups.qc:381).  The file's own comment there called it "the
//  weakest match of the four", and it was: a belt-fed LMG standing in for a
//  rotary cannon that cannot fire until it has spun up, which is the entire
//  character of the weapon.
//
//  THE MOUNT SHIPS NO MINIGUN SOUNDS AT ALL.  Not one file under
//  svencoop/sound/weapons/ matches minigun.  The SAW's set is borrowed for the
//  fire report and the spin-up is built from the same samples pitched down; this
//  is a SUBSTITUTION and it is called one here rather than passed off as Sven's
//  audio.  If the real set turns up later it is a three-line change.
//
//  TWO p_ MODELS, NO PLAIN ONE.  p_minigunidle.mdl and p_minigunspin.mdl.  The
//  manifest can only carry one, so it carries the idle — a third-person player
//  holding a still minigun is right most of the time, and the spin variant would
//  need a per-state pmodel swap the manifest has no shape for.

// --- Ammo fields ---
// A belt, not a magazine: there is no reload animation in the model and no
// reload sound in the borrowed set, so the whole supply is one pool.
.float ammo_minigun;

// Spin state.
//
// .minigun_spin is DERIVED, never integrated — see SH_MinigunSpinAt.  It used to
// be an accumulator advanced by += dt on both sides, and that could not work:
// the field is not in the client's confirmed-state set (cl_player.qc), so a
// reconcile could not reset it, while CSQC_PredictMinigunCommand re-ran once per
// LIVE input frame AND again for every replayed command on every reconcile.  The
// client's copy therefore ratcheted to 1 almost immediately and stayed there,
// while the server's honest 0.05-per-0.05s pump still needed the full second.
//
// The two gates then disagreed permanently: the client predicted shots the server
// refused, decremented its predicted ammo, and the next snapshot corrected it
// straight back — which is exactly the reported "ammo is 200 and doesn't go down".
//
// Deriving it from a timestamp makes prediction IDEMPOTENT: replaying the same
// command any number of times yields the same spin, because the answer depends
// only on absolute time and a stamp, not on how many times the code ran.  That
// also removes the need to network it at all — both sides derive the same value
// from the same held-trigger history.
.float minigun_spin;          // 0..1, DERIVED each tick; never accumulated
.float minigun_spin_snd;      // one-shot latch for the spin-up sample
.float minigun_hold_start;    // absolute time the trigger went down (0 = not held)
.float minigun_rel_time;      // absolute time it came up (0 = never released)
.float minigun_rel_spin;      // spin value latched at that release

// --- Sequence indices, read out of svencoop/models/v_minigun.mdl (11 seqs) ---
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).
const float MINIGUN_SEQ_IDLE        = 0;   // idle,         6.000 s (31f @ 5)   LOOPING
const float MINIGUN_SEQ_IDLE2       = 1;   // idle2,        6.000 s (31f @ 5)   LOOPING
const float MINIGUN_SEQ_GENTLEIDLE  = 2;   // gentleidle,   6.000 s (31f @ 5)   LOOPING
const float MINIGUN_SEQ_STILLIDLE   = 3;   // stillidle,    6.000 s (31f @ 5)   LOOPING
const float MINIGUN_SEQ_DRAW        = 4;   // draw,         2.000 s (61f @ 30)
const float MINIGUN_SEQ_HOLSTER     = 5;   // holster,      2.000 s (61f @ 30)
const float MINIGUN_SEQ_SPINUP      = 6;   // spinup,       1.000 s (31f @ 30)
const float MINIGUN_SEQ_SPINDOWN    = 7;   // spindown,     2.000 s (61f @ 30)
const float MINIGUN_SEQ_SPINIDLE    = 8;   // spinidle,     0.400 s (13f @ 30)  LOOPING
const float MINIGUN_SEQ_SPINFIRE    = 9;   // spinfire,     0.400 s (13f @ 30)  LOOPING
const float MINIGUN_SEQ_SPINIDLEDN  = 10;  // spinidledown, 2.000 s (61f @ 30)

const float MINIGUN_FRAME_INTERVAL = 0.05;

// Spin.  Holding +attack winds the barrels up over MINIGUN_SPINUP_TIME and only
// then does it fire; letting go winds them back down.  This is the whole weapon
// — a minigun that shoots the instant you click is an LMG with a fat model, and
// that is exactly what the alias gave you.
const float MINIGUN_SPINUP_TIME   = 1.0;    // matches the spinup sequence
const float MINIGUN_SPINDOWN_TIME = 2.0;    // matches spindown

const float MINIGUN_FIRE_DELAY    = 0.05;   // 1200 rpm once it is up to speed
const float MAX_AMMO_MINIGUN      = 200;

// --- Balance ---
// Enormous volume of fire, individually weak rounds, and a cone wide enough that
// it is a suppression weapon rather than a precision one.  Damage per round sits
// below the M249's because the rate is more than double it.
const float MINIGUN_BASE_SPREAD          = 0.06;
const float MINIGUN_MOVE_SPREAD          = 0.10;
const float MINIGUN_FULL_SPREAD_SPEED    = 320;
const float MINIGUN_CLOSE_DAMAGE         = 9;
const float MINIGUN_MIN_DAMAGE           = 5;
const float MINIGUN_DAMAGE_FALLOFF_RANGE = 2560;
const float MINIGUN_KICK_PITCH    = 0.35;
const float MINIGUN_KICK_VARIANCE = 0.5;
const float MINIGUN_KICK_STRENGTH = 1.0;

const float MINIGUN_MUZZLE_FORWARD = 44;
const float MINIGUN_MUZZLE_RIGHT   = 3.0;
const float MINIGUN_MUZZLE_DOWN    = 6.0;

// --- State durations, taken from the sequences themselves ---
const float MINIGUN_DRAW_DURATION = 2.000;
const float MINIGUN_FIRE_DURATION = 0.400;   // spinfire, looping

const string MINIGUN_VIEWMODEL    = "models/v_minigun.mdl";
const string MINIGUN_WORLDMODEL   = "models/w_minigun.mdl";
const string MINIGUN_DEPLOY_SOUND = "";
const string MINIGUN_DISPLAY_NAME = "MINIGUN";

// ============================================================
//  SHARED — spin + state machine
// ============================================================

// What the spin IS at absolute time `now`, given whether the trigger is held.
// Shared so the client's predicted barrels and the server's authoritative ones
// derive the same value from the same numbers.
// Pure function of the stamps — no accumulation, so it is safe to call any number
// of times per frame and during prediction replay.
float(float now, float held) SH_MinigunSpinAt =
{
    if (held)
    {
        if (self.minigun_hold_start <= 0)
            return 0;
        return bound(0, (now - self.minigun_hold_start) / MINIGUN_SPINUP_TIME, 1);
    }
    if (self.minigun_rel_time <= 0)
        return 0;
    return bound(0, self.minigun_rel_spin - (now - self.minigun_rel_time) / MINIGUN_SPINDOWN_TIME, 1);
};

// Move the stamps on a trigger EDGE.  Both branches are guarded so re-running the
// same command leaves them untouched, which is what keeps prediction idempotent.
void(float now, float held) SH_MinigunSpinEdge =
{
    float cur;

    if (held)
    {
        if (self.minigun_hold_start <= 0)
        {
            // Resume from wherever the spin-down had reached rather than from
            // zero, by back-dating the stamp — otherwise feathering the trigger
            // would reset the barrels every tap.
            cur = SH_MinigunSpinAt(now, FALSE);
            self.minigun_hold_start = now - cur * MINIGUN_SPINUP_TIME;
            self.minigun_rel_time   = 0;
        }
    }
    else if (self.minigun_hold_start > 0)
    {
        self.minigun_rel_spin   = SH_MinigunSpinAt(now, TRUE);
        self.minigun_rel_time   = now;
        self.minigun_hold_start = 0;
    }
};

float(float now) SH_MinigunTickState =
{
    // No magazine and no reload, so the standard tick is given a full "magazine"
    // of 1 and an empty reserve: it has nothing to reload into and never enters
    // WS_RELOAD.
    return SH_StandardTickState(now, ammo_minigun, ammo_minigun, MAX_AMMO_MINIGUN,
        MINIGUN_DRAW_DURATION, MINIGUN_FIRE_DURATION, 0, 0);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_MinigunPickupCopy =
{
    player.ammo_minigun = bound(0, player.ammo_minigun + self.ammo_minigun, MAX_AMMO_MINIGUN);
};

void() W_MinigunShoot =
{
    W_PenetratingHitscanShoot(MINIGUN_BASE_SPREAD, MINIGUN_MOVE_SPREAD, MINIGUN_FULL_SPREAD_SPEED,
        MINIGUN_CLOSE_DAMAGE, MINIGUN_MIN_DAMAGE, MINIGUN_DAMAGE_FALLOFF_RANGE, 8, 0.94,
        MINIGUN_KICK_PITCH, MINIGUN_KICK_VARIANCE, MINIGUN_KICK_STRENGTH);
};

// Hand-rolled rather than SH_StandardTryFire — the gate is the SPIN, not a
// magazine.  Because it never calls SH_StandardTryFire it never emits `cmd cs`,
// so it MUST be listed in W_FireIsServerAutonomous (shared/sh_weapons.qc) or the
// server never runs this function at all.  It is; check_serverfire.py enforces
// it.  (An earlier comment here claimed the opposite — that the minigun still
// emitted `cmd cs` "through the normal predicted path" — and that claim is what
// kept the exclusion looking deliberate while the gun did nothing.)
void() W_MinigunFire =
{
    if (Weapon_SprintBlocksFire()) return;
    if (Weapon_LowerBlocksFire()) return;
    if (self.weaponstate == WS_DRAW) return;

    // Derive the spin HERE rather than trusting whatever W_MinigunFrame last
    // left behind.  That coupling was the original deadlock: .minigun_spin was
    // written only by the frame pump, the pump runs only while .wep_nextframe > 0,
    // and the pump retired itself when the gun went idle — so a retired pump could
    // never wind the barrels up, the gate never opened, and every line below it
    // (ammo decrement, fire sound, W_MinigunShoot) was unreachable for the rest of
    // the weapon's life.  Deriving from the stamps removes the dependency
    // entirely; calling it in both places is safe precisely because it is
    // idempotent.
    SH_MinigunSpinEdge(time, self.button0);
    self.minigun_spin = SH_MinigunSpinAt(time, self.button0);

    // The pump still has to be running for the state machine and the sequence
    // walk, just no longer for the spin.
    if (self.wep_nextframe <= 0)
        self.wep_nextframe = time + MINIGUN_FRAME_INTERVAL;

    // Winding up.  Not a dry fire and not a refusal — the trigger IS held, the
    // gun simply is not ready yet.
    if (self.minigun_spin < 1)
    {
        if (!self.minigun_spin_snd)
        {
            self.minigun_spin_snd = 1;
            sound(self, CHAN_WEAPON, "weapons/saw_deploy.wav", 1, ATTN_NORM);
        }
        return;
    }

    if (time < self.attack_finished)
        return;

    if (self.ammo_minigun <= 0)
    {
        self.attack_finished = time + 0.5;
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
        return;
    }

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = time;
    self.attack_finished = time + MINIGUN_FIRE_DELAY;
    self.ammo_minigun    = self.ammo_minigun - 1;

    self.weaponframe   = MINIGUN_SEQ_SPINFIRE;
    self.wep_nextframe = time + MINIGUN_FRAME_INTERVAL;

    W_MinigunShoot();

    sound(self, CHAN_WEAPON, "weapons/saw_fire2.wav", 1, ATTN_NORM);
    W_ShellEffect(SHELL_RIFLE, '10 5 -4', '6 46 36', '240 720 120');
};

void() W_MinigunFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += MINIGUN_FRAME_INTERVAL;

    // Stamp the edge, then DERIVE.  Both halves live here now — W_MinigunFire no
    // longer has to wind anything up, it just reads the value.
    SH_MinigunSpinEdge(time, self.button0);
    self.minigun_spin = SH_MinigunSpinAt(time, self.button0);
    if (!self.button0 && self.minigun_spin <= 0)
        self.minigun_spin_snd = 0;

    float result = SH_MinigunTickState(time);
    if (result & 1)
    {
        // All four idles carry STUDIO_LOOPING, and so do spinidle and spinfire,
        // so whichever is shown can be held safely.
        self.weaponframe = (self.minigun_spin > 0) ? MINIGUN_SEQ_SPINIDLE : MINIGUN_SEQ_IDLE;
    }

    // Retire the frame pump only once the barrels have actually STOPPED and the
    // trigger is up.  Retiring on the idle transition alone (which is what this
    // used to do) froze .minigun_spin at whatever it held: this function is its
    // only writer, so a pump retired mid-spin could never wind it back down, and
    // one retired at rest could never wind it up.  The `result & 1` transition
    // fires once, so this test has to live outside it — otherwise there is no
    // later frame on which the retire could be reconsidered.
    if (self.weaponstate == WS_IDLE && self.minigun_spin <= 0 && !self.button0)
    {
        self.weaponframe   = MINIGUN_SEQ_IDLE;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_MinigunEquip =
{
    W_StandardEquipSetup(MINIGUN_VIEWMODEL, MINIGUN_DISPLAY_NAME, MINIGUN_SEQ_DRAW,
        MINIGUN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_MinigunFire;
    self.reload   = __NULL__;
    self.wepframe = W_MinigunFrame;
    self.shoot    = W_MinigunShoot;
    self.minigun_spin     = 0;
    self.minigun_spin_snd = 0;
    // Clear the STAMPS too, not just the derived value - a leftover
    // .minigun_hold_start would have the barrels reading as fully wound the
    // instant the weapon comes back up.
    self.minigun_hold_start = 0;
    self.minigun_rel_time   = 0;
    self.minigun_rel_spin   = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(MINIGUN_BASE_SPREAD, MINIGUN_MOVE_SPREAD, MINIGUN_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_MinigunDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_minigun  = self.ammo_minigun;
    self.ammo_minigun = 0;
    self.minigun_spin = 0;
    // Clear the STAMPS too, not just the derived value - a leftover
    // .minigun_hold_start would have the barrels reading as fully wound the
    // instant the weapon comes back up.
    self.minigun_hold_start = 0;
    self.minigun_rel_time   = 0;
    self.minigun_rel_spin   = 0;

    setmodel(tgt, MINIGUN_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_minigun";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_MINIGUN;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_MinigunEquip;
    tgt.weap_drop_func = W_MinigunDrop;
    tgt.pickupcopy     = W_MinigunPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_minigun =
{
    setmodel(self, MINIGUN_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_minigun";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_MINIGUN;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_MinigunEquip;
    self.weap_drop_func = W_MinigunDrop;
    self.pickupcopy     = W_MinigunPickupCopy;
    self.touch          = weapon_touch;
    self.ammo_minigun   = MAX_AMMO_MINIGUN;
    W_RegisterMapWeapon(weapon_minigun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictMinigunCommand =
{
    // dt is the length of THIS input frame, not MINIGUN_FRAME_INTERVAL.  The
    // The spin is DERIVED here exactly as it is on the server — no dt, because
    // nothing is being integrated.  An earlier pass charged a fixed 0.05 per
    // predict call, then a corrected pass charged input_timelength; both were
    // still accumulators, and an accumulator cannot survive this call being
    // re-run for every buffered command on every reconcile.  See the note on
    // .minigun_spin at the top of the file.
    float held = (input_buttons & 1);

    SH_MinigunSpinEdge(csqc_pred_time, held);
    self.minigun_spin = SH_MinigunSpinAt(csqc_pred_time, held);

    if (held)
    {

        // Effects only once the barrels are up.  The spin itself is predicted so
        // the viewmodel starts turning on the frame you press, rather than after
        // a round trip.
        if (self.minigun_spin >= 1 && csqc_pred_time >= self.attack_finished
            && self.ammo_minigun > 0)
        {
            self.attack_finished = csqc_pred_time + MINIGUN_FIRE_DELAY;
            self.weaponstate     = WS_FIRE;
            self.wep_action_id  += 1;
            self.wep_anim_start  = csqc_pred_time;
            // Predicted ammo spend.  W_MinigunFire decrements server-side; without
            // the matching decrement here the HUD reads its count straight off
            // predicted_player and shows a magazine that never empties, and the
            // gate two lines up (ammo_minigun > 0) keeps predicting shots after the
            // server has run dry.
            self.ammo_minigun    = self.ammo_minigun - 1;

            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound("weapons/saw_fire2.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(MINIGUN_BASE_SPREAD, MINIGUN_MOVE_SPREAD, MINIGUN_FULL_SPREAD_SPEED,
                    MINIGUN_CLOSE_DAMAGE, MINIGUN_MIN_DAMAGE, MINIGUN_DAMAGE_FALLOFF_RANGE, 8, 0.94,
                    MINIGUN_KICK_PITCH, MINIGUN_KICK_VARIANCE, MINIGUN_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '10 5 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(MINIGUN_MUZZLE_FORWARD, MINIGUN_MUZZLE_RIGHT,
                    MINIGUN_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(MINIGUN_MUZZLE_FORWARD, MINIGUN_MUZZLE_RIGHT,
                    MINIGUN_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
    }

    SH_MinigunTickState(csqc_pred_time);
};

float(float elapsed) CSQC_MinigunDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return MINIGUN_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return MINIGUN_SEQ_SPINFIRE;
    // Spinning but not firing is a state of its own and it is the tell that the
    // gun is ready — showing the still idle here would hide the whole mechanic.
    if (predicted_player.minigun_spin > 0)
        return MINIGUN_SEQ_SPINIDLE;
    return MINIGUN_SEQ_IDLE;
};

void() CSQC_MinigunDropClear =
{
    self.ammo_minigun = 0;
    self.minigun_spin = 0;
    // Clear the STAMPS too, not just the derived value - a leftover
    // .minigun_hold_start would have the barrels reading as fully wound the
    // instant the weapon comes back up.
    self.minigun_hold_start = 0;
    self.minigun_rel_time   = 0;
    self.minigun_rel_spin   = 0;
};

void() CSQC_MinigunEquip =
{
    self.weapon_name         = MINIGUN_DISPLAY_NAME;
    self.weapon_viewmodel    = MINIGUN_VIEWMODEL;
    self.weapon_worldmodel   = MINIGUN_WORLDMODEL;
    self.weapon_deploy_sound = MINIGUN_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictMinigunCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_MinigunDisplayFrame;
    self.csqc_drop_clear     = CSQC_MinigunDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
