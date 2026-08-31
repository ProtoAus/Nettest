// ============================================================
//  shared/weapons/sh_wpn_dodbar.qc  -  Day of Defeat M1918 BAR
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 60 reserve, full-auto .30-06
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_bar.mdl, models/w_bar.mdl,
// models/p_barbu.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_bar.mdl — NINE sequences in two halves:
//   [0] up_idle     12fps   86f  7.083s
//   [1] up_reload   32fps  120f  3.719s
//         f13 5004 "weapons/tommy_reload_clipout.wav"   frac 0.1092
//         f71 5004 "weapons/tommy_reload_clipin.wav"    frac 0.5966
//         f99 5004 "weapons/tommy_draw_slideback.wav"   frac 0.8319
//   [2] up_draw     60fps   81f  1.333s   f1 5004 "weapons/rifleselect.wav"
//   [3] up_shoot    25fps  101f  4.000s   f1 5001 (flash) f1 6002 (shell)
//   [4] up_to_down  30fps   71f  2.333s
//   [5] down_idle   12fps    2f  0.083s
//   [6] down_reload 35fps  136f  3.857s
//   [7] down_shoot  25fps   20f  0.760s
//   [8] down_to_up  32fps   66f  2.031s
//
// BOTH HALVES ARE WIRED NOW.  down_* is the BIPOD-DEPLOYED set: in Day of Defeat
// the BAR can be planted, which locks you in place, removes almost all of the
// recoil and swaps the whole animation set.  The old note here said that was "a
// movement-state mechanic this mod has no framework for" and that wiring
// down_shoot "would give the recoil benefit with none of the cost".  The
// framework exists now — the shared .wep_deployed flag and SH_DeploySpeedFactor
// in sh_weapons.qc, which the mortar and the three machine guns use too — so the
// cost is a hard movement lock and the benefit is DODBAR_DEPLOY_SPREAD_SCALE.
//
// +attack2 OR weapon-special (impulse 7) plants it (up_to_down, 2.333 s) and
// picks it back up (down_to_up, 2.031 s).  Both are long enough that planting is
// a commitment, and you have to be CROUCHED to plant — sh_pmove.qc then holds you
// crouched for the whole stance.  Both buttons work because the Bren and the two
// FG42s have only ever been on impulse 7, and this weapon bound no .special.
//
// The third-person half is unchanged: p_barbu.mdl is still what goes on the wire
// whether or not the bipod is down, so other players see a standing BAR.  That is
// cosmetic and is called out rather than hidden.
//
// up_shoot runs 4.0s, which is the full muzzle-climb recovery.  At a 0.120s
// trigger the sequence restarts long before it finishes, so only its opening
// frames are ever seen -- exactly how Day of Defeat plays it.

// --- Ammo fields ---
.float mag_dodbar;
.float ammo_dodbar;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODBAR_SEQ_IDLE   = 0;
const float DODBAR_SEQ_RELOAD = 1;
const float DODBAR_SEQ_DRAW   = 2;
const float DODBAR_SEQ_SHOOT  = 3;
const float DODBAR_SEQ_PLANT  = 4;   // up_to_down
const float DODBAR_SEQ_DIDLE  = 5;   // down_idle
const float DODBAR_SEQ_DRELOAD = 6;  // down_reload
const float DODBAR_SEQ_DSHOOT = 7;   // down_shoot
const float DODBAR_SEQ_STANDUP = 8;  // down_to_up

const float DODBAR_FRAME_INTERVAL = 0.0333334;
const float DODBAR_FIRE_DELAY     = 0.120;   // ~500 rpm, the BAR's slow setting
const float DODBAR_DRYFIRE_DELAY  = 0.20;

// Spread multiplier on the bipod.  Tighter than the machine guns' 0.35 because
// the BAR starts from a much better standing cone (0.013 against 0.055-0.072) and
// a proportional cut there would be imperceptible; 0.30 of 0.013 is 0.0039, which
// is rifle-accurate and is what a planted automatic rifle should be.
const float DODBAR_DEPLOY_SPREAD_SCALE = 0.30;

const float DODBAR_DRAW_F_SELECT    = 0.0125;   // frame 1  / 80
const float DODBAR_RELOAD_F_CLIPOUT = 0.1092;   // frame 13 / 119
const float DODBAR_RELOAD_F_CLIPIN  = 0.5966;   // frame 71 / 119
const float DODBAR_RELOAD_F_BOLT    = 0.8319;   // frame 99 / 119
const float DODBAR_RELOAD_F_APPLY   = 0.6200;   // just after the mag seats

const float DODBAR_IDLE_REARM_MIN = 10;
const float DODBAR_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODBAR  = 20;
const float MAX_AMMO_DODBAR = 60;

// --- Balance ---
//
// A full-power rifle round on full auto, which is the most dangerous thing in
// this set and is priced as such.  46/32 over 3400: three quarters of a Garand
// hit, four times a second, and it keeps most of that out to rifle distance.
//
// The costs are all real and all in the numbers below or in the manifest.
// Twenty rounds -- the shortest burst budget of any automatic here.  0.889 carry
// speed, the same as the M249 and the slowest in the mod.  And the heaviest
// recoil in the file by a wide margin: 2.6 pitch against the StG44's 1.15, with
// the variance to match.  Standing and holding the trigger walks it off target
// within half a magazine, which is what the bipod exists to fix and why not
// having the bipod is a real limitation rather than a free pass.
const float DODBAR_BASE_SPREAD          = 0.013;
const float DODBAR_MOVE_SPREAD          = 0.095;
const float DODBAR_FULL_SPREAD_SPEED    = 320;
const float DODBAR_CLOSE_DAMAGE         = 46;
const float DODBAR_MIN_DAMAGE           = 32;
const float DODBAR_DAMAGE_FALLOFF_RANGE = 3400;
const float DODBAR_KICK_PITCH    = 2.60;
const float DODBAR_KICK_VARIANCE = 0.55;
const float DODBAR_KICK_STRENGTH = 1.45;

const float DODBAR_MUZZLE_FORWARD = 46;
const float DODBAR_MUZZLE_RIGHT   = 3.5;
const float DODBAR_MUZZLE_DOWN    = 3;

const string DODBAR_VIEWMODEL    = "models/v_bar.mdl";
const string DODBAR_WORLDMODEL   = "models/w_bar.mdl";
const string DODBAR_DEPLOY_SOUND = "";
const string DODBAR_DISPLAY_NAME = "BAR";

.float dodbar_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

// Every pose takes the stance as a PARAMETER rather than reading self, because
// the CSQC display path runs with self set to the viewmodel entity and passes
// predicted_player.wep_deployed in.
float(float dep) SH_DodBarSeqIdle =
{
    if (dep) return SH_SeqForName(DODBAR_VIEWMODEL, "down_idle", DODBAR_SEQ_DIDLE);
    return         SH_SeqForName(DODBAR_VIEWMODEL, "up_idle",   DODBAR_SEQ_IDLE);
};
float(float dep) SH_DodBarSeqReload =
{
    if (dep) return SH_SeqForName(DODBAR_VIEWMODEL, "down_reload", DODBAR_SEQ_DRELOAD);
    return         SH_SeqForName(DODBAR_VIEWMODEL, "up_reload",   DODBAR_SEQ_RELOAD);
};
float(float dep) SH_DodBarSeqShoot =
{
    if (dep) return SH_SeqForName(DODBAR_VIEWMODEL, "down_shoot", DODBAR_SEQ_DSHOOT);
    return         SH_SeqForName(DODBAR_VIEWMODEL, "up_shoot",   DODBAR_SEQ_SHOOT);
};

// There is only ONE draw take and it is the standing one — the BAR is always
// drawn off the shoulder, never off its bipod.
float() SH_DodBarSeqDraw   = { return SH_SeqForName(DODBAR_VIEWMODEL, "up_draw",   DODBAR_SEQ_DRAW); };

// The stance pair.  The take that plays is the one LEAVING the current stance,
// because .wep_deployed does not flip until it ends.
float() SH_DodBarSeqPlant   = { return SH_SeqForName(DODBAR_VIEWMODEL, "up_to_down", DODBAR_SEQ_PLANT); };
float() SH_DodBarSeqStandUp = { return SH_SeqForName(DODBAR_VIEWMODEL, "down_to_up", DODBAR_SEQ_STANDUP); };
float(float dep) SH_DodBarSeqStance = { return dep ? SH_DodBarSeqStandUp() : SH_DodBarSeqPlant(); };

float() SH_DodBarDrawDuration   = { return SH_SeqDuration(DODBAR_VIEWMODEL, SH_DodBarSeqDraw(),   1.333); };
float(float dep) SH_DodBarReloadDuration = { return SH_SeqDuration(DODBAR_VIEWMODEL, SH_DodBarSeqReload(dep), 3.719); };
float(float dep) SH_DodBarStanceDuration =
{
    if (dep) return SH_SeqDuration(DODBAR_VIEWMODEL, SH_DodBarSeqStandUp(), 2.031);
    return         SH_SeqDuration(DODBAR_VIEWMODEL, SH_DodBarSeqPlant(),   2.333);
};

// The LIVE spread — base, scaled by the bipod.  DODBAR_BASE_SPREAD stays the
// standing number so the crosshair profile and the balance comments still read as
// one value.
float() SH_DodBarSpread =
{
    if (self.wep_deployed)
        return DODBAR_BASE_SPREAD * DODBAR_DEPLOY_SPREAD_SCALE;
    return DODBAR_BASE_SPREAD;
};

// ============================================================
//  SHARED - state machine
// ============================================================

// NOT SH_SeqDuration(weaponframe) for the fire duration, which every other
// weapon in this set uses: up_shoot is 4.0s of recoil recovery, and handing
// that to SH_StandardTickState would keep the state machine in WS_FIRE for four
// seconds after one round -- blocking the reload and the idle.  The fire state
// only has to outlast the trigger delay, so it gets that.
// +attack2 plants the BAR on its bipod, or picks it back up.  Same shape as the
// mortar's and the machine guns': both sides run it, the flag flips when the take
// ends, and the prediction proxy reconciles it.
float(float now) SH_DodBarTryStance =
{
    // RISING EDGE — see SH_StanceAltEdge in sh_weapons.qc.  A held +attack2 would
    // otherwise re-toggle the frame after the take ends, so the bipod would go
    // down and straight back up for as long as the key stayed down.
    if (!SH_StanceAltEdge(TRUE)) return FALSE;

    if (Weapon_LowerBlocksFire()) return FALSE;
    // CROUCH TO PLANT.  Same gate and same reasoning as the mortar's — see
    // SH_DodMortarTryStance.  Both sides read the replicated FL_DUCKING, so it is
    // prediction-exact; the !wep_deployed guard keeps standing back up free.
    if (!self.wep_deployed
        && !((self.flags & FL_DUCKING) && (self.flags & FL_ONGROUND)))
        return FALSE;
    if (self.weaponstate != WS_IDLE) return FALSE;
    if (now < self.attack_finished)  return FALSE;

    self.weaponstate     = WS_SPECIAL;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + SH_DodBarStanceDuration(self.wep_deployed);
    return TRUE;
};

float(float now) SH_DodBarTickState =
{
    // WS_SPECIAL is the plant / stand-up take.  Handled before the standard
    // driver, which has no arm for it.
    if (self.weaponstate == WS_SPECIAL)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodBarStanceDuration(self.wep_deployed))
        {
            self.wep_deployed = !self.wep_deployed;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_DodBarReloadDuration(self.wep_deployed);
    return SH_StandardTickState(now, mag_dodbar, ammo_dodbar, MAX_MAG_DODBAR,
        SH_DodBarDrawDuration(),
        DODBAR_FIRE_DELAY,
        rel, rel * DODBAR_RELOAD_F_APPLY);
};

float(float now) SH_DodBarTryFire =
{
    return SH_StandardTryFire(now, mag_dodbar, DODBAR_FIRE_DELAY, DODBAR_DRYFIRE_DELAY);
};

float(float now) SH_DodBarTryReload =
{
    return SH_StandardTryReload(now, mag_dodbar, ammo_dodbar, MAX_MAG_DODBAR,
        SH_DodBarReloadDuration(self.wep_deployed));
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodBarPickupCopy =
{
    player.mag_dodbar  = self.mag_dodbar;
    player.ammo_dodbar = self.ammo_dodbar;
};

void() W_DodBarShoot =
{
    W_PenetratingHitscanShoot(SH_DodBarSpread(), DODBAR_MOVE_SPREAD, DODBAR_FULL_SPREAD_SPEED,
        DODBAR_CLOSE_DAMAGE, DODBAR_MIN_DAMAGE, DODBAR_DAMAGE_FALLOFF_RANGE, 80, 0.98,
        DODBAR_KICK_PITCH, DODBAR_KICK_VARIANCE, DODBAR_KICK_STRENGTH);
};

// Button-up half of the rising-edge latch; .altrelease is called every frame the
// button is up, which is exactly the clearing edge needed.
void() W_DodBarAltRelease =
{
    SH_StanceAltEdge(FALSE);
};

// +attack2 — plant on the bipod, or pick the gun back up.
void() W_DodBarAltFire =
{
    if (SH_DodBarTryStance(time))
    {
        self.weaponframe      = SH_DodBarSeqStance(self.wep_deployed);
        self.wep_nextframe    = time + DODBAR_FRAME_INTERVAL;
        self.dodbar_snd_stage = 0;
    }
};

// SECOND ENTRY POINT: weapon-special (impulse 7).  See W_DodMGSpecial — the five
// +attack2 deployables bound no .special at all, so impulse 7 did literally
// nothing on them while the Bren and both FG42s have only ever been on impulse 7.
void() W_DodBarSpecial =
{
    SH_StanceAltArmForImpulse();
    W_DodBarAltFire();
};

void() W_DodBarFire =
{
    float r = SH_DodBarTryFire(time);

    if (r == 1)
    {
        self.weaponframe      = SH_DodBarSeqShoot(self.wep_deployed);
        self.wep_nextframe    = time + DODBAR_FRAME_INTERVAL;
        self.dodbar_snd_stage = 0;

        W_DodBarShoot();

        sound(self, CHAN_WEAPON, "weapons/bar_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_DodBarReload =
{
    if (SH_DodBarTryReload(time))
    {
        self.weaponframe      = SH_DodBarSeqReload(self.wep_deployed);
        self.wep_nextframe    = time + DODBAR_FRAME_INTERVAL;
        self.dodbar_snd_stage = 0;
    }
};

void() W_DodBarFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODBAR_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodBarDrawDuration() * DODBAR_DRAW_F_SELECT
            && self.dodbar_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodbar_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodBarReloadDuration(self.wep_deployed);

        if (elapsed >= rel * DODBAR_RELOAD_F_CLIPOUT && self.dodbar_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.dodbar_snd_stage = 1;
        }
        if (elapsed >= rel * DODBAR_RELOAD_F_CLIPIN && self.dodbar_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_reload_clipin.wav", 1, ATTN_NORM);
            self.dodbar_snd_stage = 2;
        }
        if (elapsed >= rel * DODBAR_RELOAD_F_BOLT && self.dodbar_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/tommy_draw_slideback.wav", 1, ATTN_NORM);
            self.dodbar_snd_stage = 3;
        }
    }

    result = SH_DodBarTickState(time);
    if (result & 1)
    {
        // wep_deployed may have just flipped inside the tick — re-read it.
        self.weaponframe      = SH_DodBarSeqIdle(self.wep_deployed);
        self.wep_nextframe    = 0;
        self.dodbar_snd_stage = 0;
    }
};

void() W_DodBarEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodbar", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODBAR_VIEWMODEL, DODBAR_DISPLAY_NAME, SH_DodBarSeqDraw(),
        DODBAR_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodBarFire;
    self.altfire    = W_DodBarAltFire;      // plant / pick up
    self.altrelease = W_DodBarAltRelease;   // clears the rising-edge latch
    self.special    = W_DodBarSpecial;      // impulse 7 does the same thing
    self.wep_stance_alt_held = 0;
    self.reload   = W_DodBarReload;
    self.wepframe = W_DodBarFrame;
    self.shoot    = W_DodBarShoot;
    self.dodbar_snd_stage = 0;
    // ALWAYS COMES OUT STANDING — up_draw is the only draw take on this model, so
    // a BAR that remembered its bipod would draw into a pose it cannot animate,
    // and would hand the player a movement lock they did not ask for.
    self.wep_deployed      = 0;
    self.weapon_deployable = TRUE;   // arms the shared SH_DeploySpeedFactor lock
    W_SetCrosshairProfile(DODBAR_BASE_SPREAD, DODBAR_MOVE_SPREAD, DODBAR_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_DodBarDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodbar  = self.mag_dodbar;
    tgt.ammo_dodbar = self.ammo_dodbar;

    self.mag_dodbar  = 0;
    self.ammo_dodbar = 0;

    setmodel(tgt, DODBAR_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_bar";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODBAR;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodBarEquip;
    tgt.weap_drop_func = W_DodBarDrop;
    tgt.pickupcopy     = W_DodBarPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_bar =
{
    setmodel(self, DODBAR_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_bar";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODBAR;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodBarEquip;
    self.weap_drop_func = W_DodBarDrop;
    self.pickupcopy     = W_DodBarPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodbar     = MAX_MAG_DODBAR;
    self.ammo_dodbar    = MAX_AMMO_DODBAR;
    W_RegisterMapWeapon(weapon_bar);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodbar_snd_stage;
float csqc_dodbar_snd_action;

void() CSQC_PredictDodBarCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodbar_snd_action)
    {
        csqc_dodbar_snd_action = predicted_player.wep_action_id;
        csqc_dodbar_snd_stage  = 0;
    }

    // +attack2 — plant on the bipod, or pick the gun back up.  Predicted so the
    // movement lock lifts the instant the take ends rather than a round trip
    // later; SH_DodBarTickState flips the flag identically on both sides.
    if (input_buttons & 4)
    {
        if (SH_DodBarTryStance(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_dodbar_snd_stage  = 0;
            csqc_dodbar_snd_action = predicted_player.wep_action_id;
        }
    }
    else
    {
        // Clearing half of the rising-edge latch, mirroring W_DodBarAltRelease.
        SH_StanceAltEdge(FALSE);
    }

    if (input_buttons & 1)
    {
        r = SH_DodBarTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/bar_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(SH_DodBarSpread(), DODBAR_MOVE_SPREAD, DODBAR_FULL_SPREAD_SPEED,
                    DODBAR_CLOSE_DAMAGE, DODBAR_MIN_DAMAGE, DODBAR_DAMAGE_FALLOFF_RANGE, 80, 0.98,
                    DODBAR_KICK_PITCH, DODBAR_KICK_VARIANCE, DODBAR_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODBAR_MUZZLE_FORWARD, DODBAR_MUZZLE_RIGHT,
                    DODBAR_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODBAR_MUZZLE_FORWARD, DODBAR_MUZZLE_RIGHT,
                    DODBAR_MUZZLE_DOWN, self.wep_action_id, 3);
                CSQC_EndFireActionEffects();
            }
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
            if (csqc_dodbar_snd_stage < 1
                && elapsed >= SH_DodBarDrawDuration() * DODBAR_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodbar_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodBarReloadDuration(predicted_player.wep_deployed);

            if (csqc_dodbar_snd_stage < 1 && elapsed >= rel * DODBAR_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/tommy_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodbar_snd_stage = 1;
            }
            if (csqc_dodbar_snd_stage < 2 && elapsed >= rel * DODBAR_RELOAD_F_CLIPIN)
            {
                localsound("weapons/tommy_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodbar_snd_stage = 2;
            }
            if (csqc_dodbar_snd_stage < 3 && elapsed >= rel * DODBAR_RELOAD_F_BOLT)
            {
                localsound("weapons/tommy_draw_slideback.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodbar_snd_stage = 3;
            }
        }
    }

    // MARK THE ACK AT THE FLIP, NOT ONLY AT THE PRESS.
    //
    // CSQC_ResetToConfirmedState writes wep_deployed back from the server's copy
    // unconditionally, and the reset-then-replay contract only holds for a field
    // the replay can RE-DERIVE.  This one it cannot: the flip is produced inside
    // the tick below, which immediately calls SH_WeaponEnterIdle() — and reconcile
    // deliberately never rewinds weaponstate / wep_anim_start, so the replay
    // re-enters the tick with WS_SPECIAL already false and never flips again.
    // The ack marked on the +attack2 PRESS has long since cleared by the time the
    // 2.0-2.3 s take ends, so the stance was stomped back for a full RTT after
    // every plant: the client un-deployed, predicted a full-speed walk against a
    // server holding the player at zero, and rubber-banded.
    //
    // Marking here defers the whole weapon-state reset until the server acks the
    // command the flip happened in.  CSQC_MarkPendingWeaponAck no-ops on replay
    // passes, so this latches on live ticks only, exactly like the fire path.
    float bar_pre_dep = self.wep_deployed;
    SH_DodBarTickState(csqc_pred_time);
    if (self.wep_deployed != bar_pre_dep)
        CSQC_MarkPendingWeaponAck();
};

// Weapon-special (impulse 7), the second entry point to the bipod toggle.  See
// CSQC_PredictDodMGSpecial — it must be on the else-if chain under
// WEAPON_IMPULSE_SPECIAL in client/cl_weapons.qc or nothing animates.
void() CSQC_PredictDodBarSpecial =
{
    SH_StanceAltArmForImpulse();
    if (SH_DodBarTryStance(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        csqc_dodbar_snd_stage  = 0;
        csqc_dodbar_snd_action = predicted_player.wep_action_id;
    }
};

void() CSQC_PredictDodBarReload =
{
    if (SH_DodBarTryReload(csqc_pred_time))
    {
        csqc_dodbar_snd_stage  = 0;
        csqc_dodbar_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_DodBarDisplayFrame =
{
    float dep  = predicted_player.wep_deployed;
    float pose = SH_DodBarSeqIdle(dep);

    // THE STANCE IS PART OF THE LATCH KEY.  SH_SeqIdleDisplay only re-picks on a
    // non-idle -> idle edge or the 10-15 s reroll, so a stance that changes while
    // the weapon is ALREADY idle — a force-equip, a respawn, a server correction —
    // would leave the previous stance's idle on screen for up to fifteen seconds.
    // csqc_seqidle_owner_wep != wep forces an immediate re-pick, so folding the
    // stance into that key costs one add and closes the hole without touching the
    // shared helper.  4096 is far above any WEP_* id.
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODBAR + (dep ? 4096 : 0),
                                   predicted_player.weaponstate,
                                   pose, pose,
                                   DODBAR_IDLE_REARM_MIN, DODBAR_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodBarSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodBarSeqReload(dep);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodBarSeqShoot(dep);
    // The stance change.  The flag has not flipped yet — it flips when the take
    // ends — so this is the take LEAVING the current stance.
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodBarSeqStance(dep);

    return pose;
};

void() CSQC_DodBarDropClear =
{
    self.mag_dodbar  = 0;
    self.ammo_dodbar = 0;
};

void() CSQC_DodBarEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodbar", SCOPE_CLASS_NONE);
    self.weapon_name         = DODBAR_DISPLAY_NAME;
    self.weapon_viewmodel    = DODBAR_VIEWMODEL;
    self.weapon_worldmodel   = DODBAR_WORLDMODEL;
    self.weapon_deploy_sound = DODBAR_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodBarCommand;
    self.csqc_predict_reload = CSQC_PredictDodBarReload;
    self.csqc_display_frame  = CSQC_DodBarDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodBarDropClear;
    self.weapon_uses_sequences = TRUE;
    // Arms the shared movement lock on the client's copy too.  NOT accompanied by
    // a wep_deployed reset: this function re-runs on every reconcile and would
    // unplant the bipod 20 times a second.  W_DodBarEquip clears it on a real
    // weapon switch and the proxy carries that across.
    self.weapon_deployable = TRUE;
};

#endif // CSQC
