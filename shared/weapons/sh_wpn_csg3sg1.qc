// ============================================================
//  shared/weapons/sh_wpn_csg3sg1.qc  -  CS G3SG1
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 60 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Scope : 2-stage zoom cycle via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_g3sg1;
.float ammo_g3sg1;

// --- Sequence indices (GoldSrc IDST viewmodel) ---
//
// These are FALLBACKS.  Every one is resolved by NAME at runtime through
// SH_SeqForName, so a model swap that reorders its sequences cannot silently
// point "reload" at the holster anim.  The numbers below are the layout of
// cstrike/models/v_g3sg1.mdl and are used only if the loaded model carries no
// sequence names at all.
//
//   idx  label     frames   fps     dur
//     0  idle1         11  16.0   0.625
//     1  shoot         16  30.0   0.500   event 5001(22)
//     2  shoot2        16  30.0   0.500   event 5001(22)
//     3  reload       141  30.0   4.667   events at f16/f54/f85/f116
//     4  draw          31  30.0   1.000
//
// This file previously drove a flat IDPO frame bake (wpn_csg3sg1/v_g3sg1.mdl,
// 157 frames named frame0..frame156) with hand-guessed ranges marked
// "placeholder — user will tune".  Those names carry no information: FTE
// groups Quake MDL frames by stripping trailing digits, so that model exposes
// exactly ONE group, named "frame".  The ranges could not be recovered from it
// and are not recoverable — the bake is 157 frames against the original's 215.
// Same migration the crowbar made (see sh_wpn_hlcrowbar.qc:12).
const float G3SG1_SEQ_IDLE   = 0;
const float G3SG1_SEQ_SHOOT1 = 1;
const float G3SG1_SEQ_SHOOT2 = 2;
const float G3SG1_SEQ_RELOAD = 3;
const float G3SG1_SEQ_DRAW   = 4;

const float G3SG1_FRAME_INTERVAL      = 0.0333334;   // state-machine tick rate
const float G3SG1_FIRE_DELAY          = 0.25;

// Reload event marks as a FRACTION of the reload sequence, not absolute
// seconds.  The model's studio events sit at frames 16/54/85/116 of 141, and
// frameduration divides by (numframes-1) = 140.  Fractions are load-bearing
// here: cstrike and czero are BOTH mounted (fs_addons.txt:16-17), both ship
// models/v_g3sg1.mdl, and their reload is the same 141 frames at DIFFERENT fps
// — 4.667 s vs 3.590 s.  Whichever mount wins, scaling by that model's own
// duration keeps the sounds on the animation.
const float G3SG1_RELOAD_F_SLIDE1  = 0.1143;   // frame  16 / 140
const float G3SG1_RELOAD_F_CLIPOUT = 0.3857;   // frame  54 / 140
const float G3SG1_RELOAD_F_CLIPIN  = 0.6071;   // frame  85 / 140
const float G3SG1_RELOAD_F_SLIDE2  = 0.8286;   // frame 116 / 140
const float G3SG1_RELOAD_F_APPLY   = 0.6500;   // just after the fresh mag seats

// Per-entity reload sound stage (server).  The old frame-stepping code compared
// weaponframe against absolute frame numbers; a sequence-driven model never
// steps weaponframe, so stages are latched off elapsed time instead.
.float g3sg1_reload_snd_stage;

const float MAX_MAG_G3SG1             = 20;
const float MAX_AMMO_G3SG1            = 60;

// --- Balance ---
const float G3SG1_BASE_SPREAD          = 0.01;
const float G3SG1_MOVE_SPREAD          = 0.08;
const float G3SG1_FULL_SPREAD_SPEED    = 320;
const float G3SG1_CLOSE_DAMAGE         = 60;
const float G3SG1_MIN_DAMAGE           = 40;
const float G3SG1_DAMAGE_FALLOFF_RANGE = 4096;
const float G3SG1_DRYFIRE_DELAY        = 0.2;
const float G3SG1_KICK_PITCH    = 1.4;   // sv_gunkick — semi-auto sniper.
const float G3SG1_KICK_VARIANCE = 0.4;
const float G3SG1_KICK_STRENGTH = 1.0;   // semi-auto — moderate per-shot delay.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float G3SG1_MUZZLE_FORWARD = 52;
const float G3SG1_MUZZLE_RIGHT   = 7;
const float G3SG1_MUZZLE_DOWN    = 4.55;

// Resolves off the mounted cstrike gamedir (fs_addons.txt:16), exactly the way
// the crowbar takes models/v_crowbar.mdl from the valve mount.  The world model
// stays the mod's own — only the viewmodel needed its animations back.
const string G3SG1_VIEWMODEL    = "models/v_g3sg1.mdl";
const string G3SG1_WORLDMODEL   = "models/w_g3sg1.mdl";
const string G3SG1_DEPLOY_SOUND = "";
const string G3SG1_DISPLAY_NAME = "G3SG1";

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_G3SG1SeqIdle   = { return SH_SeqForName(G3SG1_VIEWMODEL, "idle1",  G3SG1_SEQ_IDLE); };
float() SH_G3SG1SeqShoot1 = { return SH_SeqForName(G3SG1_VIEWMODEL, "shoot",  G3SG1_SEQ_SHOOT1); };
float() SH_G3SG1SeqShoot2 = { return SH_SeqForName(G3SG1_VIEWMODEL, "shoot2", G3SG1_SEQ_SHOOT2); };
float() SH_G3SG1SeqReload = { return SH_SeqForName(G3SG1_VIEWMODEL, "reload", G3SG1_SEQ_RELOAD); };
float() SH_G3SG1SeqDraw   = { return SH_SeqForName(G3SG1_VIEWMODEL, "draw",   G3SG1_SEQ_DRAW); };

// Deterministic shoot-sequence pick from wep_action_id so client and server
// agree which of shoot/shoot2 plays for this shot (CFGLOCK pattern).
float() SH_G3SG1PickShootSeq =
{
    if (SH_SpreadHash(self.wep_action_id) < 0.5)
        return SH_G3SG1SeqShoot1();
    return SH_G3SG1SeqShoot2();
};

// Durations come from the model that actually loaded, never from a constant —
// see the fps note on the reload fractions above.
float() SH_G3SG1DrawDuration   = { return SH_SeqDuration(G3SG1_VIEWMODEL, SH_G3SG1SeqDraw(),   1.000); };
float() SH_G3SG1ReloadDuration = { return SH_SeqDuration(G3SG1_VIEWMODEL, SH_G3SG1SeqReload(), 4.667); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_G3SG1TickState =
{
    float rel = SH_G3SG1ReloadDuration();
    return SH_StandardTickState(now, mag_g3sg1, ammo_g3sg1, MAX_MAG_G3SG1,
        SH_G3SG1DrawDuration(),
        SH_SeqDuration(G3SG1_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel * G3SG1_RELOAD_F_APPLY);
};

// Don't clear zoomstage here — Shoot needs it for spread.
// Cleared in Fire/prediction AFTER the shot.
float(float now) SH_G3SG1TryFire =
{
    return SH_StandardTryFire(now, mag_g3sg1, G3SG1_FIRE_DELAY, G3SG1_DRYFIRE_DELAY);
};

float(float now) SH_G3SG1TryReload =
{
    float r = SH_StandardTryReload(now, mag_g3sg1, ammo_g3sg1, MAX_MAG_G3SG1,
        SH_G3SG1ReloadDuration());
    if (r == 1)
        self.zoomstage = 0;
    return r;
};

float(float now) SH_G3SG1TryAltFire =
{
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

void(entity player) W_G3SG1PickupCopy =
{
    player.mag_g3sg1  = self.mag_g3sg1;
    player.ammo_g3sg1 = self.ammo_g3sg1;
};

void() W_G3SG1Shoot =
{
    // Scoped: zero base spread, movement still applies
    if (self.zoomstage > 0)
        W_PenetratingHitscanShoot(0, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED,
            G3SG1_CLOSE_DAMAGE, G3SG1_MIN_DAMAGE, G3SG1_DAMAGE_FALLOFF_RANGE, 96, 0.98,
            G3SG1_KICK_PITCH, G3SG1_KICK_VARIANCE, G3SG1_KICK_STRENGTH);
    else
        W_PenetratingHitscanShoot(G3SG1_BASE_SPREAD, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED,
            G3SG1_CLOSE_DAMAGE, G3SG1_MIN_DAMAGE, G3SG1_DAMAGE_FALLOFF_RANGE, 96, 0.98,
            G3SG1_KICK_PITCH, G3SG1_KICK_VARIANCE, G3SG1_KICK_STRENGTH);
};

void() W_G3SG1Fire =
{
    float r = SH_G3SG1TryFire(time);
    if (r == 1)
    {
        self.weaponframe   = SH_G3SG1PickShootSeq();
        self.wep_nextframe = time + G3SG1_FRAME_INTERVAL;
        W_G3SG1Shoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csg3sg1/fire.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_G3SG1AltFire =
{
    if (SH_G3SG1TryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_G3SG1Reload =
{
    if (SH_G3SG1TryReload(time))
    {
        self.weaponframe   = SH_G3SG1SeqReload();
        self.wep_nextframe = time + G3SG1_FRAME_INTERVAL;
        self.sv_zoomstage = 0;
        self.g3sg1_reload_snd_stage = 0;
    }
};

void() W_G3SG1Frame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // Sequence-driven model — DO NOT step weaponframe per tick.  The engine
    // animates within the sequence; this only ticks the state machine and
    // fires timed sound events.  CHAN_AUTO so the predicted-sound dedup
    // window matches CSQC_RecordPredictedAutoSound on the client.
    self.wep_nextframe += G3SG1_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        float rel = SH_G3SG1ReloadDuration();
        if (elapsed >= rel * G3SG1_RELOAD_F_SLIDE1 && self.g3sg1_reload_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/slide.wav", 1, ATTN_NORM);
            self.g3sg1_reload_snd_stage = 1;
        }
        if (elapsed >= rel * G3SG1_RELOAD_F_CLIPOUT && self.g3sg1_reload_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/clipout.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
            self.g3sg1_reload_snd_stage = 2;
        }
        if (elapsed >= rel * G3SG1_RELOAD_F_CLIPIN && self.g3sg1_reload_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/clipin.wav", 1, ATTN_NORM);
            self.g3sg1_reload_snd_stage = 3;
        }
        if (elapsed >= rel * G3SG1_RELOAD_F_SLIDE2 && self.g3sg1_reload_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csg3sg1/slide.wav", 1, ATTN_NORM);
            self.g3sg1_reload_snd_stage = 4;
        }
    }

    result = SH_G3SG1TickState(time);
    if (result & 1)
    {
        self.weaponframe = SH_G3SG1SeqIdle();
        self.wep_nextframe = 0;
        self.g3sg1_reload_snd_stage = 0;
    }
};

void() W_G3SG1Equip =
{
    // Semi-auto sniper: it stays scoped through the shot, unlike the AWP and
    // Scout's SCOPE_CLASS_SNIPER_BOLT — the same class the SG550 carries.  This
    // profile was simply missing, which left weapon_scope_class at 0 and gave
    // the gun no ADS/scope handling at all under sv_codscopes.
    W_SetADSProfile(FALSE, "cl_ads_csg3sg1", SCOPE_CLASS_SNIPER_SEMI);
    W_StandardEquipSetup(G3SG1_VIEWMODEL, G3SG1_DISPLAY_NAME, SH_G3SG1SeqDraw(),
        G3SG1_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_G3SG1Fire;
    self.reload   = W_G3SG1Reload;
    self.wepframe = W_G3SG1Frame;
    self.altfire  = W_G3SG1AltFire;
    self.shoot    = W_G3SG1Shoot;
    self.g3sg1_reload_snd_stage = 0;
    W_ClearZoom();
    W_SetCrosshairProfile(G3SG1_BASE_SPREAD, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED, 1.5, FALSE);
};

void() W_G3SG1Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_g3sg1  = self.mag_g3sg1;
    tgt.ammo_g3sg1 = self.ammo_g3sg1;
    self.mag_g3sg1  = 0;
    self.ammo_g3sg1 = 0;

    setmodel(tgt, "models/w_g3sg1.mdl");
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_g3sg1";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_G3SG1;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_G3SG1Equip;
    tgt.weap_drop_func = W_G3SG1Drop;
    tgt.pickupcopy   = W_G3SG1PickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_g3sg1 =
{
    setmodel(self, "models/w_g3sg1.mdl");
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_g3sg1";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_G3SG1;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_G3SG1Equip;
    self.weap_drop_func = W_G3SG1Drop;
    self.pickupcopy    = W_G3SG1PickupCopy;
    self.touch         = weapon_touch;
    self.mag_g3sg1     = MAX_MAG_G3SG1;
    self.ammo_g3sg1    = MAX_AMMO_G3SG1;
    W_RegisterMapWeapon(weapon_g3sg1);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_g3sg1_reload_snd_stage;

void() CSQC_PredictG3SG1Command =
{
    float r;

    // Alt-fire: zoom toggle
    if (input_buttons & 4)
    {
        if (SH_G3SG1TryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_G3SG1TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csg3sg1/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(self.zoomstage > 0 ? 0 : G3SG1_BASE_SPREAD, G3SG1_MOVE_SPREAD, G3SG1_FULL_SPREAD_SPEED,
                    G3SG1_CLOSE_DAMAGE, G3SG1_MIN_DAMAGE, G3SG1_DAMAGE_FALLOFF_RANGE, 96, 0.98,
                    G3SG1_KICK_PITCH, G3SG1_KICK_VARIANCE, G3SG1_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // Sniper muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(G3SG1_MUZZLE_FORWARD, G3SG1_MUZZLE_RIGHT,
                    G3SG1_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(G3SG1_MUZZLE_FORWARD, G3SG1_MUZZLE_RIGHT,
                    G3SG1_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted reload sounds
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float rel = SH_G3SG1ReloadDuration();
        if (csqc_g3sg1_reload_snd_stage < 1 && reload_elapsed >= rel * G3SG1_RELOAD_F_SLIDE1)
        { localsound("sounds/weapons/wpn_csg3sg1/slide.wav"); CSQC_RecordPredictedAutoSound(); csqc_g3sg1_reload_snd_stage = 1; }
        if (csqc_g3sg1_reload_snd_stage < 2 && reload_elapsed >= rel * G3SG1_RELOAD_F_CLIPOUT)
        {
            localsound("sounds/weapons/wpn_csg3sg1/clipout.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/riflemag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_g3sg1_reload_snd_stage = 2;
        }
        if (csqc_g3sg1_reload_snd_stage < 3 && reload_elapsed >= rel * G3SG1_RELOAD_F_CLIPIN)
        { localsound("sounds/weapons/wpn_csg3sg1/clipin.wav"); CSQC_RecordPredictedAutoSound(); csqc_g3sg1_reload_snd_stage = 3; }
        if (csqc_g3sg1_reload_snd_stage < 4 && reload_elapsed >= rel * G3SG1_RELOAD_F_SLIDE2)
        { localsound("sounds/weapons/wpn_csg3sg1/slide.wav"); CSQC_RecordPredictedAutoSound(); csqc_g3sg1_reload_snd_stage = 4; }
    }

    SH_G3SG1TickState(csqc_pred_time);
};

void() CSQC_PredictG3SG1Reload =
{
    if (SH_G3SG1TryReload(csqc_pred_time))
    { csqc_g3sg1_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Sequence-driven: return the SEQUENCE index, not a stepped frame.  The pick
// mirrors SH_G3SG1PickShootSeq but reads predicted_player, which is the entity
// the display path owns (self is not the player here).
float(float elapsed) CSQC_G3SG1DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_G3SG1SeqDraw();
    if (predicted_player.weaponstate == WS_FIRE)
    {
        if (SH_SpreadHash(predicted_player.wep_action_id) < 0.5)
            return SH_G3SG1SeqShoot1();
        return SH_G3SG1SeqShoot2();
    }
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_G3SG1SeqReload();

    return SH_G3SG1SeqIdle();
};

void() CSQC_G3SG1DropClear =
{
	self.mag_g3sg1 = 0;
	self.ammo_g3sg1 = 0;
	self.zoomstage = 0;
};

void() CSQC_G3SG1Equip =
{
	W_SetADSProfile(FALSE, "cl_ads_csg3sg1", SCOPE_CLASS_SNIPER_SEMI);
	self.weapon_name         = G3SG1_DISPLAY_NAME;
	self.weapon_viewmodel    = G3SG1_VIEWMODEL;
	self.weapon_worldmodel   = G3SG1_WORLDMODEL;
	self.weapon_deploy_sound = G3SG1_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictG3SG1Command;
	self.csqc_predict_reload = CSQC_PredictG3SG1Reload;
	self.csqc_display_frame  = CSQC_G3SG1DisplayFrame;
	self.csqc_drop_clear     = CSQC_G3SG1DropClear;
	// GoldSrc-format viewmodel: .frame holds the SEQUENCE index and the engine
	// animates within it via .frame1time.  Without this flag
	// CSQC_AddPredictedViewmodel takes the frame-stepping branch and the model
	// sits frozen on the first frame of whatever sequence we set.
	self.weapon_uses_sequences = TRUE;
	// FLIPPED — reported left-handed in game.  models/v_g3sg1.mdl draws the same
	// stock cstrike arm as v_aug / v_sg550 / v_glock18, every one of which is
	// flipped; this was the one long arm in the set the flip had been left
	// commented out on.  cl_lefthand XORs against it, so reverting is one word.
	self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
