// ============================================================
//  shared/weapons/sh_wpn_cssg550.qc  -  Counter-Strike SIG SG-550 "Commando"
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 90 reserve, semi-automatic 5.56
//  Fire  : lag-compensated penetrating hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle on +attack2, SCOPE_CLASS_SNIPER_SEMI
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON.  models/v_sg550.mdl, models/w_sg550.mdl,
// models/p_sg550.mdl and every "weapons/..." sound below resolve through the
// mounted cstrike gamedir (fs_addons.txt), exactly the way sh_wpn_csaug.qc
// takes models/v_aug.mdl and sh_wpn_hlcrowbar.qc takes models/v_crowbar.mdl
// from valve.  The mod DOES ship models/weapons/wpn_cfsg550/ — that is the CF
// Dragunov wearing an SG-550 alias (sh_wpn_cfsvd.qc, which still owns the bare
// "sg550" manifest key).  This weapon is a different gun and answers to
// "cssg550" / "commando" / the real GoldSrc classname weapon_sg550.
//
// This is the CT-side twin of the T-side G3SG1 the mod already ships, so
// sh_wpn_csg3sg1.qc is both the structural template and the balance anchor for
// everything below.
//
// ============================================================
//  WHERE THE NUMBERS BELOW CAME FROM
// ============================================================
//
// Every sequence index, every event fraction and every .wav name in this file
// was read out of cstrike/models/v_sg550.mdl itself, not guessed:
//
//   [0] idle1    16fps    3 frames  0.125s
//   [1] shoot    45fps   46 frames  1.000s   f0 5001 (muzzleflash)
//   [2] shoot2   45fps   46 frames  1.000s   f0 5001
//   [3] reload   28fps  107 frames  3.786s
//         f22  5004 "weapons/sg550_clipout.wav"   frac 0.2075
//         f46  5004 "weapons/sg550_clipin.wav"    frac 0.4340
//         f82  5004 "weapons/sg550_boltpull.wav"  frac 0.7736
//   [4] draw     30fps   31 frames  1.000s   — NO SOUND EVENT AT ALL
//
// A GoldSrc studio event of code 5004 carries the sound filename in its
// options[64] field, so the model is the authority on which sample plays and
// when.  The draw genuinely carries no event, so there is no draw-sound branch
// in W_CSSg550Frame or in the CSQC mirror — inventing one would put a sound on
// this gun that Counter-Strike never played.
//
// Fractions are eventframe/(numframes-1), which is the form frameduration()
// (and therefore SH_SeqDuration) scales.  Only TWO shoot takes exist, so the
// deterministic pick below is a coin flip rather than the AUG's three-way.

// --- Ammo fields ---
.float mag_sg550;
.float ammo_sg550;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// FALLBACKS ONLY.  Every one is resolved by NAME at runtime through
// SH_SeqForName, because cstrike AND czero are both mounted and both ship
// models/v_sg550.mdl with the same labels at different fps and frame counts.
// Whichever mount wins, resolving by name and scaling every mark by that
// model's own duration keeps the sounds on the animation.
//
// The same divergence is not merely cosmetic elsewhere in this set: czero's
// v_ump45.mdl carries a seventh sequence (shoot_empty) that cstrike's does not,
// so an index-keyed lookup would be reading a sequence that is not there.
//
// Sound note: cstrike/sound/weapons/ carries all four samples named below;
// czero's copy of the set is missing sg550_boltpull.wav.  cstrike is mounted
// and is the authority for that one — nothing here invents a filename.
const float CSSG550_SEQ_IDLE   = 0;
const float CSSG550_SEQ_SHOOT1 = 1;
const float CSSG550_SEQ_SHOOT2 = 2;
const float CSSG550_SEQ_RELOAD = 3;
const float CSSG550_SEQ_DRAW   = 4;

const float CSSG550_FRAME_INTERVAL   = 0.0333334;   // state-machine tick rate
const float CSSG550_FIRE_DELAY       = 0.22;        // slightly faster than the G3SG1's 0.25
const float CSSG550_DRYFIRE_DELAY    = 0.20;

// Event marks as a FRACTION of their sequence — see the fps note above.
const float CSSG550_RELOAD_F_CLIPOUT = 0.2075;   // frame 22 / 106
const float CSSG550_RELOAD_F_CLIPIN  = 0.4340;   // frame 46 / 106
const float CSSG550_RELOAD_F_BOLT    = 0.7736;   // frame 82 / 106
// Ammo lands between the fresh mag seating (0.4340) and the charging handle
// coming back (0.7736), nearer the mag.  The SG-550's reload is 3.79 s — the
// longest in the CS set — so waiting on the bolt event would leave the player
// holding an apparently-loaded rifle with a zeroed counter for most of a
// second.  Same placement rule the AUG (0.70, clipin 0.667) and the G3SG1
// (0.65, clipin 0.607) use, scaled onto this animation's much earlier clipin.
const float CSSG550_RELOAD_F_APPLY   = 0.6200;

const float MAX_MAG_CSSG550          = 30;
const float MAX_AMMO_CSSG550         = 90;

// --- Balance ---
//
// Placed against the G3SG1, which is the same weapon class already on this
// mod's ladder (60/40 close/min, 0.25 s, falloff 4096).  55/38 sits
// deliberately BELOW it: CS 1.6 rates the SG-550 at 70 damage against the
// G3SG1's 80, and that ordering is the whole point of the CT/T autosniper
// pair.  It sits ABOVE every rifle in this tree — the AK47 is the hardest
// hitter at 34, the SG-552 at 33, the AUG at 32 — and below the Scout's 70 and
// the AWP's 140, so the autosnipers occupy the band between assault rifles and
// the bolt-actions rather than displacing either.
//
// The compensation for the 5-point deficit against the G3SG1 is rate: 0.22 s
// against 0.25 s, which is the same direction CS 1.6 tunes the pair.  Falloff
// range matches every other sniper here at 4096.
//
// 30 rounds and a 90 reserve is a sniper that reloads like a rifle — CS 1.6's
// figures, kept as-is, and the reason the reload above is worth animating
// properly rather than the G3SG1's 20/60.
const float CSSG550_BASE_SPREAD          = 0.010;
const float CSSG550_MOVE_SPREAD          = 0.080;
const float CSSG550_FULL_SPREAD_SPEED    = 320;
const float CSSG550_CLOSE_DAMAGE         = 55;
const float CSSG550_MIN_DAMAGE           = 38;
const float CSSG550_DAMAGE_FALLOFF_RANGE = 4096;
const float CSSG550_KICK_PITCH    = 1.35;  // sv_gunkick — semi-auto sniper, just under the G3SG1's 1.4.
const float CSSG550_KICK_VARIANCE = 0.40;
const float CSSG550_KICK_STRENGTH = 1.0;   // semi-auto — moderate per-shot delay.

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.  Seeded from
// the G3SG1 (52 / 7 / 4.55); the SG-550 mesh sits marginally lower and further
// out in the view.
const float CSSG550_MUZZLE_FORWARD = 50;
const float CSSG550_MUZZLE_RIGHT   = 7.5;
const float CSSG550_MUZZLE_DOWN    = 4.8;

const string CSSG550_VIEWMODEL    = "models/v_sg550.mdl";
const string CSSG550_WORLDMODEL   = "models/w_sg550.mdl";
const string CSSG550_DEPLOY_SOUND = "";
const string CSSG550_DISPLAY_NAME = "SG550";

// The zoom click is the mod's OWN sample, not the mount's weapons/zoom.wav —
// the G3SG1 already borrows the AWP's, and the two autosnipers should sound
// alike when they cycle their scopes.
const string CSSG550_ZOOM_SOUND   = "sounds/weapons/wpn_csawp/zoom.wav";

// Sound stage latch.  A sequence-driven model never steps weaponframe, so the
// timed reload events latch off elapsed time instead of a frame number.
.float sg550_snd_stage;

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_CSSg550SeqIdle   = { return SH_SeqForName(CSSG550_VIEWMODEL, "idle1",  CSSG550_SEQ_IDLE); };
float() SH_CSSg550SeqShoot1 = { return SH_SeqForName(CSSG550_VIEWMODEL, "shoot",  CSSG550_SEQ_SHOOT1); };
float() SH_CSSg550SeqShoot2 = { return SH_SeqForName(CSSG550_VIEWMODEL, "shoot2", CSSG550_SEQ_SHOOT2); };
float() SH_CSSg550SeqReload = { return SH_SeqForName(CSSG550_VIEWMODEL, "reload", CSSG550_SEQ_RELOAD); };
float() SH_CSSg550SeqDraw   = { return SH_SeqForName(CSSG550_VIEWMODEL, "draw",   CSSG550_SEQ_DRAW); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which of the two takes plays for this shot — the CFGLOCK pattern.
// Takes the id as an argument rather than reading self.wep_action_id, because
// the CSQC display path has to ask about predicted_player, not self, and both
// callers must land on the SAME answer or the viewmodel rubber-bands.
float(float action_id) SH_CSSg550PickShootSeq =
{
    if (SH_SpreadHash(action_id) < 0.5)
        return SH_CSSg550SeqShoot1();
    return SH_CSSg550SeqShoot2();
};

// Durations come from the model that actually loaded, never from a constant.
float() SH_CSSg550DrawDuration   = { return SH_SeqDuration(CSSG550_VIEWMODEL, SH_CSSg550SeqDraw(),   1.000); };
float() SH_CSSg550ReloadDuration = { return SH_SeqDuration(CSSG550_VIEWMODEL, SH_CSSg550SeqReload(), 3.786); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CSSg550TickState =
{
    float rel = SH_CSSg550ReloadDuration();
    return SH_StandardTickState(now, mag_sg550, ammo_sg550, MAX_MAG_CSSG550,
        SH_CSSg550DrawDuration(),
        SH_SeqDuration(CSSG550_VIEWMODEL, self.weaponframe, 1.000),
        rel, rel * CSSG550_RELOAD_F_APPLY);
};

// SEMI-AUTO: one shot per trigger press.  SH_StandardTryFireSemiAuto adds the
// rising-edge gate on top of the FIRE_DELAY pacing, which is what separates an
// autosniper from a rifle — holding +attack must not empty the magazine.
//
// Zoom is NOT cleared here: W_CSSg550Shoot reads self.zoomstage for the spread,
// and unlike the bolt-action AWP and Scout nothing clears it afterwards either.
// Staying scoped through the shot is the defining property of an autosniper and
// is why this weapon registers SCOPE_CLASS_SNIPER_SEMI below.
float(float now) SH_CSSg550TryFire =
{
    return SH_StandardTryFireSemiAuto(now, mag_sg550, CSSG550_FIRE_DELAY, CSSG550_DRYFIRE_DELAY);
};

float(float now) SH_CSSg550TryReload =
{
    float r = SH_StandardTryReload(now, mag_sg550, ammo_sg550, MAX_MAG_CSSG550,
        SH_CSSg550ReloadDuration());
    if (r == 1)
        self.zoomstage = 0;
    return r;
};

// Two scope stages then back out — the same cycle the G3SG1 and the AWP drive.
float(float now) SH_CSSg550TryAltFire =
{
    // sv_codscopes short-circuit — CoD mode owns the scope visuals through
    // cl_codscope.qc, keyed off the weapon_scope_class set in the equips; see
    // SH_AWPTryAltFire for the full rationale.  Without this the two systems
    // both answer +attack2 and the zoom double-toggles.
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

void(entity player) W_CSSg550PickupCopy =
{
    player.mag_sg550  = self.mag_sg550;
    player.ammo_sg550 = self.ammo_sg550;
};

void() W_CSSg550Shoot =
{
    // Scoped: zero base spread, movement spread still applies — the G3SG1's
    // two-armed shape.  96 / 0.98 are the sniper penetration args this mod
    // gives the G3SG1; the SG-550 fires the same class of shot.
    if (self.zoomstage > 0)
        W_PenetratingHitscanShoot(0, CSSG550_MOVE_SPREAD, CSSG550_FULL_SPREAD_SPEED,
            CSSG550_CLOSE_DAMAGE, CSSG550_MIN_DAMAGE, CSSG550_DAMAGE_FALLOFF_RANGE, 96, 0.98,
            CSSG550_KICK_PITCH, CSSG550_KICK_VARIANCE, CSSG550_KICK_STRENGTH);
    else
        W_PenetratingHitscanShoot(CSSG550_BASE_SPREAD, CSSG550_MOVE_SPREAD, CSSG550_FULL_SPREAD_SPEED,
            CSSG550_CLOSE_DAMAGE, CSSG550_MIN_DAMAGE, CSSG550_DAMAGE_FALLOFF_RANGE, 96, 0.98,
            CSSG550_KICK_PITCH, CSSG550_KICK_VARIANCE, CSSG550_KICK_STRENGTH);
};

void() W_CSSg550Fire =
{
    float r = SH_CSSg550TryFire(time);

    if (r == 1)
    {
        self.weaponframe     = SH_CSSg550PickShootSeq(self.wep_action_id);
        self.wep_nextframe   = time + CSSG550_FRAME_INTERVAL;
        self.sg550_snd_stage = 0;

        W_CSSg550Shoot();

        // No zoomstage clear after the shot — SCOPE_CLASS_SNIPER_SEMI stays
        // scoped through fire.  Contrast W_AWPFire, which zeroes both here.
        sound(self, CHAN_WEAPON, "weapons/sg550-1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_CSSg550AltFire =
{
    if (SH_CSSg550TryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, CSSG550_ZOOM_SOUND, 1, ATTN_NORM);
    }
};

void() W_CSSg550Reload =
{
    if (SH_CSSg550TryReload(time))
    {
        self.weaponframe     = SH_CSSg550SeqReload();
        self.wep_nextframe   = time + CSSG550_FRAME_INTERVAL;
        self.sv_zoomstage    = 0;
        self.sg550_snd_stage = 0;
    }
};

void() W_CSSg550Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and fires
    // the timed sound events.  CHAN_AUTO so the predicted-sound dedup window
    // matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += CSSG550_FRAME_INTERVAL;

    // No WS_DRAW branch: v_sg550.mdl's draw sequence carries no studio event.

    if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_CSSg550ReloadDuration();

        if (elapsed >= rel * CSSG550_RELOAD_F_CLIPOUT && self.sg550_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/sg550_clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.sg550_snd_stage = 1;
        }
        if (elapsed >= rel * CSSG550_RELOAD_F_CLIPIN && self.sg550_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "weapons/sg550_clipin.wav", 1, ATTN_NORM);
            self.sg550_snd_stage = 2;
        }
        if (elapsed >= rel * CSSG550_RELOAD_F_BOLT && self.sg550_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "weapons/sg550_boltpull.wav", 1, ATTN_NORM);
            self.sg550_snd_stage = 3;
        }
    }

    result = SH_CSSg550TickState(time);
    if (result & 1)
    {
        self.weaponframe     = SH_CSSg550SeqIdle();
        self.wep_nextframe   = 0;
        self.sg550_snd_stage = 0;
    }
};

void() W_CSSg550Equip =
{
    // weapon_scope_class is what makes the CoD scope stay up through a shot
    // (cl_codscope.qc's fire_scopes_out test) and what keeps the stamina drain
    // running while scoped (sh_pmove.qc, which already names the SG550 in its
    // SCOPE_CLASS_SNIPER_SEMI comment).  It is NOT replicated — CSQC_CSSg550Equip
    // has to make the identical call.
    W_SetADSProfile(FALSE, "cl_ads_cssg550", SCOPE_CLASS_SNIPER_SEMI);
    W_StandardEquipSetup(CSSG550_VIEWMODEL, CSSG550_DISPLAY_NAME, SH_CSSg550SeqDraw(),
        CSSG550_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CSSg550Fire;
    self.altfire  = W_CSSg550AltFire;
    self.reload   = W_CSSg550Reload;
    self.wepframe = W_CSSg550Frame;
    self.shoot    = W_CSSg550Shoot;
    self.sg550_snd_stage = 0;
    W_ClearZoom();
    W_SetCrosshairProfile(CSSG550_BASE_SPREAD, CSSG550_MOVE_SPREAD, CSSG550_FULL_SPREAD_SPEED, 2.0, TRUE);
};

void() W_CSSg550Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_sg550  = self.mag_sg550;
    tgt.ammo_sg550 = self.ammo_sg550;

    self.mag_sg550  = 0;
    self.ammo_sg550 = 0;

    setmodel(tgt, CSSG550_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_sg550";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_CSSG550;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_CSSg550Equip;
    tgt.weap_drop_func = W_CSSg550Drop;
    tgt.pickupcopy     = W_CSSg550PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

// Takes the REAL Counter-Strike classname.  weapon_sg550 had zero references in
// this tree before this weapon existed — the CF Dragunov holds the "sg550"
// MANIFEST KEY, not the classname — so nothing is displaced and a GoldSrc CS
// map placing one now gets the SG-550 rather than "no spawn function".
void() weapon_sg550 =
{
    setmodel(self, CSSG550_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_sg550";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_CSSG550;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_CSSg550Equip;
    self.weap_drop_func = W_CSSg550Drop;
    self.pickupcopy     = W_CSSg550PickupCopy;
    self.touch          = weapon_touch;
    self.mag_sg550      = MAX_MAG_CSSG550;
    self.ammo_sg550     = MAX_AMMO_CSSG550;
    W_RegisterMapWeapon(weapon_sg550);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_sg550_snd_stage;
float csqc_sg550_snd_action;

void() CSQC_PredictCSSg550Command =
{
    float r;
    float elapsed;

    // Reset the sound stage on action change so each reload fires its events
    // exactly once even when pmove replay re-runs the same buffered command.
    if (predicted_player.wep_action_id != csqc_sg550_snd_action)
    {
        csqc_sg550_snd_action = predicted_player.wep_action_id;
        csqc_sg550_snd_stage  = 0;
    }

    // Alt-fire: zoom toggle.  Same predicate and same sample as W_CSSg550AltFire.
    if (input_buttons & 4)
    {
        if (SH_CSSg550TryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound(CSSG550_ZOOM_SOUND);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_CSSg550TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/sg550-1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                // Mirrors W_CSSg550Shoot's two arms exactly — scoped drops the
                // base spread to zero and keeps the movement term.
                CSQC_PredictedPenetratingImpact(self.zoomstage > 0 ? 0 : CSSG550_BASE_SPREAD,
                    CSSG550_MOVE_SPREAD, CSSG550_FULL_SPREAD_SPEED,
                    CSSG550_CLOSE_DAMAGE, CSSG550_MIN_DAMAGE, CSSG550_DAMAGE_FALLOFF_RANGE, 96, 0.98,
                    CSSG550_KICK_PITCH, CSSG550_KICK_VARIANCE, CSSG550_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(CSSG550_MUZZLE_FORWARD, CSSG550_MUZZLE_RIGHT,
                    CSSG550_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(CSSG550_MUZZLE_FORWARD, CSSG550_MUZZLE_RIGHT,
                    CSSG550_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
            }
            // No zoomstage clear — see SH_CSSg550TryFire.
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

    // Predicted reload sounds — the same three marks, off the same resolved
    // duration, as W_CSSg550Frame, so the dedup window suppresses the server
    // echo.  No draw branch: the draw sequence carries no event.
    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_RELOAD)
        {
            float rel = SH_CSSg550ReloadDuration();

            if (csqc_sg550_snd_stage < 1 && elapsed >= rel * CSSG550_RELOAD_F_CLIPOUT)
            {
                localsound("weapons/sg550_clipout.wav");
                CSQC_RecordPredictedAutoSound();
                CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
                csqc_sg550_snd_stage = 1;
            }
            if (csqc_sg550_snd_stage < 2 && elapsed >= rel * CSSG550_RELOAD_F_CLIPIN)
            {
                localsound("weapons/sg550_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sg550_snd_stage = 2;
            }
            if (csqc_sg550_snd_stage < 3 && elapsed >= rel * CSSG550_RELOAD_F_BOLT)
            {
                localsound("weapons/sg550_boltpull.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_sg550_snd_stage = 3;
            }
        }
    }

    SH_CSSg550TickState(csqc_pred_time);
};

void() CSQC_PredictCSSg550Reload =
{
    if (SH_CSSg550TryReload(csqc_pred_time))
    {
        csqc_sg550_snd_stage  = 0;
        csqc_sg550_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  The shoot
// pick goes through the shared helper against predicted_player's action id,
// which is the same value W_CSSg550Fire hashed on the server.
float(float elapsed) CSQC_CSSg550DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_CSSg550SeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_CSSg550SeqReload();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_CSSg550PickShootSeq(predicted_player.wep_action_id);

    return SH_CSSg550SeqIdle();
};

void() CSQC_CSSg550DropClear =
{
    self.mag_sg550  = 0;
    self.ammo_sg550 = 0;
    self.zoomstage  = 0;
};

void() CSQC_CSSg550Equip =
{
    // MUST mirror W_CSSg550Equip's call.  weapon_scope_class is not replicated
    // and CSQC_WeaponEquip zeroes all three ADS fields on every weapon change;
    // omitting this leaves the client at SCOPE_CLASS_NONE, CodScope_Eligible()
    // rejects the weapon, and because SH_CSSg550TryAltFire deliberately stands
    // down when sv_codscopes is set, +attack2 would fall between the two systems
    // and do nothing at all.  That exact bug is documented in sh_wpn_thm14.qc.
    W_SetADSProfile(FALSE, "cl_ads_cssg550", SCOPE_CLASS_SNIPER_SEMI);
    self.weapon_name         = CSSG550_DISPLAY_NAME;
    self.weapon_viewmodel    = CSSG550_VIEWMODEL;
    self.weapon_worldmodel   = CSSG550_WORLDMODEL;
    self.weapon_deploy_sound = CSSG550_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCSSg550Command;
    self.csqc_predict_reload = CSQC_PredictCSSg550Reload;
    self.csqc_display_frame  = CSQC_CSSg550DisplayFrame;
    self.csqc_drop_clear     = CSQC_CSSg550DropClear;
    // GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
    // animates within it via .frame1time.  Without this flag
    // CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
    // sits frozen on the first frame of whatever sequence we set.
    self.weapon_uses_sequences = TRUE;
    // FLIPPED — reported left-handed in game.  sh_wpn_csglock.qc:664 already
    // listed this weapon as one of the ten drawing the same stock cstrike arm
    // and needing the same flip once it was reported.  The rhand/lhand meshes
    // here are byte-identical to the flipped handguns'.  cl_lefthand still XORs.
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
