// ============================================================
//  shared/weapons/sh_wpn_snowball.qc  -  Snowball + slingshot
//
//  Slot  : SLOT_UTILITY (multi-carry with HL grenade)
//  Stats : ammo_snowball, snowball_has_slingshot
//  Fire  : hold +attack to ready, release to throw.
//          Hand throw: 5 damage. Slingshot throw: 15 damage, longer range.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

.float snowball_throw_pending;
.float snowball_spawn_time;
.float snowball_throw_damage;
.float snowball_throw_speed_mult;
.float snowball_fake_spawned_serial;

const float MAX_AMMO_SNOWBALL          = 50;

const float SNOWBALL_SEQ_IDLE          = 0;
const float SNOWBALL_SEQ_READY         = 1;  // "start"
const float SNOWBALL_SEQ_THROW         = 2;
const float SNOWBALL_SEQ_DEPLOY        = 3;

const float SLINGSHOT_SEQ_IDLE         = 0;  // "angrybirds"
const float SLINGSHOT_SEQ_READY        = 1;
const float SLINGSHOT_SEQ_THROW        = 2;  // "weehee"
const float SLINGSHOT_SEQ_DEPLOY       = 3;

const float SNOWBALL_FRAME_INTERVAL    = 0.05;
const float SNOWBALL_DRAW_DURATION     = 0.69;
const float SNOWBALL_READY_DURATION    = 0.52;
const float SNOWBALL_THROW_DURATION    = 0.37;
const float SLINGSHOT_DRAW_DURATION    = 1.30;
const float SLINGSHOT_READY_DURATION   = 1.50;
const float SLINGSHOT_THROW_DURATION   = 1.00;

const float SNOWBALL_THROW_DELAY       = 0.12;
const float SLINGSHOT_THROW_DELAY      = 0.20;
const float SNOWBALL_DRYFIRE_DELAY     = 0.2;
const float SNOWBALL_SPECIAL_DELAY     = 0.35;

const float SNOWBALL_DAMAGE            = 15;
const float SLINGSHOT_DAMAGE           = 40;
const float SNOWBALL_THROW_FORWARD     = 560;
const float SNOWBALL_THROW_UPWARD      = 80;     // straight forward, no upward bias
const float SLINGSHOT_THROW_FORWARD    = 1200;
const float SLINGSHOT_THROW_UPWARD     = 0;     // straight forward, no upward bias
const float SNOWBALL_GRAVITY           = 0.65;
const float SNOWBALL_IMPACT_RADIUS     = 3.0;
const float SNOWBALL_CHARGE_TIME       = 1.5;
const float SNOWBALL_CHARGE_BONUS      = 0.5;

const string SNOWBALL_VIEWMODEL        = "models/weapons/wpn_snowball/v_snowball.mdl";
const string SNOWBALL_WORLDMODEL       = "models/weapons/wpn_snowball/w_snowball.mdl";
const string SNOWBALL_PMODEL           = "models/weapons/wpn_snowball/p_snowball.mdl";
const string SLINGSHOT_VIEWMODEL       = "models/weapons/wpn_snowball/v_slingshot.mdl";
const string SLINGSHOT_WORLDMODEL      = "models/weapons/wpn_snowball/w_slingshot.mdl";
const string SNOWBALL_DISPLAY_NAME     = "SNOWBALL";
const string SLINGSHOT_DISPLAY_NAME    = "SLINGSHOT";

const string SNOWBALL_HIT_SOUND        = "sounds/weapons/wpn_snowball/hit.wav";
const string SNOWBALL_THROW_SOUND      = "sounds/weapons/wpn_snowball/throw.wav";
const string SLINGSHOT_PULL_SOUND      = "sounds/weapons/wpn_snowball/stretch.wav";
const string SLINGSHOT_THROW_SOUND     = "sounds/weapons/wpn_snowball/snap.wav";

vector sh_snowball_impact_pos;
vector sh_snowball_impact_normal;
vector sh_snowball_probe_center;
float  sh_snowball_probe_best;

void(vector start, vector end, entity ignore_ent) SH_SnowballProbeSurface =
{
    float dist;

    traceline(start, end, MOVE_NORMAL, ignore_ent);
    if (trace_fraction >= 1)
        return;
    if (vlen(trace_plane_normal) <= 0)
        return;
    if (trace_ent != world && (!trace_ent || trace_ent.solid != SOLID_BSP))
        return;

    dist = vlen(trace_endpos - sh_snowball_probe_center);
    if (dist >= sh_snowball_probe_best)
        return;

    sh_snowball_probe_best = dist;
    sh_snowball_impact_pos = trace_endpos;
    sh_snowball_impact_normal = normalize(trace_plane_normal);
};

void(vector center, vector normal, vector velocity, entity ignore_ent) SH_SnowballResolveImpactSurface =
{
    vector n;
    float radius;

    if (vlen(normal) <= 0)
    {
        if (vlen(velocity) > 0)
            n = normalize(velocity) * -1;
        else
            n = '0 0 1';
    }
    else
        n = normalize(normal);

    radius = SNOWBALL_IMPACT_RADIUS * (fabs(n_x) + fabs(n_y) + fabs(n_z));
    sh_snowball_probe_center = center;
    sh_snowball_probe_best = 999999;
    sh_snowball_impact_pos = center - n * radius;
    sh_snowball_impact_normal = n;

    SH_SnowballProbeSurface(center + n * 16, center - n * 48, ignore_ent);

    if (vlen(velocity) > 0)
    {
        vector dir = normalize(velocity);
        SH_SnowballProbeSurface(center - dir * 16, center + dir * 64, ignore_ent);
    }

    SH_SnowballProbeSurface(center + '16 0 0', center - '48 0 0', ignore_ent);
    SH_SnowballProbeSurface(center - '16 0 0', center + '48 0 0', ignore_ent);
    SH_SnowballProbeSurface(center + '0 16 0', center - '0 48 0', ignore_ent);
    SH_SnowballProbeSurface(center - '0 16 0', center + '0 48 0', ignore_ent);
    SH_SnowballProbeSurface(center + '0 0 16', center - '0 0 48', ignore_ent);
    SH_SnowballProbeSurface(center - '0 0 16', center + '0 0 48', ignore_ent);
};

float(float now, float charge_start) SH_SnowballChargeMultiplier =
{
    float hold_time;

    hold_time = now - charge_start;
    if (hold_time < 0)
        hold_time = 0;

    return 1 + bound(0, hold_time / SNOWBALL_CHARGE_TIME, 1) * SNOWBALL_CHARGE_BONUS;
};

float(float wep) W_UtilityWeaponSelectable =
{
    return (wep == WEP_HLGRENADE
        || wep == WEP_SNOWBALL
        || wep == WEP_CSHEGRENADE
        || wep == WEP_CSFLASHBANG
        || wep == WEP_CSSMOKEGRENADE
        || wep == WEP_SATCHEL
        || wep == WEP_TRIPMINE
        || wep == WEP_SNARK
        || wep == WEP_CFC4);
};

float(float wep) W_UtilityWeaponPickup =
{
    return (wep == WEP_HLGRENADE
        || wep == WEP_SNOWBALL
        || wep == WEP_SLINGSHOT
        || wep == WEP_CSHEGRENADE
        || wep == WEP_CSFLASHBANG
        || wep == WEP_CSSMOKEGRENADE
        || wep == WEP_SATCHEL
        || wep == WEP_TRIPMINE
        || wep == WEP_SNARK
        || wep == WEP_CFC4);
};

float(entity player, float wep) W_UtilityEntityHasWeapon =
{
    if (!player)
        return FALSE;
    if (wep == WEP_HLGRENADE)
        return player.ammo_hlgrenade > 0;
    if (wep == WEP_SNOWBALL)
        return player.ammo_snowball > 0;
    if (wep == WEP_CSHEGRENADE)
        return player.ammo_cshegrenade > 0;
    if (wep == WEP_CSFLASHBANG)
        return player.ammo_csflashbang > 0;
    if (wep == WEP_CSSMOKEGRENADE)
        return player.ammo_cssmokegrenade > 0;
    if (wep == WEP_SATCHEL)
        return player.ammo_satchel > 0;
    if (wep == WEP_TRIPMINE)
        return player.ammo_tripmine > 0;
    if (wep == WEP_SNARK)
        return player.ammo_snark > 0;
    if (wep == WEP_CFC4)
        return player.ammo_cfc4 > 0;
    if (wep == WEP_SLINGSHOT)
        return player.snowball_has_slingshot > 0;
    return FALSE;
};

float(float wep) W_UtilityPlayerHasWeapon =
{
    return W_UtilityEntityHasWeapon(self, wep);
};

// Cycle order for impulse 4 (utility cycle).  Note: C4 deliberately
// EXCLUDED from this cycle — it lives on its own dedicated impulse
// (WEAPON_IMPULSE_C4 = 8) since plant-and-detonate is a fundamentally
// different action from throw-grenade.  C4 still uses the slot_utility
// plumbing internally for equip/drop/pickup, but the impulse-4 cycle
// skips over it.
// The canonical utility ring.  This used to be five hand-written branches of
// five lines each, all doing the identical thing: start one past from_wep,
// walk forward, wrap, and accept from_wep itself last.  Three more utilities
// would have made it eight branches of eight - so it is a table walk now.
// The order and the semantics are unchanged for the original five; the HL
// equipment is appended after them, which is where a player expects it.
const float UTILRING_COUNT = 8;
float(float idx) W_UtilityRingAt =
{
    if (idx == 0) return WEP_HLGRENADE;
    if (idx == 1) return WEP_SNOWBALL;
    if (idx == 2) return WEP_CSHEGRENADE;
    if (idx == 3) return WEP_CSFLASHBANG;
    if (idx == 4) return WEP_CSSMOKEGRENADE;
    if (idx == 5) return WEP_SATCHEL;
    if (idx == 6) return WEP_TRIPMINE;
    return WEP_SNARK;
};

float(float from_wep) W_UtilityNextCarried =
{
    float start = -1;
    float i;
    float w;

    for (i = 0; i < UTILRING_COUNT; i = i + 1)
        if (W_UtilityRingAt(i) == from_wep) { start = i; break; }

    if (start >= 0)
    {
        // Inclusive of from_wep on the final step: holding only grenades and
        // throwing one still leaves you holding grenades.
        for (i = 1; i <= UTILRING_COUNT; i = i + 1)
        {
            w = W_UtilityRingAt((start + i) % UTILRING_COUNT);
            if (W_UtilityPlayerHasWeapon(w)) return w;
        }
        return WEP_NONE;
    }

    // CFC4 lands here — it lives on impulse 8, not in this cycle — as does
    // any non-utility, and both want "whatever is carried".
    if (W_UtilityWeaponSelectable(self.slot_utility)
        && W_UtilityPlayerHasWeapon(self.slot_utility)
        && self.slot_utility != WEP_CFC4)
        return self.slot_utility;

    for (i = 0; i < UTILRING_COUNT; i = i + 1)
    {
        w = W_UtilityRingAt(i);
        if (W_UtilityPlayerHasWeapon(w)) return w;
    }
    return WEP_NONE;
};

float(float spent_wep) W_UtilityNextAfterSpent =
{
    return W_UtilityNextCarried(spent_wep);
};

// Walk the canonical utility order (W_UtilityRingAt: HL → SNOWBALL → CSHE →
// CSFLASH → CSSMOKE → SATCHEL → TRIPMINE → SNARK) in `dir` direction (+1
// next, −1 prev) starting from `current`, returning the next carried utility
// in that direction or WEP_NONE when there isn't one.  Non-wrapping by
// design: once the caller exhausts utilities in the requested direction, the
// cycle falls through to the next slot (primary on +1, melee on -1) instead
// of looping forever among the carried grenades.
float(float current, float dir) W_UtilityCycleCarried =
{
    float i, n, start = -1;
    for (i = 0; i < UTILRING_COUNT; i++)
        if (W_UtilityRingAt(i) == current) { start = i; break; }
    if (start < 0)
        return WEP_NONE;        // current isn't a utility — caller falls through

    for (i = 1; i < UTILRING_COUNT; i++)
    {
        n = start + i * dir;
        if (n < 0 || n >= UTILRING_COUNT)
            return WEP_NONE;    // walked off the end — exit the section
        if (W_UtilityPlayerHasWeapon(W_UtilityRingAt(n)))
            return W_UtilityRingAt(n);
    }
    return WEP_NONE;
};

float() SH_SnowballUsingSlingshot =
{
    return self.snowball_has_slingshot && self.snowball_use_slingshot;
};

string() SH_SnowballViewModel =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_VIEWMODEL;
    return SNOWBALL_VIEWMODEL;
};

string() SH_SnowballDisplayName =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_DISPLAY_NAME;
    return SNOWBALL_DISPLAY_NAME;
};

float() SH_SnowballDeploySeq =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_SEQ_DEPLOY;
    return SNOWBALL_SEQ_DEPLOY;
};

float() SH_SnowballReadySeq =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_SEQ_READY;
    return SNOWBALL_SEQ_READY;
};

float() SH_SnowballThrowSeq =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_SEQ_THROW;
    return SNOWBALL_SEQ_THROW;
};

float() SH_SnowballIdleSeq =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_SEQ_IDLE;
    return SNOWBALL_SEQ_IDLE;
};

float() SH_SnowballDrawDuration =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_DRAW_DURATION;
    return SNOWBALL_DRAW_DURATION;
};

float() SH_SnowballThrowDuration =
{
    // Both modes fire the THROW seq, then play DEPLOY (the re-arm /
    // ready-the-next-snowball animation) before the player can fire
    // again. Total WS_FIRE window = throw + deploy. The display-frame
    // switch from THROW seq to DEPLOY seq happens at the per-mode
    // throw-duration mark (see CSQC_SnowballDisplayFrame).
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_THROW_DURATION + SLINGSHOT_DRAW_DURATION;
    return SNOWBALL_THROW_DURATION + SNOWBALL_DRAW_DURATION;
};

float() SH_SnowballThrowDelay =
{
    if (SH_SnowballUsingSlingshot())
        return SLINGSHOT_THROW_DELAY;
    return SNOWBALL_THROW_DELAY;
};

float(float now) SH_SnowballTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_SnowballDrawDuration())
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_SPECIAL)
        return 0;

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_SnowballThrowDuration())
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

float(float now) SH_SnowballTryReady =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_snowball <= 0)
    {
        self.attack_finished = now + SNOWBALL_DRYFIRE_DELAY;
        return -1;
    }

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + SNOWBALL_DRYFIRE_DELAY;
    return 1;
};

float(float now) SH_SnowballThrow =
{
    float charge_start;
    float charge_mult;
    float base_damage;

    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;

    if (self.weaponstate != WS_SPECIAL) return 0;

    charge_start = self.wep_anim_start;
    charge_mult  = SH_SnowballChargeMultiplier(now, charge_start);
    self.ammo_snowball -= 1;
    self.weaponstate    = WS_FIRE;
    self.wep_action_id += 1;
    self.wep_anim_start = now;
    self.attack_finished = now + SH_SnowballThrowDuration();
    self.snowball_throw_speed_mult = charge_mult;

    // Charge-bonus damage — same multiplier as throw speed, so a fully-
    // held shot lands harder AND faster. SLINGSHOT_DAMAGE is the base;
    // at full charge the slingshot peaks at SLINGSHOT_DAMAGE * (1 +
    // SNOWBALL_CHARGE_BONUS) = 40 * 1.5 = 60. Hand throw peaks at 7.5.
    base_damage = SH_SnowballUsingSlingshot() ? SLINGSHOT_DAMAGE : SNOWBALL_DAMAGE;
    self.snowball_throw_damage = base_damage * charge_mult;

    if (self.ammo_snowball <= 0)
        self.slot_utility = W_UtilityNextAfterSpent(WEP_SNOWBALL);

    return 1;
};

float(float now) SH_SnowballTrySpecial =
{
    if (!self.snowball_has_slingshot) return 0;
    if (self.weapon != WEP_SNOWBALL) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.altfire_finished) return 0;

    self.snowball_use_slingshot = !self.snowball_use_slingshot;
    self.weaponstate = WS_DRAW;
    self.wep_action_id += 1;
    self.wep_anim_start = now;
    self.altfire_finished = now + SNOWBALL_SPECIAL_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(vector pos, vector normal, entity owner_ent, entity target_ent, float spawn_decal) W_SnowballImpactEffect =
{
    if (vlen(normal) <= 0)
        normal = '0 0 1';
    normal = normalize(normal);

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_SNOWSPLAT);
    WriteByte(MSG_MULTICAST, owner_ent ? num_for_edict(owner_ent) : 0);
    WriteByte(MSG_MULTICAST, spawn_decal ? 1 : 0);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteByte(MSG_MULTICAST, bound(0, floor(normal_x * 127 + 127.5), 254));
    WriteByte(MSG_MULTICAST, bound(0, floor(normal_y * 127 + 127.5), 254));
    WriteByte(MSG_MULTICAST, bound(0, floor(normal_z * 127 + 127.5), 254));
    // Target entnum so remote clients can attach the snow splat to a
    // brushmodel (func_breakable / func_door / func_button) and have
    // the tracked-decal renderer follow its motion + remove it on
    // break.  0 = world / non-BSP target (treated as a stationary
    // world decal).
    WriteShort(MSG_MULTICAST, (target_ent && target_ent != world) ? num_for_edict(target_ent) : 0);
    multicast(pos, MULTICAST_PHS);
};

void() W_SnowballTouch =
{
    vector n;
    vector impact_pos;

    if (other == self.owner)
        return;

    n = trace_plane_normal;
    if (vlen(n) <= 0 && vlen(self.velocity) > 0)
        n = normalize(self.velocity) * -1;
    if (vlen(n) <= 0)
        n = '0 0 1';
    SH_SnowballResolveImpactSurface(self.origin, n, self.velocity, self);
    impact_pos = sh_snowball_impact_pos;
    n = sh_snowball_impact_normal;

    // Mesh-intersection gate for player targets — bbox touch alone
    // isn't enough since the player bbox is wider than the animated
    // mesh.  Probe MOVE_HITMODEL forward along velocity, fall back to
    // a swept trace from prev-tick origin.  When BOTH probes miss the
    // mesh the snowball just grazed the bbox and we let it keep
    // flying past rather than popping out mid-air.  Non-player
    // targets (phys props, world, breakables) skip this gate entirely.
    //
    // sv_hitbox_expand is applied to `other` for the duration of the
    // probes (same idea as W_PlayersExpandHitboxes around hitscan).
    if (other.classname == "player")
    {
        float expand = cvar("sv_hitbox_expand");
        vector saved_mn = other.mins;
        vector saved_mx = other.maxs;
        if (expand > 0)
            setsize(other,
                    saved_mn - expand * '1 1 1',
                    saved_mx + expand * '1 1 1');

        float mesh_hit = 0;
        if (vlen(self.velocity) > 0)
        {
            vector vdir = normalize(self.velocity);
            traceline(self.origin - vdir * 8,
                      self.origin + vdir * 48,
                      MOVE_HITMODEL, self);
            if (trace_ent == other && trace_bone_id > 0)
                mesh_hit = 1;
        }
        if (!mesh_hit && self.proj_prev_origin != self.origin)
        {
            traceline(self.proj_prev_origin, self.origin,
                      MOVE_HITMODEL, self);
            if (trace_ent == other && trace_bone_id > 0)
                mesh_hit = 1;
        }

        if (expand > 0)
            setsize(other, saved_mn, saved_mx);

        if (!mesh_hit)
        {
            // Bbox-only graze — MOVETYPE_NOCLIP for the pass-through
            // window bypasses FTE's SV_Physics_Toss ClipVelocity (which
            // would otherwise flatten our velocity against the player
            // bbox face).  Velocity is snapshotted now and restored
            // verbatim by W_SnowballProjectileTick.
            self.proj_passthrough_savedvel = self.velocity;
            self.proj_passthrough_until = time + 0.06;
            self.movetype = MOVETYPE_NOCLIP;
            self.solid    = SOLID_NOT;
            setorigin(self, self.origin);
            // First restore tick fires next frame to swap in the pre-clip
            // velocity before NOCLIP integrates very far with the
            // engine-clipped tangent vector.  See W_PaintballProjectileTouch.
            self.nextthink = time + 0.001;
            return;
        }

        // Mesh confirmed.  Defer matches the hitscan / paintball
        // claim flow: when sv_trust_clienthits is on AND the shooter
        // pushes cl_predict_hits, the server waits for the client's
        // `cmd snowprojhit` claim (SV_HandleProjhitClaim) instead of
        // self-applying damage here.
        float defer_player = W_ShouldDeferToClaim(self.owner);
        if (!defer_player && W_CanDamageTarget(other))
        {
            // Paintgun gamemode: any snowball hit on a player is a
            // tag kill, matching paintball lethality so either weapon
            // is a valid "you're out" trigger.
            float final_damage = self.proj_damage;
            if (cvar("sv_gamemode") == GAMEMODE_PAINTGUN)
                final_damage = 1000;
            W_ApplyDamage(self.owner, other, final_damage);
        }
    }
    else if (W_CanDamageTarget(other))
        W_ApplyDamage(self.owner, other, self.proj_damage);

    if (other == world || other.solid == SOLID_BSP)
        W_SnowballImpactEffect(impact_pos, n, self.owner, other, TRUE);
    else
        W_SnowballImpactEffect(impact_pos, n, world, world, FALSE);
    remove(self);
};

void() W_SnowballProjectileTick =
{
    // Pass-through restoration is two-phase (see W_PaintballProjectileTick
    // for the full explanation):
    //   (a) First tick after touch — restore pre-glance velocity, since
    //       the engine's ClipVelocity already projected it onto the bbox
    //       tangent before our tick fires.  Letting NOCLIP integrate the
    //       clipped vector for the whole window produces the "bounce"
    //       deflection.
    //   (b) End of the 60ms window — restore MOVETYPE_TOSS + SOLID_BBOX
    //       so walls block again and gravity resumes.
    if (self.proj_passthrough_until > 0)
    {
        if (self.proj_passthrough_savedvel != '0 0 0')
        {
            self.velocity = self.proj_passthrough_savedvel;
            self.proj_passthrough_savedvel = '0 0 0';
        }
        if (time < self.proj_passthrough_until)
        {
            // Still in window — keep ticking quickly so phase (b)
            // lands on schedule, skip drag + swept-trace meanwhile.
            self.SendFlags |= 1;
            self.nextthink = time + Toss_NextThinkInterval();
            return;
        }
        self.movetype = MOVETYPE_TOSS;
        self.solid    = SOLID_BBOX;
        setorigin(self, self.origin);
        self.proj_passthrough_until = 0;
    }

    // Swept-trace tunneling guard.  The engine's SV_PushEntity does a
    // bbox sweep every physics frame, but a player MOVING into our
    // path between two frames can land in a "no overlap at frame N,
    // no overlap at frame N+1" gap.  Re-trace from the previous
    // tick's origin to the current origin and run the touch handler
    // by hand if anything intersected.  One tracebox per tick.
    // Skipped while in a pass-through window — re-tracing would just
    // re-touch the same player we're gliding past.
    if (self.proj_passthrough_until == 0 && self.proj_prev_origin != self.origin)
    {
        tracebox(self.proj_prev_origin, self.mins, self.maxs,
                 self.origin, MOVE_NORMAL, self);
        if (trace_fraction < 1 && trace_ent && trace_ent != self.owner)
        {
            other = trace_ent;
            W_SnowballTouch();   // removes self (or sets pass-through)
            return;
        }
    }
    self.proj_prev_origin = self.origin;

    self.SendFlags |= 1;
    if (time >= self.proj_fuse_end)
    {
        remove(self);
        return;
    }
    self.nextthink = time + Toss_NextThinkInterval();
};

void(entity player) W_SnowballPickupCopy =
{
    player.ammo_snowball = self.ammo_snowball;
};

void(entity player) W_SlingshotPickupCopy =
{
    player.snowball_has_slingshot = TRUE;
};

void() W_SnowballFire =
{
    float r = SH_SnowballTryReady(time);

    if (r == 1)
    {
        self.weaponframe = SH_SnowballReadySeq();
        self.wep_nextframe = time + SNOWBALL_FRAME_INTERVAL;
        if (SH_SnowballUsingSlingshot())
            sound(self, CHAN_WEAPON, SLINGSHOT_PULL_SOUND, 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_SnowballRelease =
{
    if (!SH_SnowballThrow(time)) return;

    self.weaponframe = SH_SnowballThrowSeq();
    self.wep_nextframe = time + SNOWBALL_FRAME_INTERVAL;
    self.snowball_throw_pending = 1;
    self.snowball_spawn_time = time + SH_SnowballThrowDelay();

    if (SH_SnowballUsingSlingshot())
        sound(self, CHAN_WEAPON, SLINGSHOT_THROW_SOUND, 1, ATTN_NORM);
    else
        sound(self, CHAN_WEAPON, SNOWBALL_THROW_SOUND, 1, ATTN_NORM);
};

void() W_SnowballSpecial =
{
    if (!SH_SnowballTrySpecial(time))
        return;

    self.weaponmodel = SH_SnowballViewModel();
    self.weapon_name = SH_SnowballDisplayName();
    self.weaponframe = SH_SnowballDeploySeq();
    self.wep_nextframe = time + SNOWBALL_FRAME_INTERVAL;
};

void() W_SnowballFrame =
{
    float was_fire;
    float result;

    if (self.weaponstate == WS_SPECIAL)
    {
        if (!self.button0)
            W_SnowballRelease();
        return;
    }

    if (self.weaponstate == WS_FIRE
        && self.snowball_throw_pending > 0
        && time >= self.snowball_spawn_time)
    {
        entity ball;
        float using_sling;
        float throw_mult;

        self.snowball_throw_pending = 0;
        using_sling = (self.snowball_throw_damage >= SLINGSHOT_DAMAGE);
        throw_mult = max(1, self.snowball_throw_speed_mult);

        makevectors(self.v_angle);
        ball = spawn();
        ball.owner = self;
        ball.classname = "proj_snowball";
        ball.movetype = MOVETYPE_TOSS;
        ball.solid = SOLID_BBOX;
        setmodel(ball, SNOWBALL_WORLDMODEL);
        setsize(ball, '-3 -3 -3', '3 3 3');
        setorigin(ball, self.origin + self.view_ofs + v_forward * 18);
        ball.velocity = self.velocity
                      + v_forward * (using_sling ? SLINGSHOT_THROW_FORWARD : SNOWBALL_THROW_FORWARD) * throw_mult
                      + v_up      * (using_sling ? SLINGSHOT_THROW_UPWARD  : SNOWBALL_THROW_UPWARD) * throw_mult;
        ball.avelocity = '260 420 180';
        ball.gravity = SNOWBALL_GRAVITY;
        ball.touch = W_SnowballTouch;
        ball.proj_damage = self.snowball_throw_damage;
        ball.proj_type = PROJ_TYPE_SNOWBALL;
        ball.SendEntity = projectile_SendEntity;
        ball.SendFlags = 1;
        ball.proj_fuse_end = time + 6;
        // Anti-spoof key for cmd snowprojhit (matched against the
        // chain-walk in SV_HandleProjhitClaim).  Pair this with the
        // client-side fake snowball storing the same wep_action_id.
        ball.wep_action_id = self.wep_action_id;
        // Snapshot for the swept-trace tunneling guard in the tick.
        ball.proj_prev_origin = ball.origin;
        ball.think = W_SnowballProjectileTick;
        ball.nextthink = time + Toss_NextThinkInterval();
    }

    was_fire = (self.weaponstate == WS_FIRE);
    result = SH_SnowballTickState(time);
    if (was_fire && (result & 1)
        && self.ammo_snowball <= 0
        && self.weapon == WEP_SNOWBALL)
    {
        // See sh_wpn_csgrenades.qc — explicit fallback chain matches
        // CSQC prediction so the empty grenade can't stick visually.
        if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
        else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
        else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
        else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
    }
};

void() W_SnowballEquip =
{
    W_StandardEquipSetup(SH_SnowballViewModel(),
        SH_SnowballDisplayName(),
        SH_SnowballDeploySeq(), SNOWBALL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire = W_SnowballFire;
    self.reload = __NULL__;
    self.wepframe = W_SnowballFrame;
    self.special = W_SnowballSpecial;
    self.snowball_throw_pending = 0;
    self.snowball_spawn_time = 0;
    self.snowball_throw_speed_mult = 1;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_SnowballDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_snowball = self.ammo_snowball;
    self.ammo_snowball = 0;

    setmodel(tgt, SNOWBALL_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 40');
    tgt.classname = "weapon_snowball";
    tgt.solid = SOLID_NOT;
    tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_SNOWBALL;
    tgt.weapon_slot = SLOT_UTILITY;
    tgt.weap_draw = W_SnowballEquip;
    tgt.weap_drop_func = W_SnowballDrop;
    tgt.pickupcopy = W_SnowballPickupCopy;
    tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid;
    tgt.nextthink = time + 0.7;
};

void() weapon_snowball =
{
    setmodel(self, SNOWBALL_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 40');
    self.classname = "weapon_snowball";
    self.solid = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_SNOWBALL;
    self.weapon_slot = SLOT_UTILITY;
    self.weap_draw = W_SnowballEquip;
    self.weap_drop_func = W_SnowballDrop;
    self.pickupcopy = W_SnowballPickupCopy;
    self.touch = weapon_touch;
    self.ammo_snowball = MAX_AMMO_SNOWBALL;
    W_RegisterMapWeapon(weapon_snowball);
};

void() weapon_slingshot =
{
    setmodel(self, SLINGSHOT_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 44');
    self.classname = "weapon_slingshot";
    self.solid = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_SLINGSHOT;
    self.weapon_slot = SLOT_UTILITY;
    self.weap_draw = __NULL__;
    self.weap_drop_func = __NULL__;
    self.pickupcopy = W_SlingshotPickupCopy;
    self.touch = weapon_touch;
    self.snowball_has_slingshot = TRUE;
    W_RegisterMapWeapon(weapon_slingshot);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_snowball_charge_start_time;
float csqc_snowball_pending_speed_mult;
float csqc_snowball_pending_action_id;

void(float new_weapon) CSQC_PredictSelectWeapon;
void(vector hit_pos, vector hit_normal, entity hit_target) CSQC_SpawnSnowSplat;
void() CSQC_FakeSnowballExpire;

// Two-phase pass-through restoration.  The engine's ClipVelocity
// already projected our velocity onto the bbox tangent at the end of
// the touch frame (FTE SV_Physics_Toss runs ClipVelocity after touch
// regardless of changes made inside touch), so phase (a) — the first
// call here, scheduled by CSQC_FakeSnowballTouch for ~+1ms after
// touch — swaps in the saved pre-glance velocity before NOCLIP
// integrates much.  Phase (b) — at proj_passthrough_until — restores
// MOVETYPE_TOSS + SOLID_BBOX so walls can splat us and gravity
// resumes, then hands back to CSQC_FakeSnowballExpire to ride out the
// remaining fuse.
void() CSQC_FakeSnowballPassThroughThink =
{
    if (self.proj_passthrough_savedvel != '0 0 0')
    {
        self.velocity = self.proj_passthrough_savedvel;
        self.proj_passthrough_savedvel = '0 0 0';
    }

    if (time < self.proj_passthrough_until)
    {
        // Phase (a) complete — wait out the rest of the window so the
        // NOCLIP segment can carry us clear of the bbox before walls
        // start blocking again.
        self.nextthink = self.proj_passthrough_until;
        return;
    }

    // Phase (b): restore the standard physics path + expire think.
    self.movetype = MOVETYPE_TOSS;
    self.solid    = SOLID_BBOX;
    setorigin(self, self.origin);
    self.proj_passthrough_until = 0;
    self.think = CSQC_FakeSnowballExpire;
    if (self.proj_fuse_end > time)
        self.nextthink = self.proj_fuse_end;
    else
        self.nextthink = time;   // fuse already expired during pass-through
};

void() CSQC_FakeSnowballTouch =
{
    vector n;
    vector impact_pos;

    if (other == self.owner)
        return;

    n = trace_plane_normal;
    if (vlen(n) <= 0 && vlen(self.velocity) > 0)
        n = normalize(self.velocity) * -1;
    if (vlen(n) <= 0)
        n = '0 0 1';
    SH_SnowballResolveImpactSurface(self.origin, n, self.velocity, self);
    impact_pos = sh_snowball_impact_pos;
    n = sh_snowball_impact_normal;

    // Player hit → emit snowprojhit claim if trust mode is on.  Mirror
    // of CSQC_FakePaintballTouch — the server resolves the slot via
    // an active proj_snowball owned by us with matching wep_action_id
    // (anti-spoof key in SV_HandleProjhitClaim).
    float is_player_hit =
        ((other != world && other.entnum >= 1 && other.entnum <= maxclients)
         || (other.classname == "player_visual_proxy"));

    if (is_player_hit)
    {
        // Mesh-intersection gate.  Bbox touch is necessary but not
        // sufficient — the bbox is significantly bigger than the
        // animated mesh, so a snowball whistling past the shoulder
        // would otherwise still register.  Probe with MOVE_HITMODEL:
        // forward along velocity first, and on miss fall back to a
        // swept trace from the previous tick's origin to current.
        // Damage only applies when one of the probes lands on
        // `other`'s mesh AND populates a non-zero bone.
        //
        // sv_hitbox_expand applied to `other` for the probe duration
        // so outstretched limbs aren't bbox-culled before the per-
        // bone test.  Read via serverkeyfloat (broadcast in sv_main.qc
        // SV_UpdateMovementServerInfo) since this is an SV-side cvar;
        // a local cvar() would return 0 on the client.
        float expand = serverkeyfloat("sv_hitbox_expand");
        vector saved_mn = other.mins;
        vector saved_mx = other.maxs;
        if (expand > 0)
            setsize(other,
                    saved_mn - expand * '1 1 1',
                    saved_mx + expand * '1 1 1');

        float mesh_hit = 0;
        float bone_id  = 0;
        if (vlen(self.velocity) > 0)
        {
            vector vdir = normalize(self.velocity);
            traceline(self.origin - vdir * 8,
                      self.origin + vdir * 48,
                      MOVE_HITMODEL, self);
            if (trace_ent == other && trace_bone_id > 0)
            {
                mesh_hit = 1;
                bone_id  = trace_bone_id;
            }
        }
        if (!mesh_hit && self.proj_prev_origin != self.origin)
        {
            traceline(self.proj_prev_origin, self.origin,
                      MOVE_HITMODEL, self);
            if (trace_ent == other && trace_bone_id > 0)
            {
                mesh_hit = 1;
                bone_id  = trace_bone_id;
            }
        }

        if (expand > 0)
            setsize(other, saved_mn, saved_mx);

        if (!mesh_hit)
        {
            // Bbox-only graze — MOVETYPE_NOCLIP + SOLID_NOT bypass
            // FTE's SV_Physics_Toss ClipVelocity (which otherwise
            // pins our velocity flat against the bbox face).
            // CSQC_FakeSnowballPassThroughThink restores both fields
            // once `time >= proj_passthrough_until` and re-arms the
            // expire think with the remaining fuse.
            self.proj_passthrough_savedvel = self.velocity;
            self.proj_passthrough_until    = time + 0.06;
            self.movetype = MOVETYPE_NOCLIP;
            self.solid    = SOLID_NOT;
            setorigin(self, self.origin);
            self.think = CSQC_FakeSnowballPassThroughThink;
            // Fire phase (a) on the next frame so velocity is swapped
            // in before NOCLIP integrates much with the engine-clipped
            // tangent vector.  Phase (b) self-reschedules from there.
            self.nextthink = time + 0.001;
            return;
        }

        if (cvar("sv_trust_clienthits") >= 1)
        {
            entity saved_te = trace_ent;
            trace_ent = other;
            float hitgroup = W_BoneToHitgroup(bone_id);
            trace_ent = saved_te;

            // Wire format: cmd snowprojhit <slot> <damage> <action_id> <life_serial> <hitgroup>
            float slot = (other.classname == "player_visual_proxy")
                         ? other.vis_owner_entnum : other.entnum;
            float life_serial = (other.classname == "player_visual_proxy")
                                ? other.vis_life_serial : 0;
            localcmd(sprintf("cmd snowprojhit %g %g %g %g %g\n",
                             slot, self.proj_damage, self.wep_action_id,
                             life_serial, hitgroup));
            CSQC_TryPlayPredictedHitmarker();
        }
    }
    else if (other == world || other.solid == SOLID_BSP)
    {
        pointsound(impact_pos, SNOWBALL_HIT_SOUND, 1, ATTN_NORM);
        CSQC_SpawnSnowSplat(impact_pos, n, other);
    }
    remove(self);
};

void() CSQC_FakeSnowballExpire =
{
    remove(self);
};

void() CSQC_SpawnFakeSnowball =
{
    entity ball;
    float using_sling;
    float throw_mult;

    using_sling = (self.snowball_throw_damage >= SLINGSHOT_DAMAGE);
    throw_mult = max(1, self.snowball_throw_speed_mult);
    if (csqc_snowball_pending_action_id == self.wep_action_id)
        throw_mult = max(throw_mult, csqc_snowball_pending_speed_mult);
    csqc_snowball_pending_action_id = 0;
    csqc_snowball_pending_speed_mult = 1;

    makevectors(input_angles);
    ball = spawn();
    setmodel(ball, SNOWBALL_WORLDMODEL);
    setsize(ball, '-3 -3 -3', '3 3 3');
    setorigin(ball, self.origin + self.view_ofs + v_forward * 18);
    ball.owner = self;
    ball.velocity = self.velocity
                  + v_forward * (using_sling ? SLINGSHOT_THROW_FORWARD : SNOWBALL_THROW_FORWARD) * throw_mult
                  + v_up      * (using_sling ? SLINGSHOT_THROW_UPWARD  : SNOWBALL_THROW_UPWARD) * throw_mult;
    ball.avelocity = '260 420 180';
    ball.movetype = MOVETYPE_TOSS;
    ball.solid = SOLID_BBOX;
    ball.gravity = SNOWBALL_GRAVITY;
    ball.drawmask = MASK_ENGINE;
    ball.touch = CSQC_FakeSnowballTouch;
    ball.think = CSQC_FakeSnowballExpire;
    ball.proj_fuse_end = time + 6;     // re-armed by the pass-through restore
    ball.nextthink = ball.proj_fuse_end;
    // Tag the fake so generic CSQC iterators (e.g. cl_throwtrail's
    // per-frame walk via find(world, classname, ...)) can discover
    // both the server-replicated CSQC projectile and the local
    // owner-side fake.  Without these the thrower never sees their
    // own projectile's trail because the fake is hidden under no
    // classname.
    ball.classname             = "csqc_projectile";
    ball.csqc_projectile_type  = PROJ_TYPE_SNOWBALL;
    // Anti-spoof key + damage stamp for the snowprojhit claim path.
    // Damage is computed the same way the server does — see
    // W_SnowballFrame's `ball.proj_damage = self.snowball_throw_damage`.
    ball.wep_action_id = self.wep_action_id;
    ball.proj_damage   = self.snowball_throw_damage;
};

void() CSQC_PredictSnowballSpecial =
{
    if (!SH_SnowballTrySpecial(csqc_pred_time))
        return;

    self.weapon_viewmodel = SH_SnowballViewModel();
    self.weapon_name = SH_SnowballDisplayName();
    CSQC_MarkPendingWeaponAck();
};

void() CSQC_PredictSnowballCommand =
{
    float r;
    float was_fire;

    if (input_buttons & 1)
    {
        r = SH_SnowballTryReady(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
                csqc_snowball_charge_start_time = csqc_pred_time;
            if (!pm_suppress_sounds && SH_SnowballUsingSlingshot())
            {
                localsound(SLINGSHOT_PULL_SOUND);
                CSQC_RecordPredictedWeaponSound();
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

    if (self.weaponstate == WS_SPECIAL && !(input_buttons & 1))
    {
        if (SH_SnowballThrow(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds && csqc_snowball_charge_start_time > 0)
            {
                self.snowball_throw_speed_mult = max(self.snowball_throw_speed_mult,
                    SH_SnowballChargeMultiplier(csqc_pred_time, csqc_snowball_charge_start_time));
                csqc_snowball_pending_speed_mult = self.snowball_throw_speed_mult;
                csqc_snowball_pending_action_id = self.wep_action_id;
                csqc_snowball_charge_start_time = 0;
            }
            self.snowball_throw_pending = 1;
            self.snowball_spawn_time = csqc_pred_time + SH_SnowballThrowDelay();
            if (!pm_suppress_sounds)
            {
                if (self.snowball_throw_damage >= SLINGSHOT_DAMAGE)
                    localsound(SLINGSHOT_THROW_SOUND);
                else
                    localsound(SNOWBALL_THROW_SOUND);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    if (self.weaponstate == WS_FIRE
        && self.snowball_throw_pending > 0
        && csqc_pred_time >= self.snowball_spawn_time
        && !pm_suppress_sounds
        && self.snowball_fake_spawned_serial != self.wep_action_id)
    {
        self.snowball_throw_pending = 0;
        self.snowball_fake_spawned_serial = self.wep_action_id;
        CSQC_SpawnFakeSnowball();
    }

    was_fire = (self.weaponstate == WS_FIRE);
    SH_SnowballTickState(csqc_pred_time);

    if (was_fire && self.weaponstate == WS_IDLE
        && self.ammo_snowball <= 0
        && self.weapon == WEP_SNOWBALL)
    {
        if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
        else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
        else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
        else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
    }
};

float(float elapsed) CSQC_SnowballDisplayFrame =
{
    entity old_self;
    float seq;

    old_self = self;
    self = predicted_player;
    if (predicted_player.weaponstate == WS_DRAW)
        seq = SH_SnowballDeploySeq();
    else if (predicted_player.weaponstate == WS_SPECIAL)
        seq = SH_SnowballReadySeq();
    else if (predicted_player.weaponstate == WS_FIRE)
    {
        // Two-phase WS_FIRE for both modes:
        //   [0, throw_duration)              → THROW seq (release)
        //   [throw_duration, +draw_duration) → DEPLOY seq (re-arm /
        //                                      pull-out-the-next-ball)
        // sequence_time_override resets the deploy-anim playhead to 0
        // so it doesn't pick up mid-anim — matches paintball reload
        // pattern.
        float throw_dur = SH_SnowballUsingSlingshot()
            ? SLINGSHOT_THROW_DURATION
            : SNOWBALL_THROW_DURATION;
        if (elapsed >= throw_dur)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = max(0, elapsed - throw_dur);
            seq = SH_SnowballDeploySeq();
        }
        else
            seq = SH_SnowballThrowSeq();
    }
    else
        seq = SH_SnowballIdleSeq();
    self = old_self;

    return seq;
};

void() CSQC_SnowballDropClear =
{
    self.ammo_snowball = 0;
};

void() CSQC_SnowballEquip =
{
    self.weapon_name = SH_SnowballDisplayName();
    self.weapon_viewmodel = SH_SnowballViewModel();
    self.weapon_worldmodel = SNOWBALL_WORLDMODEL;
    self.weapon_deploy_sound = "";
    self.snowball_throw_speed_mult = 1;
    self.csqc_predict_cmd = CSQC_PredictSnowballCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame = CSQC_SnowballDisplayFrame;
    self.csqc_drop_clear = CSQC_SnowballDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
