// ============================================================
//  shared/weapons/sh_wpn_svuzi.qc  -  Sven Co-op UZI (single)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//          Moved off SLOT_SECONDARY - see the note beside WMF_WEP_UZI in
//          sh_weapon_manifest.qc.  This value and the manifest's MUST agree:
//          weapon_touch routes a floor pickup by .weapon_slot while the
//          slot-ammo bridge derives the slot from the manifest, so a mismatch
//          silently puts the gun in one slot and its ammo in another.
//  Stats : 32-round magazine, 250 reserve, full-auto, 9mm
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6975 (weapon_uzi, "Single UZI (2 UZIs for
//  Akimbo)"), svencoop/models/{v,p,w}_uzi.mdl and the 17-file
//  svencoop/sound/weapons/uzi/ set.
//
//  Previously an alias onto WEP_CFMAC10 carrying w_uzi.mdl
//  (sv_goldsrc_pickups.qc:340) — so a map that placed an UZI handed you a
//  CrossFire MAC-10 that happened to be wearing an UZI on the ground.  Every
//  asset for the real thing was on the mount and unused, including the akimbo
//  half that sh_wpn_svuziakimbo.qc now uses.

// --- Ammo fields ---
.float mag_uzi;
.float ammo_uzi;

.float uzi_reload_snd_stage;

// --- Sequence indices, read out of svencoop/models/v_uzi.mdl (17 seqs) -------
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
//
// The file holds BOTH weapons: 0-7 are the single UZI, 8-16 are the akimbo pair
// (see sh_wpn_svuziakimbo.qc, which points at the same model).  That is also why
// there is no v_2uzis.mdl on the mount and why looking for one is a dead end.
//
// Sequences 6 and 7 are duplicate takes of draw and idle2; only 0-5 are used.
const float UZI_SEQ_IDLE1   = 0;   // idle1,  1.000 s  (61f @ 60)  LOOPING
const float UZI_SEQ_IDLE2   = 1;   // idle2,  3.000 s  (61f @ 20)
const float UZI_SEQ_IDLE3   = 2;   // idle3,  1.167 s  (71f @ 60)
const float UZI_SEQ_RELOAD  = 3;   // reload, 2.667 s (161f @ 60)
const float UZI_SEQ_DRAW    = 4;   // draw,   0.900 s  (55f @ 60)
const float UZI_SEQ_SHOOT   = 5;   // shoot,  0.533 s  (33f @ 60)

const float UZI_FRAME_INTERVAL = 0.05;   // wepframe tick rate, not an anim rate

// The real UZI's cyclic rate is about 600 rpm.  0.1 s is that, and it is also
// what keeps it distinct from the MAC-10 it used to impersonate, which is faster
// and less accurate.
const float UZI_FIRE_DELAY     = 0.1;
const float UZI_DRYFIRE_DELAY  = 0.2;

const float MAX_MAG_UZI        = 32;    // the UZI's own magazine
const float MAX_AMMO_UZI       = 250;

// Reload sound instants, elapsed from wep_anim_start, spread across the 2.667 s
// animation.  The set has three reload samples and the animation has three
// beats — magazine out, magazine in, bolt.
const float UZI_RELOAD_SND1_TIME = 0.45;
const float UZI_RELOAD_SND2_TIME = 1.40;
const float UZI_RELOAD_SND3_TIME = 2.20;

// --- Balance ---
// A 9mm SMG, so it takes the Half-Life MP5's damage numbers — the same reasoning
// sh_wpn_thgreasegun.qc uses for the same calibre.  Slightly tighter base cone
// than the MAC-10 it replaces: the UZI is the more controllable of the two.
const float UZI_BASE_SPREAD          = 0.02618;   // VECTOR_CONE_3DEGREES
const float UZI_MOVE_SPREAD          = 0.07;
const float UZI_FULL_SPREAD_SPEED    = 320;
const float UZI_CLOSE_DAMAGE         = 10;
const float UZI_MIN_DAMAGE           = 5;
const float UZI_DAMAGE_FALLOFF_RANGE = 2048;
const float UZI_KICK_PITCH    = 0.55;
const float UZI_KICK_VARIANCE = 0.3;
const float UZI_KICK_STRENGTH = 1.4;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float UZI_MUZZLE_FORWARD = 30;
const float UZI_MUZZLE_RIGHT   = 4.0;
const float UZI_MUZZLE_DOWN    = 5.0;

// --- State durations, taken from the sequences themselves ---
const float UZI_DRAW_DURATION   = 0.900;
const float UZI_FIRE_DURATION   = 0.533;
const float UZI_RELOAD_DURATION = 2.667;

const string UZI_VIEWMODEL    = "models/v_uzi.mdl";
const string UZI_WORLDMODEL   = "models/w_uzi.mdl";
const string UZI_DEPLOY_SOUND = "weapons/uzi/deploy.wav";
const string UZI_DISPLAY_NAME = "UZI";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// Three shoot samples, cycled off wep_action_id rather than rolled so the
// predicted sound and the server's agree.  `x - floor(x/n)*n` is this codebase's
// fmod idiom (sh_pmove.qc:2578); there is no `%` operator.
string(float shot_id) SH_UziShootSound =
{
    float n = shot_id - floor(shot_id / 3) * 3;
    if (n == 0) return "weapons/uzi/shoot1.wav";
    if (n == 1) return "weapons/uzi/shoot2.wav";
    return "weapons/uzi/shoot3.wav";
};

float(float now) SH_UziTickState =
{
    return SH_StandardTickState(now, mag_uzi, ammo_uzi, MAX_MAG_UZI,
        UZI_DRAW_DURATION, UZI_FIRE_DURATION, UZI_RELOAD_DURATION, UZI_RELOAD_DURATION);
};

float(float now) SH_UziTryFire =
{
    return SH_StandardTryFire(now, mag_uzi, UZI_FIRE_DELAY, UZI_DRYFIRE_DELAY);
};

float(float now) SH_UziTryReload =
{
    return SH_StandardTryReload(now, mag_uzi, ammo_uzi, MAX_MAG_UZI, UZI_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_UziPickupCopy =
{
    player.mag_uzi  = self.mag_uzi;
    player.ammo_uzi = self.ammo_uzi;
};

void() W_UziShoot =
{
    W_PenetratingHitscanShoot(UZI_BASE_SPREAD, UZI_MOVE_SPREAD, UZI_FULL_SPREAD_SPEED,
        UZI_CLOSE_DAMAGE, UZI_MIN_DAMAGE, UZI_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        UZI_KICK_PITCH, UZI_KICK_VARIANCE, UZI_KICK_STRENGTH);
};

void() W_UziFire =
{
    float r = SH_UziTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = UZI_SEQ_SHOOT;
        self.wep_nextframe = time + UZI_FRAME_INTERVAL;

        W_UziShoot();

        sound(self, CHAN_WEAPON, SH_UziShootSound(self.wep_action_id), 1, ATTN_NORM);
        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_UziReload =
{
    if (SH_UziTryReload(time))
    {
        self.weaponframe   = UZI_SEQ_RELOAD;
        self.wep_nextframe = time + UZI_FRAME_INTERVAL;
        self.uzi_reload_snd_stage = 0;
    }
};

void() W_UziFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += UZI_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float el = time - self.wep_anim_start;
        if (self.uzi_reload_snd_stage < 1 && el >= UZI_RELOAD_SND1_TIME)
        { sound(self, CHAN_AUTO, "weapons/uzi/reload1.wav", 1, ATTN_NORM); self.uzi_reload_snd_stage = 1; }
        if (self.uzi_reload_snd_stage < 2 && el >= UZI_RELOAD_SND2_TIME)
        { sound(self, CHAN_AUTO, "weapons/uzi/reload2.wav", 1, ATTN_NORM); self.uzi_reload_snd_stage = 2; }
        if (self.uzi_reload_snd_stage < 3 && el >= UZI_RELOAD_SND3_TIME)
        { sound(self, CHAN_AUTO, "weapons/uzi/reload3.wav", 1, ATTN_NORM); self.uzi_reload_snd_stage = 3; }
    }

    result = SH_UziTickState(time);
    if (result & 1)
    {
        // idle1 carries STUDIO_LOOPING, so the resting pose is safe to hold —
        // no SH_SeqIdleDisplay re-send needed (the trap is written up in
        // sh_wpn_thspanner.qc).
        self.weaponframe = UZI_SEQ_IDLE1;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).
        self.wep_nextframe = 0;
    }
};

void() W_UziEquip =
{
    W_StandardEquipSetup(UZI_VIEWMODEL, UZI_DISPLAY_NAME, UZI_SEQ_DRAW,
        UZI_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_UziFire;
    self.reload   = W_UziReload;
    self.wepframe = W_UziFrame;
    self.shoot    = W_UziShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(UZI_BASE_SPREAD, UZI_MOVE_SPREAD, UZI_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_UziDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_uzi  = self.mag_uzi;
    tgt.ammo_uzi = self.ammo_uzi;
    self.mag_uzi  = 0;
    self.ammo_uzi = 0;

    setmodel(tgt, UZI_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_uzi";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_UZI;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_UziEquip;
    tgt.weap_drop_func = W_UziDrop;
    tgt.pickupcopy     = W_UziPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_uzi =
{
    setmodel(self, UZI_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_uzi";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_UZI;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_UziEquip;
    self.weap_drop_func = W_UziDrop;
    self.pickupcopy     = W_UziPickupCopy;
    self.touch          = weapon_touch;
    self.mag_uzi        = MAX_MAG_UZI;
    self.ammo_uzi       = MAX_AMMO_UZI;
    W_RegisterMapWeapon(weapon_uzi);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_uzi_reload_snd_stage;

void() CSQC_PredictUziCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_UziTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound(SH_UziShootSound(self.wep_action_id));
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(UZI_BASE_SPREAD, UZI_MOVE_SPREAD, UZI_FULL_SPREAD_SPEED,
                    UZI_CLOSE_DAMAGE, UZI_MIN_DAMAGE, UZI_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    UZI_KICK_PITCH, UZI_KICK_VARIANCE, UZI_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(UZI_MUZZLE_FORWARD, UZI_MUZZLE_RIGHT,
                    UZI_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(UZI_MUZZLE_FORWARD, UZI_MUZZLE_RIGHT,
                    UZI_MUZZLE_DOWN, self.wep_action_id, 1);
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

    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float el = csqc_pred_time - self.wep_anim_start;
        if (csqc_uzi_reload_snd_stage < 1 && el >= UZI_RELOAD_SND1_TIME)
        { localsound("weapons/uzi/reload1.wav"); CSQC_RecordPredictedAutoSound(); csqc_uzi_reload_snd_stage = 1; }
        if (csqc_uzi_reload_snd_stage < 2 && el >= UZI_RELOAD_SND2_TIME)
        { localsound("weapons/uzi/reload2.wav"); CSQC_RecordPredictedAutoSound(); csqc_uzi_reload_snd_stage = 2; }
        if (csqc_uzi_reload_snd_stage < 3 && el >= UZI_RELOAD_SND3_TIME)
        { localsound("weapons/uzi/reload3.wav"); CSQC_RecordPredictedAutoSound(); csqc_uzi_reload_snd_stage = 3; }
    }

    SH_UziTickState(csqc_pred_time);
};

void() CSQC_PredictUziReload =
{
    if (SH_UziTryReload(csqc_pred_time))
    { csqc_uzi_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_UziDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return UZI_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return UZI_SEQ_SHOOT;
    if (predicted_player.weaponstate == WS_RELOAD)
        return UZI_SEQ_RELOAD;
    return UZI_SEQ_IDLE1;   // LOOPING — safe to hold
};

void() CSQC_UziDropClear =
{
    self.mag_uzi  = 0;
    self.ammo_uzi = 0;
};

void() CSQC_UziEquip =
{
    self.weapon_name         = UZI_DISPLAY_NAME;
    self.weapon_viewmodel    = UZI_VIEWMODEL;
    self.weapon_worldmodel   = UZI_WORLDMODEL;
    self.weapon_deploy_sound = UZI_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictUziCommand;
    self.csqc_predict_reload = CSQC_PredictUziReload;
    self.csqc_display_frame  = CSQC_UziDisplayFrame;
    self.csqc_drop_clear     = CSQC_UziDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
