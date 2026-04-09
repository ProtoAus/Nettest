// ============================================================
//  shared/sh_weapon_logic.qc  -  Cross-weapon shared utilities
//  Compiled by both sv_progs and cl_progs.
//
//  Per-weapon state machines live in shared/weapons/sh_wpn_*.qc.
//  This file provides utilities used by all weapons.
// ============================================================

// --- Shared utilities ---

void() SH_WeaponEnterIdle =
{
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
};

string(float weapon_id) SH_WeaponViewModel =
{
    if (weapon_id == WEP_DEAGLE)
        return "models/weapons/wpn_csdeagle/v_deagle.mdl";
    if (weapon_id == WEP_KNIFE)
        return "models/weapons/wpn_csknife/v_knife.mdl";
    if (weapon_id == WEP_AK47)
        return "models/weapons/wpn_csak47/v_ak47.mdl";
    if (weapon_id == WEP_M4A1)
        return "models/weapons/wpn_csm4a1/v_m4a1.mdl";   // default silenced; overridden by M4A1 code
    if (weapon_id == WEP_FLAKSHOTGUN)
        return "models/weapons/wpn_flakshotgun/v_flakshotgun.mdl";
    if (weapon_id == WEP_PISTOL)
        return "models/weapons/wpn_pistol/v_pistol.mdl";
    if (weapon_id == WEP_GAUSS)
        return "models/weapons/wpn_hlgauss/v_gauss.mdl";
    if (weapon_id == WEP_CROSSBOW)
        return "models/weapons/wpn_hlcrossbow/v_crossbow.mdl";
    if (weapon_id == WEP_357)
        return "models/weapons/wpn_hl357/v_357.mdl";
    if (weapon_id == WEP_DOD98K)
        return "models/weapons/wpn_dod98k/v_98k.mdl";
    if (weapon_id == WEP_SCOUT)
        return "models/weapons/wpn_csscout/v_scout.mdl";
    if (weapon_id == WEP_GRENADELAUNCHER)
        return "models/weapons/wpn_grenadelauncher/v_grenlauncher.mdl";
    if (weapon_id == WEP_M249)
        return "models/weapons/wpn_csm249/v_m249.mdl";
    if (weapon_id == WEP_HLCROWBAR)
        return "models/weapons/wpn_hlcrowbar/v_crowbar.mdl";
    if (weapon_id == WEP_HLSHOTGUN)
        return "models/weapons/wpn_hlshotgun/v_shotgun.mdl";
    if (weapon_id == WEP_CSM3)
        return "models/weapons/wpn_csm3/v_m3.mdl";
    if (weapon_id == WEP_CSMP5)
        return "models/weapons/wpn_csmp5/v_mp5.mdl";
    if (weapon_id == WEP_REBAR)
        return "models/weapons/wpn_rebar/v_rebar.mdl";
    if (weapon_id == WEP_CSAWP)
        return "models/weapons/wpn_csawp/v_awp.mdl";
    if (weapon_id == WEP_WRENCH)
        return "models/weapons/wpn_wrench/v_wrench.mdl";
    return "";
};

string(float weapon_id) SH_WeaponWorldModel =
{
    if (weapon_id == WEP_DEAGLE)
        return "models/weapons/wpn_csdeagle/w_deagle.mdl";
    if (weapon_id == WEP_KNIFE)
        return "models/weapons/wpn_csknife/w_knife.mdl";
    if (weapon_id == WEP_AK47)
        return "models/weapons/wpn_csak47/w_ak47.mdl";
    if (weapon_id == WEP_M4A1)
        return "models/weapons/wpn_csm4a1/w_m4a1.mdl";
    if (weapon_id == WEP_FLAKSHOTGUN)
        return "models/weapons/wpn_flakshotgun/w_flakshotgun.mdl";
    if (weapon_id == WEP_PISTOL)
        return "models/weapons/wpn_pistol/w_pistol.mdl";
    if (weapon_id == WEP_GAUSS)
        return "models/weapons/wpn_hlgauss/w_gauss.mdl";
    if (weapon_id == WEP_CROSSBOW)
        return "models/weapons/wpn_hlcrossbow/w_crossbow.mdl";
    if (weapon_id == WEP_357)
        return "models/weapons/wpn_hl357/w_357.mdl";
    if (weapon_id == WEP_DOD98K)
        return "models/weapons/wpn_dod98k/w_98k.mdl";
    if (weapon_id == WEP_SCOUT)
        return "models/weapons/wpn_csscout/w_scout.mdl";
    if (weapon_id == WEP_GRENADELAUNCHER)
        return "models/weapons/wpn_grenadelauncher/w_grenlauncher.mdl";
    if (weapon_id == WEP_M249)
        return "models/weapons/wpn_csm249/w_m249.mdl";
    if (weapon_id == WEP_HLCROWBAR)
        return "models/weapons/wpn_hlcrowbar/w_crowbar.mdl";
    if (weapon_id == WEP_HLSHOTGUN)
        return "models/weapons/wpn_hlshotgun/w_shotgun.mdl";
    if (weapon_id == WEP_CSM3)
        return "models/weapons/wpn_csm3/w_m3.mdl";
    if (weapon_id == WEP_CSMP5)
        return "models/weapons/wpn_csmp5/w_mp5.mdl";
    if (weapon_id == WEP_REBAR)
        return "models/weapons/wpn_rebar/w_rebar.mdl";
    if (weapon_id == WEP_CSAWP)
        return "models/weapons/wpn_csawp/w_awp.mdl";
    if (weapon_id == WEP_WRENCH)
        return "models/weapons/wpn_wrench/g_wrench.mdl";
    return "";
};

string(float weapon_id) SH_WeaponDeploySound =
{
    if (weapon_id == WEP_DEAGLE)
        return "sounds/weapons/wpn_csdeagle/deploy.wav";
    if (weapon_id == WEP_KNIFE)
        return "sounds/weapons/wpn_csknife/deploy.wav";
    if (weapon_id == WEP_AK47)
        return "";   // boltpull plays at specific frame during draw animation
    if (weapon_id == WEP_M4A1)
        return "sounds/weapons/wpn_csm4a1/deploy.wav";
    if (weapon_id == WEP_FLAKSHOTGUN)
        return "";   // no deploy sound
    if (weapon_id == WEP_PISTOL)
        return "";
    if (weapon_id == WEP_GAUSS)
        return "";
    if (weapon_id == WEP_CROSSBOW)
        return "";
    if (weapon_id == WEP_357)
        return "";
    if (weapon_id == WEP_DOD98K)
        return "";
    if (weapon_id == WEP_SCOUT)
        return "";
    if (weapon_id == WEP_GRENADELAUNCHER)
        return "";
    if (weapon_id == WEP_M249)
        return "";
    if (weapon_id == WEP_HLCROWBAR)
        return "";
    if (weapon_id == WEP_HLSHOTGUN)
        return "";
    if (weapon_id == WEP_CSM3)
        return "";
    if (weapon_id == WEP_CSMP5)
        return "";
    if (weapon_id == WEP_REBAR)
        return "";
    if (weapon_id == WEP_CSAWP)
        return "sounds/weapons/wpn_csawp/deploy.wav";
    if (weapon_id == WEP_WRENCH)
        return "";
    return "";
};

// --- CSQC-only prediction bookkeeping ---
// On cl_progs.src this file is placed after sh_pmove.qc so
// pm_suppress_sounds is available.

#ifdef CSQC
void() CSQC_MuzzleFlash;
void(vector pos, vector normal) CSQC_BulletImpact;
void(vector pos, vector normal) CSQC_BulletImpactSilent;

// Fire a predicted traceline and show impact effect instantly.
// Called from per-weapon CSQC prediction after a successful fire.
void(float spread_base, float spread_move, float spread_fullspeed) CSQC_PredictedImpact =
{
    vector src, dir, end, flat_vel;
    float move_speed, spread, sx, sy;

    CSQC_MuzzleFlash();

    makevectors(input_angles);
    src = self.origin + self.view_ofs;

    flat_vel   = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = spread_base + (move_speed / spread_fullspeed) * spread_move;
    spread = min(spread, spread_base + spread_move);

    sx  = (random() * 2 - 1) * spread;
    sy  = (random() * 2 - 1) * spread;
    dir = normalize(v_forward + v_right * sx + v_up * sy);
    end = src + dir * 8192;

    traceline(src, end, MOVE_NORMAL, self);

    if (trace_fraction < 1.0)
        CSQC_BulletImpact(trace_endpos, trace_plane_normal);
};

// Fire N predicted pellets (shotgun).
void(float pellets, float spread_val) CSQC_PredictedShotgunImpact =
{
    vector src, dir, end;
    float sx, sy, i;

    CSQC_MuzzleFlash();

    makevectors(input_angles);
    src = self.origin + self.view_ofs;

    for (i = 0; i < pellets; i++)
    {
        sx  = (random() * 2 - 1) * spread_val;
        sy  = (random() * 2 - 1) * spread_val;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        traceline(src, end, MOVE_NORMAL, self);

        if (trace_fraction < 1.0)
            CSQC_BulletImpact(trace_endpos, trace_plane_normal);
    }
};

// Fire a predicted melee trace and show hit effect / play hit sound.
// Returns TRUE if something was hit.
float(float range, string hit_snd1, string hit_snd2, string miss_snd) CSQC_PredictedMeleeTrace =
{
    vector src, end;

    makevectors(input_angles);
    src = self.origin + self.view_ofs;
    end = src + v_forward * range;

    traceline(src, end, MOVE_NORMAL, self);

    if (trace_fraction < 1.0)
    {
        CSQC_BulletImpactSilent(trace_endpos, trace_plane_normal);
        if (hit_snd2 != "" && random() < 0.5)
            localsound(hit_snd2);
        else if (hit_snd1 != "")
            localsound(hit_snd1);
        return TRUE;
    }

    if (miss_snd != "")
        localsound(miss_snd);
    return FALSE;
};

void() CSQC_RecordPredictedWeaponSound =
{
    csqc_last_predicted_weapon_sound_time = cltime;
};

void() CSQC_RecordPredictedAutoSound =
{
    csqc_last_predicted_auto_sound_time = cltime;
};

void() CSQC_MarkPendingWeaponAck =
{
    if (pm_suppress_sounds)
        return;

    csqc_weapon_pending_ack_sequence
        = max(csqc_weapon_pending_ack_sequence, csqc_pred_sequence);
};
#endif
