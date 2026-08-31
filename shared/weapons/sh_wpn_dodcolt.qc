// ============================================================
//  shared/weapons/sh_wpn_dodcolt.qc  -  Day of Defeat Colt M1911A1
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 7-round magazine, 21 reserve, semi-automatic .45 ACP
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_colt.mdl, models/w_colt.mdl,
// models/p_colt.mdl and every .wav below resolve through the mounted Day of
// Defeat gamedir, the same way sh_wpn_csmac10.qc takes models/v_mac10.mdl from
// cstrike.  DoD is mounted LOW in fs_addons.txt, deliberately -- it reuses ten
// Half-Life model names and 117 sound names -- but every path this file asks for
// is DoD-exclusive and was verified against all five other mounts before the
// line was added.
//
// NOT the same weapon as sh_wpn_th1911.qc.  They Hunger ships its own M1911A1
// with its own model set under models/weapons/wpn_th1911/ and its own
// deliberately weak damage (13/10, from the AngelScript); that one keeps the
// "th1911" manifest key and the weapon_th1911 classname.  This one answers to
// "dodcolt" and to Day of Defeat's own classname, weapon_colt.
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name was read out
// of dod/models/v_colt.mdl itself:
//
//   [0] idle            12fps   66 frames  5.417s
//   [1] shoot1          50fps   36 frames  0.700s   f1 5001 (muzzleflash)
//   [2] shoot2          50fps   36 frames  0.700s   f1 5001
//   [3] reload          34fps   95 frames  2.765s
//         f2   5004 "weapons/colt_reload_clipout.wav"   frac 0.0213
//         f62  5004 "weapons/colt_reload_clipin.wav"    frac 0.6596
//         f73  5004 "weapons/colt_reload_clipin.wav"    frac 0.7766
//   [4] reload_noshoot  34fps   95 frames  2.765s
//         f2   5004 "weapons/colt_reload_clipout.wav"   frac 0.0213
//         f62  5004 "weapons/colt_reload_clipin.wav"    frac 0.6596
//         f87  5004 "weapons/colt_draw_pullslide.wav"   frac 0.9255
//   [5] draw            44fps   31 frames  0.682s   f1 5004 "weapons/rifleselect.wav"
//   [6] shoot_empty     50fps   36 frames  0.700s
//   [7] empty_idle      30fps    2 frames  0.033s
//
// THE TWO RELOADS ARE NOT DUPLICATES, which the labels hide.  They run for the
// same 2.765s and share their first two events; they differ only in the last
// one.  `reload` seats a magazine and taps the slide (a second clipin).
// `reload_noshoot` ends on colt_draw_pullslide -- the slide was locked back, so
// it has to be released.  That is the empty reload, and this file picks between
// them on the magazine count, which is the distinction DoD draws too.

// --- Ammo fields ---
.float mag_dodcolt;
.float ammo_dodcolt;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
// FALLBACKS ONLY.  Everything is resolved by NAME through SH_SeqForName so a
// replacement v_colt.mdl -- and DoD's model set is one of the most-replaced in
// GoldSrc -- cannot silently shift the firing take onto the reload.
const float DODCOLT_SEQ_IDLE      = 0;
const float DODCOLT_SEQ_SHOOT1    = 1;
const float DODCOLT_SEQ_SHOOT2    = 2;
const float DODCOLT_SEQ_RELOAD    = 3;
const float DODCOLT_SEQ_RELOADEMP = 4;
const float DODCOLT_SEQ_DRAW      = 5;
const float DODCOLT_SEQ_SHOOTEMP  = 6;

const float DODCOLT_FRAME_INTERVAL = 0.0333334;   // state-machine tick rate
const float DODCOLT_FIRE_DELAY     = 0.18;
const float DODCOLT_DRYFIRE_DELAY  = 0.20;

// Event marks as a FRACTION of their sequence, so a replacement model at a
// different fps keeps the sounds on the animation.
const float DODCOLT_DRAW_F_SELECT    = 0.0333;   // frame 1  / 30
const float DODCOLT_RELOAD_F_CLIPOUT = 0.0213;   // frame 2  / 94
const float DODCOLT_RELOAD_F_CLIPIN  = 0.6596;   // frame 62 / 94
const float DODCOLT_RELOAD_F_TAP     = 0.7766;   // frame 73 / 94  (loaded reload)
const float DODCOLT_RELOAD_F_SLIDE   = 0.9255;   // frame 87 / 94  (empty reload)

// Every sequence in every Day of Defeat viewmodel is NON-LOOPING (measured:
// flags&1 == 0 on all of them, all 37 models), so an idle plays once and the
// engine clamps to its last frame (gl_hlmdl.c:1076-1082) -- the gun freezes.
// SH_SeqIdleDisplay re-sends one on this timer, which is what GoldSrc's
// CBasePlayerWeapon::WeaponIdle does rather than relying on the loop flag.
const float DODCOLT_IDLE_REARM_MIN = 10;
const float DODCOLT_IDLE_REARM_MAX = 15;

const float MAX_MAG_DODCOLT  = 7;
const float MAX_AMMO_DODCOLT = 21;

// --- Balance ---
//
// Placed against the pistols already on this mod's ladder: Deagle 35/18, USP
// 34/12, P228 28/16, Five-seven 20/12.  A .45 ACP service pistol is the USP's
// cartridge out of a longer barrel, so 34 close matches it exactly and 18
// minimum sits between the USP's 12 and the Deagle's 18 -- the round is heavy
// and subsonic, it does not shed velocity the way the 9mm and 5.7 do.  Falloff
// 2048 is this tree's standard pistol distance.
//
// SEMI-AUTO, via SH_StandardTryFireSemiAuto: seven rounds is the whole tactical
// character of the gun and hold-to-empty would delete it.  0.18s is a fast but
// humanly reachable trigger pull -- between the USP's 0.15 and the Deagle's 0.30.
const float DODCOLT_BASE_SPREAD          = 0.008;
const float DODCOLT_MOVE_SPREAD          = 0.055;
const float DODCOLT_FULL_SPREAD_SPEED    = 320;
const float DODCOLT_CLOSE_DAMAGE         = 34;
const float DODCOLT_MIN_DAMAGE           = 18;
const float DODCOLT_DAMAGE_FALLOFF_RANGE = 2048;
const float DODCOLT_KICK_PITCH    = 1.10;   // sv_gunkick -- a light frame firing
const float DODCOLT_KICK_VARIANCE = 0.35;   // a heavy round: sharp, but the
const float DODCOLT_KICK_STRENGTH = 1.15;   // recovery is predictable

// Muzzle offset -- see cl_debug_muzzle for the live-tune marker.  Seeded from
// the USP's pose (the closest silhouette in the tree); treat as a starting
// point, not a tuned value.
const float DODCOLT_MUZZLE_FORWARD = 22;
const float DODCOLT_MUZZLE_RIGHT   = 4.5;
const float DODCOLT_MUZZLE_DOWN    = 3.0;

const string DODCOLT_VIEWMODEL    = "models/v_colt.mdl";
const string DODCOLT_WORLDMODEL   = "models/w_colt.mdl";
const string DODCOLT_PMODEL       = "models/p_colt.mdl";
const string DODCOLT_DEPLOY_SOUND = "";
const string DODCOLT_DISPLAY_NAME = "M1911";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload/draw events latch off elapsed time instead of a frame number.
.float dodcolt_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodColtSeqIdle      = { return SH_SeqForName(DODCOLT_VIEWMODEL, "idle",           DODCOLT_SEQ_IDLE); };
// The slide-locked rest pose.  This file already wires shoot_empty, so the gap
// was the IDLE only — see the note in sh_wpn_dodmp40.qc.
const float DODCOLT_SEQ_EMPTY_IDLE = 7;
float() SH_DodColtSeqEmptyIdle = { return SH_SeqForName(DODCOLT_VIEWMODEL, "empty_idle", DODCOLT_SEQ_EMPTY_IDLE); };
float() SH_DodColtSeqShoot1    = { return SH_SeqForName(DODCOLT_VIEWMODEL, "shoot1",         DODCOLT_SEQ_SHOOT1); };
float() SH_DodColtSeqShoot2    = { return SH_SeqForName(DODCOLT_VIEWMODEL, "shoot2",         DODCOLT_SEQ_SHOOT2); };
float() SH_DodColtSeqShootEmp  = { return SH_SeqForName(DODCOLT_VIEWMODEL, "shoot_empty",    DODCOLT_SEQ_SHOOTEMP); };
float() SH_DodColtSeqReload    = { return SH_SeqForName(DODCOLT_VIEWMODEL, "reload",         DODCOLT_SEQ_RELOAD); };
float() SH_DodColtSeqReloadEmp = { return SH_SeqForName(DODCOLT_VIEWMODEL, "reload_noshoot", DODCOLT_SEQ_RELOADEMP); };
float() SH_DodColtSeqDraw      = { return SH_SeqForName(DODCOLT_VIEWMODEL, "draw",           DODCOLT_SEQ_DRAW); };

// Which reload take -- see the note at the top of the file.  Read the magazine,
// not the weaponstate: by the time this is called the reload has already
// started, and the count is still the pre-reload one until RELOAD_F_APPLY.
float(float mag) SH_DodColtSeqReloadFor =
{
    return (mag <= 0) ? SH_DodColtSeqReloadEmp() : SH_DodColtSeqReload();
};

// Deterministic shoot-take pick from wep_action_id so client and server agree
// which one plays for this exact shot.
float(float action_id, float mag) SH_DodColtPickShootSeq =
{
    if (mag <= 0)
        return SH_DodColtSeqShootEmp();
    return (SH_SpreadHash(action_id) < 0.5) ? SH_DodColtSeqShoot1()
                                            : SH_DodColtSeqShoot2();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_DodColtDrawDuration   = { return SH_SeqDuration(DODCOLT_VIEWMODEL, SH_DodColtSeqDraw(),   0.682); };
float() SH_DodColtReloadDuration = { return SH_SeqDuration(DODCOLT_VIEWMODEL, SH_DodColtSeqReload(), 2.765); };

// ============================================================
//  SHARED - state machine
// ============================================================

// reload_apply_time == reload_dur, DELIBERATELY, and it is the whole reason the
// two reload takes can be picked off the magazine at all.  SH_StandardTickState
// moves the reserve into the magazine at reload_apply_time; if that were the
// usual ~70% of the way through, mag_dodcolt would go 0 -> 7 mid-animation and
// SH_DodColtSeqReloadFor would swap the model from reload_noshoot to reload
// three-quarters of the way through the reload -- a visible jump-cut.  Applying
// at the end pins the magazine for the whole state, so both sides and every
// render frame agree on which take is playing.  sh_wpn_th1911.qc makes the same
// trade for the same reason; the cost is that a reload can be cancelled by a
// weapon switch right up to the last instant.
float(float now) SH_DodColtTickState =
{
    float rel = SH_DodColtReloadDuration();
    return SH_StandardTickState(now, mag_dodcolt, ammo_dodcolt, MAX_MAG_DODCOLT,
        SH_DodColtDrawDuration(),
        SH_SeqDuration(DODCOLT_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel);
};

float(float now) SH_DodColtTryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_dodcolt, DODCOLT_FIRE_DELAY, DODCOLT_DRYFIRE_DELAY);
};

float(float now) SH_DodColtTryReload =
{
    return SH_StandardTryReload(now, mag_dodcolt, ammo_dodcolt, MAX_MAG_DODCOLT,
        SH_DodColtReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodColtPickupCopy =
{
    player.mag_dodcolt  = self.mag_dodcolt;
    player.ammo_dodcolt = self.ammo_dodcolt;
};

void() W_DodColtShoot =
{
    // Penetration 24 / 0.95.  A heavy pistol round: it goes through a door skin
    // and a crate lid and stops, between the 9mm SMGs' 32 and the Five-seven's 8.
    W_PenetratingHitscanShoot(DODCOLT_BASE_SPREAD, DODCOLT_MOVE_SPREAD, DODCOLT_FULL_SPREAD_SPEED,
        DODCOLT_CLOSE_DAMAGE, DODCOLT_MIN_DAMAGE, DODCOLT_DAMAGE_FALLOFF_RANGE, 24, 0.95,
        DODCOLT_KICK_PITCH, DODCOLT_KICK_VARIANCE, DODCOLT_KICK_STRENGTH);
};

void() W_DodColtFire =
{
    float r = SH_DodColtTryFire(time);

    if (r == 1)
    {
        // Read the magazine AFTER the shot -- SH_StandardTryFire has already
        // decremented it, so 0 here means that was the last round and the slide
        // is locked back, which is what shoot_empty draws.
        self.weaponframe       = SH_DodColtPickShootSeq(self.wep_action_id, self.mag_dodcolt);
        self.wep_nextframe     = time + DODCOLT_FRAME_INTERVAL;
        self.dodcolt_snd_stage = 0;

        W_DodColtShoot();

        sound(self, CHAN_WEAPON, "weapons/colt_shoot.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_DodColtReload =
{
    if (SH_DodColtTryReload(time))
    {
        self.weaponframe       = SH_DodColtSeqReloadFor(self.mag_dodcolt);
        self.wep_nextframe     = time + DODCOLT_FRAME_INTERVAL;
        self.dodcolt_snd_stage = 0;
    }
};

void() W_DodColtFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model - DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += DODCOLT_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodColtDrawDuration() * DODCOLT_DRAW_F_SELECT
            && self.dodcolt_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodcolt_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_DodColtReloadDuration();
        // Same test the take was chosen with, and it holds for the whole state
        // because the transfer lands at the end -- see SH_DodColtTickState.  The
        // last event has to agree with the take or an empty reload seats a
        // magazine and then taps a slide that is already forward.
        float was_empty = (self.mag_dodcolt <= 0);

        if (elapsed >= rel * DODCOLT_RELOAD_F_CLIPOUT && self.dodcolt_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
            self.dodcolt_snd_stage = 1;
        }
        if (elapsed >= rel * DODCOLT_RELOAD_F_CLIPIN && self.dodcolt_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodcolt_snd_stage = 2;
        }
        if (was_empty)
        {
            if (elapsed >= rel * DODCOLT_RELOAD_F_SLIDE && self.dodcolt_snd_stage < 3)
            {
                sound(self, CHAN_AUTO, "weapons/colt_draw_pullslide.wav", 1, ATTN_NORM);
                self.dodcolt_snd_stage = 3;
            }
        }
        else if (elapsed >= rel * DODCOLT_RELOAD_F_TAP && self.dodcolt_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/colt_reload_clipin.wav", 1, ATTN_NORM);
            self.dodcolt_snd_stage = 3;
        }
    }

    result = SH_DodColtTickState(time);
    if (result & 1)
    {
        self.weaponframe       = SH_DodColtSeqIdle();
        self.wep_nextframe     = 0;
        self.dodcolt_snd_stage = 0;
    }
};

void() W_DodColtEquip =
{
    // Iron sights, no optic: SCOPE_CLASS_NONE gives the pull-in without a zoom
    // stage, the same profile every unscoped pistol in the tree uses.
    W_SetADSProfile(TRUE, "cl_ads_dodcolt", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODCOLT_VIEWMODEL, DODCOLT_DISPLAY_NAME, SH_DodColtSeqDraw(),
        DODCOLT_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodColtFire;
    self.reload   = W_DodColtReload;
    self.wepframe = W_DodColtFrame;
    self.shoot    = W_DodColtShoot;
    self.dodcolt_snd_stage = 0;
    W_SetCrosshairProfile(DODCOLT_BASE_SPREAD, DODCOLT_MOVE_SPREAD, DODCOLT_FULL_SPREAD_SPEED, 1.3, TRUE);
};

void() W_DodColtDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodcolt  = self.mag_dodcolt;
    tgt.ammo_dodcolt = self.ammo_dodcolt;

    self.mag_dodcolt  = 0;
    self.ammo_dodcolt = 0;

    setmodel(tgt, DODCOLT_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_colt";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODCOLT;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_DodColtEquip;
    tgt.weap_drop_func = W_DodColtDrop;
    tgt.pickupcopy     = W_DodColtPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes Day of Defeat's own classname (dod.fgd), so a GoldSrc DoD map that
// places one gets this gun rather than "no spawn function".  weapon_colt had
// zero references in this tree before this weapon existed.
void() weapon_colt =
{
    setmodel(self, DODCOLT_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_colt";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODCOLT;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_DodColtEquip;
    self.weap_drop_func = W_DodColtDrop;
    self.pickupcopy     = W_DodColtPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodcolt    = MAX_MAG_DODCOLT;
    self.ammo_dodcolt   = MAX_AMMO_DODCOLT;
    W_RegisterMapWeapon(weapon_colt);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodcolt_snd_stage;
float csqc_dodcolt_snd_action;

void() CSQC_PredictDodColtCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodcolt_snd_action)
    {
        csqc_dodcolt_snd_action = predicted_player.wep_action_id;
        csqc_dodcolt_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodColtTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/colt_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(DODCOLT_BASE_SPREAD, DODCOLT_MOVE_SPREAD, DODCOLT_FULL_SPREAD_SPEED,
                    DODCOLT_CLOSE_DAMAGE, DODCOLT_MIN_DAMAGE, DODCOLT_DAMAGE_FALLOFF_RANGE, 24, 0.95,
                    DODCOLT_KICK_PITCH, DODCOLT_KICK_VARIANCE, DODCOLT_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODCOLT_MUZZLE_FORWARD, DODCOLT_MUZZLE_RIGHT,
                    DODCOLT_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODCOLT_MUZZLE_FORWARD, DODCOLT_MUZZLE_RIGHT,
                    DODCOLT_MUZZLE_DOWN, self.wep_action_id, 1);
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
            if (csqc_dodcolt_snd_stage < 1
                && elapsed >= SH_DodColtDrawDuration() * DODCOLT_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodcolt_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_DodColtReloadDuration();
            float was_empty = (self.mag_dodcolt <= 0);

            if (csqc_dodcolt_snd_stage < 1 && elapsed >= rel * DODCOLT_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/colt_reload_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_dodcolt_snd_stage = 1;
            }
            if (csqc_dodcolt_snd_stage < 2 && elapsed >= rel * DODCOLT_RELOAD_F_CLIPIN)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodcolt_snd_stage = 2;
            }
            if (was_empty)
            {
                if (csqc_dodcolt_snd_stage < 3 && elapsed >= rel * DODCOLT_RELOAD_F_SLIDE)
                {
                    localsound("weapons/colt_draw_pullslide.wav");
                    CSQC_RecordPredictedAutoSound();
                    csqc_dodcolt_snd_stage = 3;
                }
            }
            else if (csqc_dodcolt_snd_stage < 3 && elapsed >= rel * DODCOLT_RELOAD_F_TAP)
            {
                localsound("weapons/colt_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodcolt_snd_stage = 3;
            }
        }
    }

    SH_DodColtTickState(csqc_pred_time);
};

void() CSQC_PredictDodColtReload =
{
    if (SH_DodColtTryReload(csqc_pred_time))
    {
        csqc_dodcolt_snd_stage  = 0;
        csqc_dodcolt_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.
float(float elapsed) CSQC_DodColtDisplayFrame =
{
    // FIRST, for every state — SH_SeqIdleDisplay has to see the non-idle frames
    // to catch the return-to-idle edge.  v_colt.mdl has no looping sequence at
    // all (none of the DoD set does), so without this the gun clamps to the
    // idle's last frame and never moves again.
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodcolt <= 0)
              ? SH_DodColtSeqEmptyIdle() : SH_DodColtSeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODCOLT, predicted_player.weaponstate,
                                   e, e,
                                   DODCOLT_IDLE_REARM_MIN, DODCOLT_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodColtSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodColtSeqReloadFor(predicted_player.mag_dodcolt);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodColtPickShootSeq(predicted_player.wep_action_id,
                                      predicted_player.mag_dodcolt);

    return e;
};

void() CSQC_DodColtDropClear =
{
    self.mag_dodcolt  = 0;
    self.ammo_dodcolt = 0;
};

void() CSQC_DodColtEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodcolt", SCOPE_CLASS_NONE);
    self.weapon_name         = DODCOLT_DISPLAY_NAME;
    self.weapon_viewmodel    = DODCOLT_VIEWMODEL;
    self.weapon_worldmodel   = DODCOLT_WORLDMODEL;
    self.weapon_deploy_sound = DODCOLT_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodColtCommand;
    self.csqc_predict_reload = CSQC_PredictDodColtReload;
    self.csqc_display_frame  = CSQC_DodColtDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodColtDropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // NOT flipped: the Day of Defeat viewmodels are right-handed, like the
    // Counter-Strike ones and unlike the CrossFire set.
};

#endif // CSQC
