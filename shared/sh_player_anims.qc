// ============================================================
//  shared/sh_player_anims.qc  -  GoldSrc CS-style player body animation
//
//  Server-authoritative single-layer animation for the third-person
//  player model. Picks one of the canonical CS 1.6 player sequences
//  (idle / walk / run / crouch / jump) based on velocity, ground
//  state, and crouch state, then writes it to self.frame.
//
//  The full-body sequences (CSANIM_WALK, CSANIM_RUN, etc.) include
//  animated legs even though they look stationary in HLMV — HLMV
//  defaults to playing upper-body-only aim sequences. The locomotion
//  sequences are full body and animate the legs correctly.
//
//  Single-layer is intentional for phase A: only self.frame is used,
//  which is a standard replicated entity field. The dual-layer split
//  (torso aim + leg gait via .baseframe / bonecontrols) is a future
//  upgrade — those fields require a custom SendEntity to replicate
//  reliably, and that plumbing is its own phase.
//
//  This file is compiled by BOTH sv_progs and cl_progs so the
//  CSANIM_* enum is visible everywhere. The update function is
//  server-only.
// ============================================================

// --- CS 1.6 player model sequence indices ---
// Ported verbatim from cstrike/src/shared/Animations.h.
// gsg9.mdl and the other 4 player models follow this layout.
const float CSANIM_DUMMY1                  = 0;
const float CSANIM_IDLE                    = 1;
const float CSANIM_IDLE_CROUCH             = 2;
const float CSANIM_WALK                    = 3;
const float CSANIM_RUN                     = 4;
const float CSANIM_RUN_CROUCH              = 5;
const float CSANIM_JUMP                    = 6;
const float CSANIM_LONGJUMP                = 7;
const float CSANIM_SWIM                    = 8;
const float CSANIM_TREADWATER              = 9;
const float CSANIM_CROUCH_AIM_CARBINE      = 10;
const float CSANIM_CROUCH_SHOOT_CARBINE    = 11;
const float CSANIM_CROUCH_RELOAD_CARBINE   = 12;
const float CSANIM_AIM_CARBINE             = 13;
const float CSANIM_SHOOT_CARBINE           = 14;
const float CSANIM_RELOAD_CARBINE          = 15;
const float CSANIM_CROUCH_AIM_ONEHAND      = 16;
const float CSANIM_CROUCH_SHOOT_ONEHAND    = 17;
const float CSANIM_CROUCH_RELOAD_ONEHAND   = 18;
const float CSANIM_AIM_ONEHAND             = 19;
const float CSANIM_SHOOT_ONEHAND           = 20;
const float CSANIM_RELOAD_ONEHAND          = 21;
const float CSANIM_CROUCH_AIM_DUALPISTOLS  = 22;
const float CSANIM_CROUCH_SHOOT_DUALPISTOLS = 23;
const float CSANIM_CROUCH_SHOOT2_DUALPISTOLS = 24;
const float CSANIM_CROUCH_RELOAD_DUALPISTOLS = 25;
const float CSANIM_AIM_DUALPISTOLS         = 26;
const float CSANIM_SHOOT_DUALPISTOLS       = 27;
const float CSANIM_SHOOT2_DUALPISTOLS      = 28;
const float CSANIM_RELOAD_DUALPISTOLS      = 29;
const float CSANIM_CROUCH_AIM_RIFLE        = 30;
const float CSANIM_CROUCH_SHOOT_RIFLE      = 31;
const float CSANIM_CROUCH_RELOAD_RIFLE     = 32;
const float CSANIM_AIM_RIFLE               = 33;
const float CSANIM_SHOOT_RIFLE             = 34;
const float CSANIM_RELOAD_RIFLE            = 35;
const float CSANIM_CROUCH_AIM_MP5          = 36;
const float CSANIM_CROUCH_SHOOT_MP5        = 37;
const float CSANIM_CROUCH_RELOAD_MP5       = 38;
const float CSANIM_AIM_MP5                 = 39;
const float CSANIM_SHOOT_MP5               = 40;
const float CSANIM_RELOAD_MP5              = 41;
const float CSANIM_CROUCH_AIM_SHOTGUN      = 42;
const float CSANIM_CROUCH_SHOOT_SHOTGUN    = 43;
const float CSANIM_CROUCH_RELOAD_SHOTGUN   = 44;
const float CSANIM_AIM_SHOTGUN             = 45;
const float CSANIM_SHOOT_SHOTGUN           = 46;
const float CSANIM_RELOAD_SHOTGUN          = 47;
const float CSANIM_CROUCH_AIM_PARA         = 48;
const float CSANIM_CROUCH_SHOOT_PARA       = 49;
const float CSANIM_CROUCH_RELOAD_PARA      = 50;
const float CSANIM_AIM_PARA                = 51;
const float CSANIM_SHOOT_PARA              = 52;
const float CSANIM_RELOAD_PARA             = 53;
const float CSANIM_DUMMY2                  = 54;
const float CSANIM_DUMMY3                  = 55;
const float CSANIM_AIM_GRENADE             = 56;
const float CSANIM_SHOOT_GRENADE           = 57;
const float CSANIM_CROUCH_AIM_GRENADE      = 58;
const float CSANIM_CROUCH_SHOOT_GRENADE    = 59;
const float CSANIM_CROUCH_AIM_C4           = 60;
const float CSANIM_CROUCH_SHOOT_C4         = 61;
const float CSANIM_AIM_C4                  = 62;
const float CSANIM_SHOOT_C4                = 63;
const float CSANIM_RELOAD_C4               = 64;
const float CSANIM_DUPLICATE1              = 65;
const float CSANIM_DUPLICATE2              = 66;
const float CSANIM_DUPLICATE3              = 67;
const float CSANIM_DUPLICATE4              = 68;
const float CSANIM_DUPLICATE5              = 69;
const float CSANIM_DUPLICATE6              = 70;
const float CSANIM_DUPLICATE7              = 71;
const float CSANIM_DUPLICATE8              = 72;
const float CSANIM_CROUCH_AIM_KNIFE        = 73;
const float CSANIM_CROUCH_SHOOT_KNIFE      = 74;
const float CSANIM_AIM_KNIFE               = 75;
const float CSANIM_SHOOT_KNIFE             = 76;
const float CSANIM_CROUCH_AIM_AK47         = 77;
const float CSANIM_CROUCH_SHOOT_AK47       = 78;
const float CSANIM_CROUCH_RELOAD_AK47      = 79;
const float CSANIM_AIM_AK47                = 80;
const float CSANIM_SHOOT_AK47              = 81;
const float CSANIM_RELOAD_AK47             = 82;
// Indices 83-98 are shield variants in the full CS 1.6 model.
// Flinch and death sequences start at 99+ (0-indexed).
const float CSANIM_GUT_FLINCH              = 99;
const float CSANIM_HEAD_FLINCH             = 100;
const float CSANIM_DEATH1                  = 101;  // land on stomach
const float CSANIM_DEATH2                  = 102;  // land on back
const float CSANIM_DEATH3                  = 103;  // dramatic
const float CSANIM_DIE_HEAD                = 104;  // headshot
const float CSANIM_DIE_GUT                 = 105;  // gutshot
const float CSANIM_DIE_LEFT                = 106;  // hit from right, fall left
const float CSANIM_DIE_BACK                = 107;  // hit from front, fall backward
const float CSANIM_DIE_RIGHT               = 108;  // hit from left, fall right
const float CSANIM_DIE_FORWARD             = 109;  // hit from behind, fall forward
const float CSANIM_CROUCH_DIE              = 110;  // die while crouching
// Custom: single-frame static-leg poses used by the legs-side anim slot
// during idle/crouch-idle. Replace CSANIM_IDLE / CSANIM_IDLE_CROUCH on
// the legs side because idle1 / crouch_idle have internal IK that fights
// FTE's basebone split (the legs counter-rotate against root translation
// that the split severs from them, producing the "feet drift" symptom).
// All 8 player models append both sequences in the same order after the
// stock 0..110 list, so the indices match across every model.
const float CSANIM_LEGS_IDLE_STATIC        = 111;
const float CSANIM_LEGS_CROUCH_STATIC      = 112;

// --- Animation sequence lookup by weapon family + crouch state ---
// These take a modelindex for frameforname-based models (sini).
// For CS models, modelindex is ignored (hardcoded CSANIM_* constants).

float(float mdlidx, float family, float crouching) SH_GetAimAnim =
{
    if (self.player_model_index == 5)
        return Sini_GetAimAnim(mdlidx, family, crouching);

    switch (family)
    {
    case PANIM_ONEHAND:  return crouching ? CSANIM_CROUCH_AIM_ONEHAND  : CSANIM_AIM_ONEHAND;
    case PANIM_CARBINE:  return crouching ? CSANIM_CROUCH_AIM_CARBINE  : CSANIM_AIM_CARBINE;
    case PANIM_RIFLE:    return crouching ? CSANIM_CROUCH_AIM_RIFLE    : CSANIM_AIM_RIFLE;
    case PANIM_MP5:      return crouching ? CSANIM_CROUCH_AIM_MP5      : CSANIM_AIM_MP5;
    case PANIM_SHOTGUN:  return crouching ? CSANIM_CROUCH_AIM_SHOTGUN  : CSANIM_AIM_SHOTGUN;
    case PANIM_PARA:     return crouching ? CSANIM_CROUCH_AIM_PARA     : CSANIM_AIM_PARA;
    case PANIM_KNIFE:    return crouching ? CSANIM_CROUCH_AIM_KNIFE    : CSANIM_AIM_KNIFE;
    case PANIM_GRENADE:  return crouching ? CSANIM_CROUCH_AIM_GRENADE  : CSANIM_AIM_GRENADE;
    case PANIM_AK47:     return crouching ? CSANIM_CROUCH_AIM_AK47     : CSANIM_AIM_AK47;
    default:             return crouching ? CSANIM_CROUCH_AIM_ONEHAND  : CSANIM_AIM_ONEHAND;
    }
};

float(float mdlidx, float family, float crouching) SH_GetShootAnim =
{
    if (self.player_model_index == 5)
        return Sini_GetShootAnim(mdlidx, family, crouching);

    switch (family)
    {
    case PANIM_ONEHAND:  return crouching ? CSANIM_CROUCH_SHOOT_ONEHAND  : CSANIM_SHOOT_ONEHAND;
    case PANIM_CARBINE:  return crouching ? CSANIM_CROUCH_SHOOT_CARBINE  : CSANIM_SHOOT_CARBINE;
    case PANIM_RIFLE:    return crouching ? CSANIM_CROUCH_SHOOT_RIFLE    : CSANIM_SHOOT_RIFLE;
    case PANIM_MP5:      return crouching ? CSANIM_CROUCH_SHOOT_MP5      : CSANIM_SHOOT_MP5;
    case PANIM_SHOTGUN:  return crouching ? CSANIM_CROUCH_SHOOT_SHOTGUN  : CSANIM_SHOOT_SHOTGUN;
    case PANIM_PARA:     return crouching ? CSANIM_CROUCH_SHOOT_PARA     : CSANIM_SHOOT_PARA;
    case PANIM_KNIFE:    return crouching ? CSANIM_CROUCH_SHOOT_KNIFE    : CSANIM_SHOOT_KNIFE;
    case PANIM_GRENADE:  return crouching ? CSANIM_CROUCH_SHOOT_GRENADE  : CSANIM_SHOOT_GRENADE;
    case PANIM_AK47:     return crouching ? CSANIM_CROUCH_SHOOT_AK47     : CSANIM_SHOOT_AK47;
    default:             return crouching ? CSANIM_CROUCH_SHOOT_ONEHAND  : CSANIM_SHOOT_ONEHAND;
    }
};

float(float mdlidx, float family, float crouching) SH_GetReloadAnim =
{
    if (self.player_model_index == 5)
        return Sini_GetReloadAnim(mdlidx, family, crouching);

    switch (family)
    {
    case PANIM_ONEHAND:  return crouching ? CSANIM_CROUCH_RELOAD_ONEHAND : CSANIM_RELOAD_ONEHAND;
    case PANIM_CARBINE:  return crouching ? CSANIM_CROUCH_RELOAD_CARBINE : CSANIM_RELOAD_CARBINE;
    case PANIM_RIFLE:    return crouching ? CSANIM_CROUCH_RELOAD_RIFLE   : CSANIM_RELOAD_RIFLE;
    case PANIM_MP5:      return crouching ? CSANIM_CROUCH_RELOAD_MP5     : CSANIM_RELOAD_MP5;
    case PANIM_SHOTGUN:  return crouching ? CSANIM_CROUCH_RELOAD_SHOTGUN : CSANIM_RELOAD_SHOTGUN;
    case PANIM_PARA:     return crouching ? CSANIM_CROUCH_RELOAD_PARA    : CSANIM_RELOAD_PARA;
    case PANIM_AK47:     return crouching ? CSANIM_CROUCH_RELOAD_AK47    : CSANIM_RELOAD_AK47;
    case PANIM_KNIFE:    return crouching ? CSANIM_CROUCH_AIM_KNIFE      : CSANIM_AIM_KNIFE;
    case PANIM_GRENADE:  return crouching ? CSANIM_CROUCH_AIM_GRENADE    : CSANIM_AIM_GRENADE;
    default:             return crouching ? CSANIM_CROUCH_RELOAD_ONEHAND : CSANIM_RELOAD_ONEHAND;
    }
};

// Per-player animation state (custom fields, no engine shadows).
.float anim_top;
.float anim_top_time;
.float anim_top_delay;
.float anim_top_gen;     // increments each PlayTop call — client detects re-fires
.float anim_bottom;
.float anim_bottom_time;

// Wall-clock timestamps when the current anim layer last (re-)started.
// Server computes baseframe1time / idle-frame1time as (time - *_start) so
// both layers track real wall time exactly — no accumulator drift vs
// the client's cltime-based visual model.
.float anim_top_start;
.float anim_bottom_start;

// ============================================================
//  SERVER ONLY
// ============================================================
// ============================================================

#ifdef SSQC

// Pick a random death animation and set it as the full-body frame.
// Pick a death animation based on the last hitgroup that killed the player.
// Falls back to random generic death if no hitgroup info available.
// .death_hitgroup should be set by the damage system before calling this.
.float death_hitgroup;

void() SH_PlayerAnim_Death =
{
    float mdlidx = 0;
    if (self.player_visual_proxy)
        mdlidx = self.player_visual_proxy.modelindex;

    float deathframe;
#ifdef SSQC
    float gm = cvar("sv_gamemode");
#else
    float gm = getstatf(STAT_GAMEMODE);
#endif
    if (gm == GAMEMODE_PAINTGUN)
    {
        // Paintgun mode plays one fixed "tag-out" animation across
        // every kill so the visual reads as a clean elimination.
        // Skip the hitgroup / crouch / model-specific branches.
        deathframe = CSANIM_DEATH2;
    }
    else if (self.player_model_index == 5)
    {
        deathframe = Sini_GetRandomDeathAnim(mdlidx);
    }
    else
    {
        float crouching = (self.flags & FL_DUCKING) != 0;
        if (crouching)
        {
            deathframe = CSANIM_CROUCH_DIE;
        }
        else if (self.death_hitgroup == HITGROUP_HEAD)
        {
            deathframe = CSANIM_DIE_HEAD;
        }
        else if (self.death_hitgroup == HITGROUP_STOMACH)
        {
            deathframe = CSANIM_DIE_GUT;
        }
        else
        {
            // Generic random death for chest/limbs/fall/unknown
            float r = floor(random() * 6);
            if (r == 0)      deathframe = CSANIM_DEATH1;
            else if (r == 1) deathframe = CSANIM_DEATH2;
            else if (r == 2) deathframe = CSANIM_DEATH3;
            else if (r == 3) deathframe = CSANIM_DIE_BACK;
            else if (r == 4) deathframe = CSANIM_DIE_FORWARD;
            else             deathframe = CSANIM_DIE_LEFT;
        }
    }
    self.frame = deathframe;
    self.baseframe = deathframe;
};

// Trigger a one-shot upper-body animation (fire, reload, draw).
// Holds anim_top at the given sequence for `duration` seconds,
// then reverts to the weapon's aim pose.
void(float anim, float duration) SH_PlayerAnim_PlayTop =
{
    self.anim_top       = anim;
    self.anim_top_time  = 0;
    self.anim_top_delay = duration;
    self.anim_top_gen   = (self.anim_top_gen + 1) & 255; // wrapping byte counter
    self.anim_top_start = time;                          // wall-clock anchor
};

.float player_spine_skel_modelindex;
.float player_spine_debug_next;

const float PLAYER_SPINE_PI_RAD = 3.14159265358979;

float(float f) SH_PlayerAnim_FloatGood =
{
    return (fabs(f) < 100000);
};

float(vector v) SH_PlayerAnim_VectorGood =
{
    return (SH_PlayerAnim_FloatGood(v_x)
         && SH_PlayerAnim_FloatGood(v_y)
         && SH_PlayerAnim_FloatGood(v_z));
};

float(float skel, float bone_idx) SH_PlayerAnim_LoadBoneBasis =
{
    if (bone_idx <= 0 || skel == 0)
        return FALSE;

    skel_get_bonerel(skel, bone_idx);

    if (!SH_PlayerAnim_VectorGood(v_forward)
        || !SH_PlayerAnim_VectorGood(v_right)
        || !SH_PlayerAnim_VectorGood(v_up)
        || vlen(v_forward) < 0.001
        || vlen(v_right) < 0.001
        || vlen(v_up) < 0.001)
        return FALSE;

    vector old_f = v_forward;
    vector old_r = v_right;
    vector old_u = v_up;
    vector lf = normalize(old_f);
    vector lu = old_u - lf * (old_u * lf);
    if (vlen(lu) < 0.001)
        lu = crossproduct(old_r, lf);
    if (vlen(lu) < 0.001)
        return FALSE;
    lu = normalize(lu);
    vector lr = crossproduct(lf, lu);
    if (vlen(lr) < 0.001)
        return FALSE;
    lr = normalize(lr);
    if (lr * old_r < 0)
    {
        lr = -lr;
        lu = -lu;
    }

    v_forward = lf;
    v_right   = lr;
    v_up      = lu;
    return TRUE;
};

void(float skel) SH_PlayerAnim_OrthonormalizeSkeleton =
{
    float n = skel_get_numbones(skel);
    float i;
    for (i = 1; i <= n; i++)
    {
        vector bone_org = skel_get_bonerel(skel, i);
        if (!SH_PlayerAnim_VectorGood(bone_org))
            bone_org = '0 0 0';
        if (SH_PlayerAnim_LoadBoneBasis(skel, i))
            skel_set_bone(skel, i, bone_org, v_forward, v_right, v_up);
        else
            skel_set_bone(skel, i, bone_org, '1 0 0', '0 1 0', '0 0 1');
    }
};

void(float skel) SH_PlayerAnim_BuildPoseSkeleton =
{
    float splitbone = self.basebone;

    // Match the client-side IQM spine path: build the base/torso and
    // regular/leg ranges separately so the explicit skeleton keeps the
    // current frame2 lerps instead of freezing locomotion bones.
    if (splitbone > 1)
    {
        skel_build(skel, self, self.modelindex, 0, 1, splitbone);
        skel_build(skel, self, self.modelindex, 0, splitbone, 0);
    }
    else
    {
        skel_build(skel, self, self.modelindex, 0, 0, 0);
    }
};

float() SH_PlayerAnim_ModelIsIQM =
{
    float len = strlen(self.model);
    if (len < 4)
        return FALSE;
    return (substring(strtolower(self.model), len - 4, 4) == ".iqm");
};

void(float skel, float bone_idx, float deg) SH_PlayerAnim_TwistBone =
{
    vector bone_org = skel_get_bonerel(skel, bone_idx);
    if (!SH_PlayerAnim_LoadBoneBasis(skel, bone_idx))
        return;

    vector lf = v_forward, lr = v_right, lu = v_up;
    float c = cos(deg * PLAYER_SPINE_PI_RAD / 180);
    float s = sin(deg * PLAYER_SPINE_PI_RAD / 180);
    skel_set_bone(skel, bone_idx, bone_org, lf, lr * c + lu * s, -lr * s + lu * c);
};

void(float skel, float bone_idx, float deg) SH_PlayerAnim_PitchBone =
{
    vector bone_org = skel_get_bonerel(skel, bone_idx);
    if (!SH_PlayerAnim_LoadBoneBasis(skel, bone_idx))
        return;

    vector lf = v_forward, lr = v_right, lu = v_up;
    float c = cos(deg * PLAYER_SPINE_PI_RAD / 180);
    float s = sin(deg * PLAYER_SPINE_PI_RAD / 180);
    skel_set_bone(skel, bone_idx, bone_org, lf * c - lr * s, lf * s + lr * c, lu);
};

void(float leg_twist) SH_PlayerAnim_ApplyIQMSpine =
{
    if (!cvar("cl_player_spine_deform") || !self.modelindex || !SH_PlayerAnim_ModelIsIQM())
    {
        if (self.skeletonindex)
        {
            skel_delete(self.skeletonindex);
            self.skeletonindex = 0;
            self.player_spine_skel_modelindex = 0;
        }
        return;
    }

    float twist_scale = cvar("cl_player_spine_twist_scale");
    float pitch_scale = cvar("cl_player_spine_pitch_scale");
    if (twist_scale == 0 && pitch_scale == 0)
    {
        if (self.skeletonindex)
        {
            skel_delete(self.skeletonindex);
            self.skeletonindex = 0;
            self.player_spine_skel_modelindex = 0;
        }
        return;
    }

    if (self.skeletonindex && self.player_spine_skel_modelindex != self.modelindex)
    {
        skel_delete(self.skeletonindex);
        self.skeletonindex = 0;
        self.player_spine_skel_modelindex = 0;
    }

    if (!self.skeletonindex)
    {
        self.skeletonindex = skel_create(self.modelindex);
        self.player_spine_skel_modelindex = self.modelindex;
    }

    if (!self.skeletonindex)
        return;

    SH_PlayerAnim_BuildPoseSkeleton(self.skeletonindex);
    SH_PlayerAnim_OrthonormalizeSkeleton(self.skeletonindex);

    float iqm_twist = -leg_twist * twist_scale;
    float pitch_max = cvar("cl_player_spine_pitch_max");
    if (pitch_max <= 0)
        pitch_max = 35;
    float pitch_frac = bound(-1, self.v_angle_x / 90, 1);
    float iqm_pitch = bound(-pitch_max, pitch_frac * pitch_max * pitch_scale, pitch_max);

    float sb0 = skel_find_bone(self.skeletonindex, "Bip01 Spine");
    float sb1 = skel_find_bone(self.skeletonindex, "Bip01 Spine1");
    float sb2 = skel_find_bone(self.skeletonindex, "Bip01 Spine2");
    float sb3 = skel_find_bone(self.skeletonindex, "Bip01 Spine3");
    float sbn = skel_find_bone(self.skeletonindex, "Bip01 Neck");

    if (iqm_twist != 0)
    {
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb0, iqm_twist);
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb1, iqm_twist * 0.5);
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb2, iqm_twist * 0.25);
        SH_PlayerAnim_TwistBone(self.skeletonindex, sb3, iqm_twist * 0.125);
    }

    if (iqm_pitch != 0)
    {
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb0, iqm_pitch * 0.05);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb1, iqm_pitch * 0.15);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb2, iqm_pitch * 0.30);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sb3, iqm_pitch * 0.35);
        SH_PlayerAnim_PitchBone(self.skeletonindex, sbn, iqm_pitch * 0.15);
    }

    if (cvar("cl_player_spine_debug") && time >= self.player_spine_debug_next)
    {
        sprint(self, PRINT_HIGH, sprintf("[spine sv] model='%s' skel=%g\n", self.model, self.skeletonindex));
        sprint(self, PRINT_HIGH, sprintf("           bones=%g/%g/%g/%g/%g\n", sb0, sb1, sb2, sb3, sbn));
        sprint(self, PRINT_HIGH, sprintf("           leg=%.1f twist=%.1f pitch=%.1f max=%.1f\n", leg_twist, iqm_twist, iqm_pitch, pitch_max));
        self.player_spine_debug_next = time + 0.5;
    }
};

void() SH_PlayerAnim_ClearIQMSpine =
{
    if (self.skeletonindex && self.player_spine_skel_modelindex)
    {
        skel_delete(self.skeletonindex);
        self.skeletonindex = 0;
        self.player_spine_skel_modelindex = 0;
    }
};

void() SH_PlayerAnim_Update =
{
    float speed;
    float crouching;
    float onground;
    float family;

    if (self.health <= 0)
        return;

    // Get the visual proxy's modelindex for frameforname lookups
    float mdlidx = 0;
    if (self.player_visual_proxy)
        mdlidx = self.player_visual_proxy.modelindex;

    speed     = vlen(self.velocity);
    crouching = (self.flags & FL_DUCKING) != 0;
    onground  = (self.flags & FL_ONGROUND) != 0;

    // func_vehicle: a seated driver carries the car's velocity (so a dismount
    // inherits its momentum) but isn't actually running — present them as
    // stationary & grounded so the legs play idle instead of run/jump.  The
    // velocity-driven leg-twist below is also gated off (see speed2d use).
    if (self.pm_driving)
    {
        speed    = 0;
        onground = TRUE;
    }

    // Tick timers
    self.anim_top_time  += frametime;
    self.anim_top_delay -= frametime;

    // Upper body: hold fire/reload anim while delay > 0, else aim pose.
    // If crouching changed mid-action, swap to the correct variant.
    family = W_GetPlayerAnimFamily(self.weapon);
    if (self.anim_top_delay <= 0)
        self.anim_top = SH_GetAimAnim(mdlidx, family, crouching);
    else if (self.weaponstate == WS_FIRE)
        self.anim_top = SH_GetShootAnim(mdlidx, family, crouching);
    else if (self.weaponstate == WS_RELOAD)
        self.anim_top = SH_GetReloadAnim(mdlidx, family, crouching);

    // Lower body: locomotion
    if (self.player_model_index == 5)
    {
        // Sini: look up by name
        if (!onground)
            self.anim_bottom = Sini_GetJumpAnim(mdlidx);
        else if (speed < 1)
            self.anim_bottom = crouching ? Sini_GetCrouchIdleAnim(mdlidx) : Sini_GetIdleAnim(mdlidx);
        else
            self.anim_bottom = crouching ? Sini_GetCrouchRunAnim(mdlidx) : Sini_GetRunAnim(mdlidx);
    }
    else
    {
        // CS models: hardcoded indices
        if (!onground)
            self.anim_bottom = CSANIM_JUMP;
        else if (speed < 1)
            // Standing/crouching idle: use single-frame static leg
            // sequences instead of CSANIM_IDLE / CSANIM_IDLE_CROUCH.
            // The stock CSANIM_IDLE* are full-body anims whose leg
            // keyframes contain root-translation IK that the basebone
            // split severs (root is in torso group), causing the legs
            // to counter-rotate against translation that no longer
            // happens — the "feet drift / swim" symptom. The static
            // variants are one frozen leg pose, no root motion, no IK.
            self.anim_bottom = crouching ? CSANIM_LEGS_CROUCH_STATIC : CSANIM_LEGS_IDLE_STATIC;
        else
            self.anim_bottom = crouching ? CSANIM_RUN_CROUCH : CSANIM_RUN;
    }

    // Body faces aim direction (set BEFORE leg twist computation).
    self.angles_y = self.v_angle_y;
    self.angles_x = 0;
    self.angles_z = 0;

    // --- Strafe body twist + backpedal detection ---
    // Computed BEFORE animation timer so locomotion can use backpedaling flag.
    // Mirrors CSQC cl_player.qc's hysteresis exactly (cl_player_backpedal_*_angle
    // cvars + .sv_backpedaling latch) so hitboxes flip at the same instant the
    // visual model does.  Without this, the server used a hardcoded ±95° flip
    // while the client had wider hysteresis, so hitboxes desynced from visuals
    // during small mouse corrections near 90°.
    vector vel2d = self.velocity;
    vel2d_z = 0;
    float speed2d = vlen(vel2d);
    float leg_twist = 0;
    float backpedaling = FALSE;

    float bp_enter = cvar("cl_player_backpedal_enter_angle");
    float bp_exit  = cvar("cl_player_backpedal_exit_angle");
    if (bp_enter <= 0) bp_enter = 150;
    if (bp_exit  <= 0) bp_exit  = 100;
    bp_enter = bound(91, bp_enter, 179);
    bp_exit  = bound(1, bp_exit, bp_enter - 1);

    if (speed2d > 10 && !self.pm_driving)
    {
        float vel_yaw = vectoyaw(vel2d);
        float yaw_diff = vel_yaw - self.v_angle_y;
        // Normalize to -180..180
        yaw_diff -= floor((yaw_diff + 180) / 360) * 360;

        // Hysteresis: enter backpedal late, leave it earlier — keeps pure
        // strafing stable while the player makes small aim corrections.
        float abs_yaw = fabs(yaw_diff);
        if (self.sv_backpedaling)
        {
            if (abs_yaw < bp_exit)
                self.sv_backpedaling = FALSE;
        }
        else if (abs_yaw > bp_enter)
            self.sv_backpedaling = TRUE;

        if (self.sv_backpedaling)
        {
            backpedaling = TRUE;
            // Mirror angle so legs face opposite dir
            if (yaw_diff > 0)
                yaw_diff = yaw_diff - 180;
            else
                yaw_diff = yaw_diff + 180;
        }

        float speed_frac = bound(0, speed2d / 250, 1);
        leg_twist = yaw_diff * speed_frac;
    }
    else
        self.sv_backpedaling = FALSE;

    // Rotate whole model toward movement (legs face walk direction)
    self.angles_y += leg_twist;

    // Counter-rotate upper body back to aim direction
    self.subblendfrac = bound(-1, leg_twist / 90, 1);
    self.subblend2frac = self.v_angle_x / 90;

    // --- Frame writes ---
    // FTE basebone rule: bones < basebone → .baseframe, bones >= basebone → .frame

    // Lower body (legs): detect anim change → stamp wall-clock start.
    if (self.anim_bottom != self.frame)
    {
        self.frame2 = self.frame;
        self.frame2time = self.frame1time;
        self.frame = self.anim_bottom;
        self.frame1time = 0;
        self.anim_bottom_start = time;
    }
    self.lerpfrac = 1;

    // Upper body (torso/aim): anim change updates lerp target and, if this
    // was a transition NOT caused by PlayTop (e.g. delay expired back to
    // aim pose), stamp the wall-clock anchor ourselves.
    if (self.anim_top != self.baseframe)
    {
        self.baseframe2 = self.baseframe;
        self.baseframe2time = self.baseframe1time;
        self.baseframe = self.anim_top;
        // Guard: PlayTop already stamped anim_top_start at trigger time;
        // only overwrite for transitions that bypass PlayTop (e.g. idle
        // aim restoration, crouch variant swap).
        if (self.anim_top_delay <= 0)
            self.anim_top_start = time;
    }
    // Wall-clock driven — matches CSQC's cltime-based vis_anim_top_time
    // exactly, so no drift between server hitbox and client visual model.
    self.baseframe1time = time - self.anim_top_start;
    self.baselerpfrac = 1;

    // --- Locomotion timer: distance-based (matches CSQC for hitbox sync) ---
    // For RUN/CROUCH_RUN, advance frame1time by horizontal distance traveled
    // so feet sync to ground speed. For idle/jump, use plain time.
    float is_locomotion = (self.anim_bottom == CSANIM_RUN
                        || self.anim_bottom == CSANIM_RUN_CROUCH);

    if (is_locomotion && speed2d > 1)
    {
        // Crouch uses its own qu_per_sec since crouch movement is slower.
        // See cl_player.qc for the matching CSQC-side branch.
        float qu_per_sec;
        if (self.anim_bottom == CSANIM_RUN_CROUCH)
        {
#ifdef SSQC
            // Cached once per tick in sv_main.qc StartFrame.
            qu_per_sec = sv_cached_anim_qu_per_sec_crouch;
#else
            qu_per_sec = cvar("sv_anim_qu_per_sec_crouch");
            if (qu_per_sec <= 0) qu_per_sec = 100;
#endif
        }
        else
        {
#ifdef SSQC
            qu_per_sec = sv_cached_anim_qu_per_sec;
#else
            qu_per_sec = cvar("sv_anim_qu_per_sec");
            if (qu_per_sec <= 0) qu_per_sec = 240;
#endif
        }

        vector delta = self.origin - self.pm_anim_prev_origin;
        delta_z = 0;
        makevectors([0, self.angles_y, 0]);

        float dist_fwd = delta * v_forward;
        if (backpedaling)
            dist_fwd = -fabs(dist_fwd);

        self.frame1time += dist_fwd / qu_per_sec;
    }
    else
    {
        // Wall-clock driven for idle/jump so the server hitbox leg timing
        // matches the CSQC visual model exactly (no usercmd-duration drift).
        // Backpedal case keeps the legacy negative-time trick (wrap below).
        if (backpedaling)
            self.frame1time = -(time - self.anim_bottom_start);
        else
            self.frame1time = time - self.anim_bottom_start;
    }
    self.pm_anim_prev_origin = self.origin;

    // Wrap negative time so engine doesn't choke (matches valve/CSQC hack)
    if (self.frame1time < 0)
        self.frame1time = 10.0;

    float bb = cvar("sv_player_basebone");
    if (bb <= 0)
    {
        // Sini: legs start at "Bip01 L Leg" (index 16)
        // CS models: legs start at "Bip01 L Thigh" (index 43)
        if (self.player_model_index == 5)
            bb = gettagindex(self, "Bip01 L Leg");
        else
            bb = gettagindex(self, "Bip01 L Thigh");
    }
    self.basebone = bb;

    // Progressive spine twist from lateral velocity
    makevectors([0, self.angles_y, 0]);
    float fCorrect = dotproduct(self.velocity, v_right) * 0.25;
    self.bonecontrol1 = fCorrect;
    self.bonecontrol2 = fCorrect * 0.5;
    self.bonecontrol3 = fCorrect * 0.25;
    self.bonecontrol4 = fCorrect * 0.125;

    // Keep the server entity on FTE's normal framestate path.  An
    // explicit IQM skeleton here is visible to MOVE_HITMODEL lagcomp
    // traces during firing, and the converted split-body poses can make
    // that path unstable while players are moving.  CSQC still applies
    // the visual spine deformation on the player_visual_proxy.
    SH_PlayerAnim_ClearIQMSpine();

    // Debug: verify blend values are being written (remove after testing)
    if (cvar("sv_debug_blendfracs"))
        dprint(sprintf("blend: sbf=%.3f sb2f=%.3f v_ang_x=%.1f bc1=%.3f bb=%g frame=%g bframe=%g\n",
            self.subblendfrac, self.subblend2frac, self.v_angle_x,
            self.bonecontrol1, self.basebone, self.frame, self.baseframe));
};

#endif // SSQC
