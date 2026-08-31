// ============================================================
//  shared/weapons/sh_wpn_svuziakimbo.qc  -  Sven Co-op akimbo UZIs
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//          Moved off SLOT_SECONDARY with the single UZI - see the note beside
//          WMF_WEP_UZI in sh_weapon_manifest.qc.  This value and the manifest's
//          must agree; sv_goldsrc_pickups.qc:157-164 names the failure mode.
//  Stats : 64-round magazine (two 32s), 250 reserve, full-auto, 9mm
//  Fire  : lag-compensated hitscan, both guns per trigger pull
//
//  This file is compiled by BOTH sv_progs and cl_progs.
//  MUST compile after sh_wpn_svuzi.qc — see the model note below.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6977 (weapon_uziakimbo, "Akimbo UZIs"),
//  svencoop/models/{p,w}_2uzis.mdl and the akimbo half of the
//  svencoop/sound/weapons/uzi/ set.
//
//  Previously an alias onto WEP_CFELITE carrying w_2uzis.mdl
//  (sv_goldsrc_pickups.qc:356) — CrossFire's Elite, a pair of pistols, standing
//  in for a pair of submachine guns.
//
//  THERE IS NO v_2uzis.mdl AND THAT IS NOT AN OMISSION.  The akimbo viewmodel is
//  sequences 8-16 of v_uzi.mdl; the single UZI is 0-7.  Both weapons point at the
//  same file and differ only in which sequences they play, which is why this unit
//  compiles after the single and reuses its VIEWMODEL constant.  Only p_ and w_
//  have separate akimbo files.

// --- Ammo fields ---
.float mag_uziakimbo;
.float ammo_uziakimbo;

.float uziak_reload_snd_stage;

// --- Sequence indices, read out of svencoop/models/v_uzi.mdl (17 seqs) -------
// The akimbo half.  Durations are (numframes-1)/fps, what frameduration()
// reports (gl_hlmdl.c:1542).  NONE of these nine carries STUDIO_LOOPING — see
// the idle note in CSQC_UziAkimboDisplayFrame.
const float UZIAK_SEQ_PULL         = 8;    // akimbo_pull,  1.850 s (112f @ 60)
const float UZIAK_SEQ_IDLE         = 9;    // akimbo_idle,  0.300 s  (19f @ 60)
const float UZIAK_SEQ_RELOAD_RIGHT = 10;   // reload_right, 1.800 s  (91f @ 50)
const float UZIAK_SEQ_RELOAD_LEFT  = 11;   // reload_left,  1.912 s (131f @ 68)
const float UZIAK_SEQ_RELOAD_BOTH  = 12;   // reload_both,  1.500 s  (91f @ 60)
// All three are labelled "shoot" in the model, but their EVENT tables differ and
// that is what distinguishes them (see SH_UziAkPickShootSeq).  Currently only
// SHOOT3 is used; these two are the one-gun-empty takes and are kept named so a
// later per-gun ammo split has them ready rather than rediscovering the mapping.
const float UZIAK_SEQ_SHOOT1       = 13;   // shoot, 0.600 s (37f @ 60) — LEFT gun only  (ev 5011)
const float UZIAK_SEQ_SHOOT2       = 14;   // shoot, 0.600 s (37f @ 60) — RIGHT gun only (ev 5001)
const float UZIAK_SEQ_SHOOT3       = 15;   // shoot, 0.600 s (37f @ 60) — BOTH guns (ev 5001+5011)
const float UZIAK_SEQ_DRAW         = 16;   // akimbo_draw,  1.000 s  (61f @ 60)

const float UZIAK_FRAME_INTERVAL = 0.05;

// Idle re-send window.  None of the akimbo sequences carries STUDIO_LOOPING, so
// the idle has to be re-sent periodically or the viewmodel clamps and freezes;
// 10/15 is the window the rest of the tree uses (opeagle, th1911, thgreasegun).
const float UZIAK_IDLE_REARM_MIN = 10;
const float UZIAK_IDLE_REARM_MAX = 15;

// Two guns alternating, so the felt rate of fire is double the single's — but
// each barrel still cycles at its own 600 rpm, which is what 0.05 s expresses.
const float UZIAK_FIRE_DELAY     = 0.05;
const float UZIAK_DRYFIRE_DELAY  = 0.2;

const float MAX_MAG_UZIAKIMBO    = 64;    // two 32-round magazines
const float MAX_AMMO_UZIAKIMBO   = 250;   // shares the 9mm reserve with the single

// reload_both is one animation with two magazine changes in it.
const float UZIAK_RELOAD_SND1_TIME = 0.30;
const float UZIAK_RELOAD_SND2_TIME = 0.95;

// --- Balance ---
// Same round, same damage — the trade for twice the volume of fire is accuracy,
// not stopping power.  A markedly wider base cone than the single and a much
// worse move penalty: you cannot aim two submachine guns.
const float UZIAK_BASE_SPREAD          = 0.05234;   // ~VECTOR_CONE_6DEGREES
const float UZIAK_MOVE_SPREAD          = 0.11;
const float UZIAK_FULL_SPREAD_SPEED    = 320;
const float UZIAK_CLOSE_DAMAGE         = 10;
const float UZIAK_MIN_DAMAGE           = 5;
const float UZIAK_DAMAGE_FALLOFF_RANGE = 2048;
const float UZIAK_KICK_PITCH    = 0.45;
const float UZIAK_KICK_VARIANCE = 0.4;
const float UZIAK_KICK_STRENGTH = 1.2;

// Camera-local fallback muzzle, used only when the bone lookup below fails.
const float UZIAK_MUZZLE_FORWARD = 30;
const float UZIAK_MUZZLE_RIGHT   = 6.0;
const float UZIAK_MUZZLE_DOWN    = 5.0;

// TWO GUNS MEANS TWO MUZZLES, and v_uzi.mdl has always carried both:
//
//   bone  0  "Mini-uzi"     parent -1     gun A root
//   bone  4  "Ejectport"    parent  3     gun A eject port
//   bone  5  "Mini-uzi01"   parent -1     gun B root
//   bone 10  "Ejectport01"  parent  9     gun B eject port
//   attachment 0  bone 0  org (0,-10,0)
//   attachment 1  bone 5  org (0,-10,0)
//
// The two $attachments are NAMELESS, so the BONES are the handle - gettagindex
// resolves bone names on a Half-Life model (com_mesh.c:7017 -> HLMDL_BoneForName),
// which is the same route cfddeagle's Bone11/Bone01 pair takes.  The offset is the
// model's own attachment origin, not a guess.
const string UZIAK_MUZZLE_BONE_RIGHT = "Mini-uzi";
#define UZIAK_MUZZLE_OFFSET_RIGHT    ('0 -10 0')
const string UZIAK_MUZZLE_BONE_LEFT  = "Mini-uzi01";
#define UZIAK_MUZZLE_OFFSET_LEFT     ('0 -10 0')

// --- State durations, taken from the sequences themselves ---
const float UZIAK_DRAW_DURATION   = 1.000;   // akimbo_draw
const float UZIAK_FIRE_DURATION   = 0.600;
const float UZIAK_RELOAD_DURATION = 1.500;   // reload_both

// v_uzi.mdl — the akimbo shares it.  w_/p_ are the only separate files.
const string UZIAK_WORLDMODEL   = "models/w_2uzis.mdl";
const string UZIAK_DEPLOY_SOUND = "weapons/uzi/akimbo_deploy.wav";
const string UZIAK_DISPLAY_NAME = "AKIMBO UZIS";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

// ONE GUN PER SHOT, ALTERNATING - which is what every balance number in this file
// was already written for and what nothing else in it did.
//
// v_uzi.mdl's own event table:
//     seq 13  one muzzleflash event (5011)  -> LEFT gun only
//     seq 14  one muzzleflash event (5001)  -> RIGHT gun only
//     seq 15  BOTH events (5001 + 5011)     -> both guns
//
// A previous pass cycled 13/14/15 shot-to-shot, which animated left, then right,
// then both, in a rotation that had nothing to do with which gun was firing - so it
// was pinned to seq 15 instead.  That traded one wrong answer for another: the gun
// fires ONE hitscan per trigger tick at UZIAK_FIRE_DELAY 0.05, which the constant's
// own comment calls "two guns alternating... each barrel still cycles at its own 600
// rpm", and W_UziAkFire has always ejected brass from alternating sides.  So the
// weapon was one bullet from one gun, dressed as a simultaneous double tap, with
// every client-side effect nailed to the right barrel - "the left gun is never
// involved".
//
// Parity is the tree's existing dual-wield convention, cfddeagle's:
//     action_id odd  -> RIGHT     action_id even -> LEFT
// SH_StandardTryFire increments wep_action_id before anything reads it, so the first
// shot of a fresh magazine is the RIGHT gun.  The same expression is consumed by the
// server fire path, the CSQC predict path and the display frame, so all three agree
// about which barrel is live without a field to network.
float(float shot_id) SH_UziAkIsRight =
{
    return (shot_id & 1) ? TRUE : FALSE;
};

float(float shot_id) SH_UziAkPickShootSeq =
{
    if (SH_UziAkIsRight(shot_id)) return UZIAK_SEQ_SHOOT2;   // right gun only
    return UZIAK_SEQ_SHOOT1;                                 // left gun only
};

// The uzi's own three fire samples, one gun's worth each.  fire_both1/2.wav are
// deliberately no longer used for a shot: they are a BOTH-BARRELS take, and playing
// one for a single-gun shot is the mismatch that made the old seq-15 pick look
// defensible.  They stay precached (the deploy set references them) and are exactly
// what a future both-barrels alt-fire would want.
string(float shot_id) SH_UziAkShootSound =
{
    float n = shot_id - floor(shot_id / 3) * 3;
    if (n == 0) return "weapons/uzi/shoot1.wav";
    if (n == 1) return "weapons/uzi/shoot2.wav";
    return "weapons/uzi/shoot3.wav";
};

float(float now) SH_UziAkTickState =
{
    return SH_StandardTickState(now, mag_uziakimbo, ammo_uziakimbo, MAX_MAG_UZIAKIMBO,
        UZIAK_DRAW_DURATION, UZIAK_FIRE_DURATION, UZIAK_RELOAD_DURATION, UZIAK_RELOAD_DURATION);
};

float(float now) SH_UziAkTryFire =
{
    return SH_StandardTryFire(now, mag_uziakimbo, UZIAK_FIRE_DELAY, UZIAK_DRYFIRE_DELAY);
};

float(float now) SH_UziAkTryReload =
{
    return SH_StandardTryReload(now, mag_uziakimbo, ammo_uziakimbo, MAX_MAG_UZIAKIMBO,
                                UZIAK_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_UziAkPickupCopy =
{
    player.mag_uziakimbo  = self.mag_uziakimbo;
    player.ammo_uziakimbo = self.ammo_uziakimbo;
};

void() W_UziAkShoot =
{
    W_PenetratingHitscanShoot(UZIAK_BASE_SPREAD, UZIAK_MOVE_SPREAD, UZIAK_FULL_SPREAD_SPEED,
        UZIAK_CLOSE_DAMAGE, UZIAK_MIN_DAMAGE, UZIAK_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        UZIAK_KICK_PITCH, UZIAK_KICK_VARIANCE, UZIAK_KICK_STRENGTH);
};

void() W_UziAkFire =
{
    float r = SH_UziAkTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_UziAkPickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + UZIAK_FRAME_INTERVAL;

        W_UziAkShoot();

        sound(self, CHAN_WEAPON, SH_UziAkShootSound(self.wep_action_id), 1, ATTN_NORM);
        // Brass from the gun that actually fired.  The sides were the right way
        // round in isolation but keyed on the OPPOSITE parity to everything else
        // (even -> +right), so once the sequence pick started meaning something the
        // shells would have come out of the silent gun.
        if (SH_UziAkIsRight(self.wep_action_id))
            W_ShellEffect(SHELL_9MM, '8 4 -4',  '6 46 36',  '240 720 120');
        else
            W_ShellEffect(SHELL_9MM, '8 -4 -4', '6 -46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_UziAkReload =
{
    if (SH_UziAkTryReload(time))
    {
        self.weaponframe   = UZIAK_SEQ_RELOAD_BOTH;
        self.wep_nextframe = time + UZIAK_FRAME_INTERVAL;
        self.uziak_reload_snd_stage = 0;
    }
};

void() W_UziAkFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += UZIAK_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float el = time - self.wep_anim_start;
        if (self.uziak_reload_snd_stage < 1 && el >= UZIAK_RELOAD_SND1_TIME)
        { sound(self, CHAN_AUTO, "weapons/uzi/reload_right1.wav", 1, ATTN_NORM); self.uziak_reload_snd_stage = 1; }
        if (self.uziak_reload_snd_stage < 2 && el >= UZIAK_RELOAD_SND2_TIME)
        { sound(self, CHAN_AUTO, "weapons/uzi/reload_left1.wav", 1, ATTN_NORM); self.uziak_reload_snd_stage = 2; }
    }

    result = SH_UziAkTickState(time);
    if (result & 1)
    {
        self.weaponframe   = UZIAK_SEQ_IDLE;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_UziAkEquip =
{
    W_StandardEquipSetup(UZI_VIEWMODEL, UZIAK_DISPLAY_NAME, UZIAK_SEQ_DRAW,
        UZIAK_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_UziAkFire;
    self.reload   = W_UziAkReload;
    self.wepframe = W_UziAkFrame;
    self.shoot    = W_UziAkShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(UZIAK_BASE_SPREAD, UZIAK_MOVE_SPREAD, UZIAK_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_UziAkDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_uziakimbo  = self.mag_uziakimbo;
    tgt.ammo_uziakimbo = self.ammo_uziakimbo;
    self.mag_uziakimbo  = 0;
    self.ammo_uziakimbo = 0;

    setmodel(tgt, UZIAK_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_uziakimbo";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_UZIAKIMBO;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_UziAkEquip;
    tgt.weap_drop_func = W_UziAkDrop;
    tgt.pickupcopy     = W_UziAkPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_uziakimbo =
{
    setmodel(self, UZIAK_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_uziakimbo";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_UZIAKIMBO;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_UziAkEquip;
    self.weap_drop_func = W_UziAkDrop;
    self.pickupcopy     = W_UziAkPickupCopy;
    self.touch          = weapon_touch;
    self.mag_uziakimbo  = MAX_MAG_UZIAKIMBO;
    self.ammo_uziakimbo = MAX_AMMO_UZIAKIMBO;
    W_RegisterMapWeapon(weapon_uziakimbo);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_uziak_reload_snd_stage;

void() CSQC_PredictUziAkCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_UziAkTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                localsound(SH_UziAkShootSound(self.wep_action_id));
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(UZIAK_BASE_SPREAD, UZIAK_MOVE_SPREAD, UZIAK_FULL_SPREAD_SPEED,
                    UZIAK_CLOSE_DAMAGE, UZIAK_MIN_DAMAGE, UZIAK_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    UZIAK_KICK_PITCH, UZIAK_KICK_VARIANCE, UZIAK_KICK_STRENGTH);
                // EVERY effect follows the firing gun.  All three used to be
                // hard-coded to +right, so the predicted brass even contradicted
                // the server's alternating eject.
                float is_r = SH_UziAkIsRight(self.wep_action_id);

                if (is_r)
                    CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                        '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                else
                    CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                        '8 -4 -4', '6 -46 36', '8 14 14', '240 720 120', '120 240 180');

                // Bone-resolved, like cfddeagle: the flash has to anchor to the
                // barrel the animation is firing, and a camera-local scalar triple
                // cannot express two of them.  CSQC_ViewmodelAttachmentWorldPos
                // poses the viewmodel to frame 0 of THIS shot's sequence first, so
                // the bone is sampled where it will actually be drawn.
                vector muzzle_world;
                if (is_r)
                    muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                        UZIAK_MUZZLE_BONE_RIGHT, UZIAK_MUZZLE_OFFSET_RIGHT);
                else
                    muzzle_world = CSQC_ViewmodelAttachmentWorldPos(
                        UZIAK_MUZZLE_BONE_LEFT, UZIAK_MUZZLE_OFFSET_LEFT);

                CSQC_MuzzleFlashAtWorld(muzzle_world, self.wep_action_id);
                CSQC_MuzzleSmokeAtWorld(muzzle_world, self.wep_action_id, 1);
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
        if (csqc_uziak_reload_snd_stage < 1 && el >= UZIAK_RELOAD_SND1_TIME)
        { localsound("weapons/uzi/reload_right1.wav"); CSQC_RecordPredictedAutoSound(); csqc_uziak_reload_snd_stage = 1; }
        if (csqc_uziak_reload_snd_stage < 2 && el >= UZIAK_RELOAD_SND2_TIME)
        { localsound("weapons/uzi/reload_left1.wav"); CSQC_RecordPredictedAutoSound(); csqc_uziak_reload_snd_stage = 2; }
    }

    SH_UziAkTickState(csqc_pred_time);
};

void() CSQC_PredictUziAkReload =
{
    if (SH_UziAkTryReload(csqc_pred_time))
    { csqc_uziak_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_UziAkimboDisplayFrame =
{
    // FIRST, for every state.  akimbo_idle is 0.3 s and does NOT carry
    // STUDIO_LOOPING, so without a periodic re-send the viewmodel clamps to its
    // last frame and freezes (gl_hlmdl.c:1076-1082).  The re-arm window is
    // short because the sequence itself is short.
    // 10/15, the same window every other sequence weapon uses, NOT the 1/3 that
    // used to be here as bare literals.  SH_SeqIdleDisplay re-anchors the
    // sequence to frame 0 on each roll, so a 1-3 s window restarted the 0.300 s
    // akimbo_idle roughly 25 times a minute where every other weapon fidgets
    // about 4 — a constant visible twitch, and the most likely thing behind
    // "animations all messed up".
    //
    // The short window was chosen because the sequence is short, which is the
    // wrong inference: a non-looping idle clamped to its last frame is simply a
    // rest pose and looks correct held.  What does not look correct is snapping
    // it back to frame 0 every couple of seconds.
    float idle = SH_SeqIdleDisplay(cltime, WEP_UZIAKIMBO, predicted_player.weaponstate,
                                   UZIAK_SEQ_IDLE, UZIAK_SEQ_IDLE,
                                   UZIAK_IDLE_REARM_MIN, UZIAK_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return UZIAK_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_UziAkPickShootSeq(predicted_player.wep_action_id);
    // reload_both, and sequences 10/11 (reload_right / reload_left) stay unused ON
    // PURPOSE.  They are for a gun with two separate magazines; this one has a
    // single 64-round pool that both barrels draw from, so there is no state in
    // which exactly one gun is empty and a one-handed reload would be honest.
    // The animation already changes both magazines and the foley already plays
    // reload_right1 then reload_left1, so both guns are involved either way.
    if (predicted_player.weaponstate == WS_RELOAD)
        return UZIAK_SEQ_RELOAD_BOTH;
    return UZIAK_SEQ_IDLE;
};

void() CSQC_UziAkDropClear =
{
    self.mag_uziakimbo  = 0;
    self.ammo_uziakimbo = 0;
};

void() CSQC_UziAkimboEquip =
{
    self.weapon_name         = UZIAK_DISPLAY_NAME;
    self.weapon_viewmodel    = UZI_VIEWMODEL;    // shared — see the model note
    self.weapon_worldmodel   = UZIAK_WORLDMODEL;
    self.weapon_deploy_sound = UZIAK_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictUziAkCommand;
    self.csqc_predict_reload = CSQC_PredictUziAkReload;
    self.csqc_display_frame  = CSQC_UziAkimboDisplayFrame;
    self.csqc_drop_clear     = CSQC_UziAkDropClear;
    self.weapon_uses_sequences = TRUE;
    // Sway-pivot anchor and the attachment-based smoke opt-in (cl_weapons.qc:1926
    // keys off this being non-empty).  The RIGHT gun, arbitrarily and exactly as
    // cfddeagle does: the pivot only needs a stable rotation centre, and the
    // per-shot bone pick still happens in the fire path.
    self.weapon_muzzle_bone   = UZIAK_MUZZLE_BONE_RIGHT;
    self.weapon_muzzle_offset = UZIAK_MUZZLE_OFFSET_RIGHT;
};

#endif // CSQC
