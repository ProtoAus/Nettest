// ============================================================
//  shared/weapons/sh_wpn_paintball.qc  -  Paintball marker
//
//  Slot  : SLOT_PRIMARY
//  Stats : 100-round hopper, 200 reserve, full-auto
//  Fire  : hitscan paintball with clipped colored splat decals
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

.float mag_paintball;
.float ammo_paintball;
.float paintball_snd_stage;
// CSQC: action_id of the most-recent shot that already spawned its
// local fake projectile, so reconcile-replay ticks for the same shot
// don't re-spawn (matches the snowball_fake_spawned_serial pattern).
.float paintball_fake_spawned_serial;
// SSQC + CSQC: spawn origin stored on the projectile so the touch
// handler can reproduce the same distance-falloff curve as hitscan.
.vector paintball_spawn_origin;
// CSQC fake projectile's expiry time. proj_fuse_end (sh_customdefs.qc)
// is gated behind #ifdef SSQC and used by the server's mirror; the
// CSQC fake gets its own field to stay independent.
.float paintball_fake_fuse_end;

const float PAINTBALL_SEQ_DRAW         = 0;
const float PAINTBALL_SEQ_SHOOT        = 1;
const float PAINTBALL_SEQ_IDLE         = 2;
const float PAINTBALL_SEQ_RELOAD_OPEN  = 3;
const float PAINTBALL_SEQ_RELOAD_LOOP  = 4;
const float PAINTBALL_SEQ_RELOAD_CLOSE = 5;

const float PAINTBALL_FRAME_INTERVAL   = 0.05;
const float PAINTBALL_DRAW_DURATION    = 1.00;
const float PAINTBALL_FIRE_DURATION    = 0.11;
const float PAINTBALL_FIRE_DELAY       = 0.11;
const float PAINTBALL_RELOAD_OPEN_TIME = 2.00;
const float PAINTBALL_RELOAD_LOOP_TIME = 3.17;
const float PAINTBALL_RELOAD_APPLY_TIME = 5.17;  // reload.wav start + 3.17s
const float PAINTBALL_RELOAD_CLOSE_TIME = 2.00;
const float PAINTBALL_RELOAD_DURATION  = 7.17;
const float PAINTBALL_DRYFIRE_DELAY    = 0.20;

const float PAINTBALL_LIDOPEN_TIME     = 1.00;
const float PAINTBALL_RELOAD_SOUND_TIME = 2.00;
const float PAINTBALL_LIDCLOSE_TIME    = 6.3367; // ball_rel3 frame 35 @ 30 fps

const float MAX_MAG_PAINTBALL          = 100;
const float MAX_AMMO_PAINTBALL         = 200;

const float PAINTBALL_BASE_SPREAD      = 0.01;
const float PAINTBALL_MOVE_SPREAD      = 0.065;
const float PAINTBALL_FULL_SPREAD_SPEED = 320;
const float PAINTBALL_CLOSE_DAMAGE     = 7;
const float PAINTBALL_MIN_DAMAGE       = 4;
const float PAINTBALL_DAMAGE_FALLOFF_RANGE = 2048;
const float PAINTBALL_SPLAT_HALF_SIZE  = 4.5;

// View kick. Mild — full-auto with low damage, kicks should feel
// present without dominating the screen. Pitch is the per-shot
// upward impulse; variance is the ± yaw jitter range; strength
// is the per-weapon multiplier on top of sv_gunkick_strength.
const float PAINTBALL_KICK_PITCH       = 0.6;
const float PAINTBALL_KICK_VARIANCE    = 0.4;
const float PAINTBALL_KICK_STRENGTH    = 0.7;

// Projectile mode (sv_paintball_projectile 1). Tunables for the
// arcing colourful round that replaces hitscan when the cvar is on.
//   _SPEED   muzzle velocity in qu/s. Fast enough to feel responsive,
//            slow enough to see the arc droop visibly.
//   _GRAVITY .gravity factor — must equal Projectile_TypeGravity for
//            PROJ_TYPE_PAINTBALL in sh_weapons.qc so CSQC extrap
//            curves match the SSQC MOVETYPE_TOSS path.
//   _QDRAG   quadratic drag coefficient. Per-tick velocity scaling
//            is (1 - QDRAG * |v| * dt). Quadratic in |v| means fast
//            shots decelerate hard up front then settle, like real
//            air resistance. 0.0005 with v=1800 + dt=1/64 = ~1.4%
//            per tick at launch, falling off as the ball slows.
//            Compile-time constant (NOT a cvar) so client and server
//            see the exact same value — quadratic divergence is more
//            sensitive to coefficient mismatch than linear.
//   _FUSE    seconds the projectile lives before self-removal.
//   _SCALE   model scale multiplier (snowball mesh shrunk to read
//            as a small marker round).
//   _SIZE    bbox half-extent (must match _SCALE for collision feel).
const float PAINTBALL_PROJ_SPEED       = 1800;
const float PAINTBALL_PROJ_GRAVITY     = 0.45;
const float PAINTBALL_PROJ_QDRAG       = 0.0005;
const float PAINTBALL_PROJ_FUSE        = 4;
const float PAINTBALL_PROJ_SCALE       = 0.25;
const float PAINTBALL_PROJ_SIZE        = 1.5;
// Visual-only muzzle offset from the camera origin so the round
// appears to launch from the gun model instead of the eye. Forward
// puts the spawn ahead of the camera (off the near-clip plane);
// right matches the right-handed viewmodel position; down nudges
// the visible mesh's pivot to align with the actual barrel line.
// CSQC mirrors this with cl_lefthand handling — the server always
// uses RIGHT because remote viewers don't have a meaningful
// "handedness" for someone else's viewmodel.
const float PAINTBALL_PROJ_MUZZLE_FORWARD = 42;
const float PAINTBALL_PROJ_MUZZLE_RIGHT   = 8.1;
const float PAINTBALL_PROJ_MUZZLE_DOWN    = 2.7;

// Shared drag step. Pulled into a helper so the SSQC mirror and the
// CSQC fake apply IDENTICAL per-tick velocity decay — quadratic drag
// is sensitive to formula divergence (a slightly different scale
// each tick compounds), so both sides must call this function with
// the same dt to stay locked together visually.
//
// The clamp `if (scale < 0) scale = 0` matters: at very high launch
// speeds (or if the user bumps PAINTBALL_PROJ_QDRAG too far) the
// per-tick scale could go negative, which would flip velocity sign
// and shoot the ball backward. Clamping floors the speed at zero
// for that tick instead — physically it just means drag exceeded
// the kinetic energy budget at this dt.
vector(vector vel, float dt) W_PaintballApplyDrag =
{
    float speed = vlen(vel);
    if (speed <= 0)
        return vel;
    float scale = 1 - PAINTBALL_PROJ_QDRAG * speed * dt;
    if (scale < 0)
        scale = 0;
    return vel * scale;
};

const string PAINTBALL_VIEWMODEL       = "models/weapons/wpn_paintball/v_excal.mdl";
const string PAINTBALL_WORLDMODEL      = "models/weapons/wpn_paintball/w_excal.mdl";
const string PAINTBALL_DISPLAY_NAME    = "PAINTBALL";
const string PAINTBALL_FIRE_SOUND      = "sounds/weapons/wpn_paintball/fire.wav";
const string PAINTBALL_LIDOPEN_SOUND   = "sounds/weapons/wpn_paintball/lidopen.wav";
const string PAINTBALL_LIDCLOSE_SOUND  = "sounds/weapons/wpn_paintball/lidclose.wav";
const string PAINTBALL_RELOAD_SOUND    = "sounds/weapons/wpn_paintball/reload.wav";

vector(float seed) SH_PaintballColour =
{
    float r;

    r = SH_SpreadHash(seed + 19.71);
    if (r < 0.14) return '1.00 0.12 0.12';
    if (r < 0.28) return '0.10 0.42 1.00';
    if (r < 0.42) return '0.05 0.90 0.20';
    if (r < 0.56) return '1.00 0.82 0.05';
    if (r < 0.70) return '1.00 0.15 0.85';
    if (r < 0.84) return '0.05 0.95 0.95';
    return '1.00 0.42 0.05';
};

float(float now) SH_PaintballTickState =
{
    return SH_StandardTickState(now, mag_paintball, ammo_paintball, MAX_MAG_PAINTBALL,
        PAINTBALL_DRAW_DURATION, PAINTBALL_FIRE_DURATION,
        PAINTBALL_RELOAD_DURATION, PAINTBALL_RELOAD_APPLY_TIME);
};

float(float now) SH_PaintballTryFire =
{
    return SH_StandardTryFire(now, mag_paintball, PAINTBALL_FIRE_DELAY, PAINTBALL_DRYFIRE_DELAY);
};

float(float now) SH_PaintballTryReload =
{
    return SH_StandardTryReload(now, mag_paintball, ammo_paintball, MAX_MAG_PAINTBALL,
        PAINTBALL_RELOAD_DURATION);
};

// Distance-based damage falloff for projectile-mode touches. Mirrors
// the hitscan W_LinearDamageFalloff call so balance stays equivalent
// between modes — close-range hits land 7, falloff asymptotes to 4
// at 2048 qu (PAINTBALL_DAMAGE_FALLOFF_RANGE). Shared scope so both
// the server projectile touch (W_PaintballProjectileTouch) and the
// CSQC fake projectile touch (CSQC_FakePaintballTouch) compute the
// same damage curve.
float(vector spawn_origin, vector hit_pos) W_PaintballProjectileDamage =
{
    float dist = vlen(hit_pos - spawn_origin);
    return W_LinearDamageFalloff(dist, PAINTBALL_CLOSE_DAMAGE,
        PAINTBALL_MIN_DAMAGE, PAINTBALL_DAMAGE_FALLOFF_RANGE);
};

// Resolve the actual surface normal at a projectile touch. Touch
// handlers receive trace_plane_normal as zero often enough (engine
// fast-path doesn't always populate it for swept-AABB/tri contacts)
// that falling back to the negated velocity puts the decal facing
// the SHOOTER instead of the WALL — the visible bug. We probe a
// short ray forward along the projectile's velocity to hit the
// surface and read its real normal.
//
// `out_normal` is the resolved normal (always a unit vector when
// trace hits something; '0 0 1' fallback otherwise). `pos` is the
// projectile's current origin; `vel` is its velocity; `ignore_ent`
// is the projectile itself so the trace doesn't self-hit.
vector(vector pos, vector vel, entity ignore_ent) W_PaintballProbeNormal =
{
    vector dir;
    if (vlen(vel) > 0)
        dir = normalize(vel);
    else
        dir = '0 0 -1';   // last-resort, treat as falling-down hit

    // Probe a short ray a few units forward + a few units back to
    // span the contact point, since the engine may have stopped the
    // projectile slightly before or after the surface plane.
    traceline(pos - dir * 4, pos + dir * 8, MOVE_NORMAL, ignore_ent);
    if (trace_fraction < 1 && vlen(trace_plane_normal) > 0)
        return normalize(trace_plane_normal);

    // Fallback: trace straight up/down from the contact point — works
    // for floors / ceilings when the forward probe misses (projectile
    // grazed the surface tangentially).
    traceline(pos + '0 0 4', pos + '0 0 -8', MOVE_NORMAL, ignore_ent);
    if (trace_fraction < 1 && vlen(trace_plane_normal) > 0)
        return normalize(trace_plane_normal);

    // Last-resort: world-up. Decal won't face the actual wall but at
    // least won't be aligned to the trajectory.
    return '0 0 1';
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(vector pos, vector normal, entity owner_ent, entity target_ent, vector color) W_PaintballSplatEffect =
{
    if (vlen(normal) <= 0)
        normal = '0 0 1';
    normal = normalize(normal);

    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_PAINTSPLAT);
    WriteByte(MSG_MULTICAST, owner_ent ? num_for_edict(owner_ent) : 0);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteByte(MSG_MULTICAST, bound(0, floor(normal_x * 127 + 127.5), 254));
    WriteByte(MSG_MULTICAST, bound(0, floor(normal_y * 127 + 127.5), 254));
    WriteByte(MSG_MULTICAST, bound(0, floor(normal_z * 127 + 127.5), 254));
    WriteByte(MSG_MULTICAST, bound(0, floor(color_x * 255 + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(color_y * 255 + 0.5), 255));
    WriteByte(MSG_MULTICAST, bound(0, floor(color_z * 255 + 0.5), 255));
    WriteShort(MSG_MULTICAST, (target_ent && target_ent != world) ? num_for_edict(target_ent) : 0);
    // PHS rather than PVS so spectators (who can lag behind the
    // followed player's PVS leaf when the engine hasn't moved their
    // server-side entity yet) still receive paint splats.  Paintballs
    // are also a strong audio cue — fits PHS by intent.  Bandwidth
    // cost vs PVS is small (23 bytes per splat, paintball-only).
    multicast(pos, MULTICAST_PHS);
};

void(entity player) W_PaintballPickupCopy =
{
    player.mag_paintball = self.mag_paintball;
    player.ammo_paintball = self.ammo_paintball;
};

// Forward decl — defined below in the projectile-mode block.
void(vector src, vector dir) W_PaintballSpawnProjectile;

void() W_PaintballShoot =
{
    vector src, dir, end, flat_vel, color;
    float spread, sx, sy, move_speed, dist, damage, hitgroup;

    // Apply view kick BEFORE the makevectors call so the shot uses the
    // kicked aim (matches W_PenetratingHitscanShoot at sh_weapon_standard.qc:495).
    // Restore v_angle afterward — the kick is tracked in view_kick_*; the
    // player's underlying input angle must stay unmutated.
    SH_ApplyViewKick(PAINTBALL_KICK_PITCH, PAINTBALL_KICK_VARIANCE, PAINTBALL_KICK_STRENGTH);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    flat_vel = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = PAINTBALL_BASE_SPREAD + (move_speed / PAINTBALL_FULL_SPREAD_SPEED) * PAINTBALL_MOVE_SPREAD;
    spread = min(spread, PAINTBALL_BASE_SPREAD + PAINTBALL_MOVE_SPREAD);
    spread = spread * SH_GetSpreadScale() + sh_spread_flat;

    if (spread > 0)
    {
        sx = SH_SpreadJitter(self.wep_action_id, 0) * spread;
        sy = SH_SpreadJitter(self.wep_action_id, 1) * spread;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
    }
    else
        dir = v_forward;

    // Projectile mode: spawn a colourful arcing round and stop here.
    // The projectile's own touch handler resolves damage + splat
    // when it lands. Hitscan branch below is skipped.
    //
    // Visual-only muzzle offset — v_forward / v_right are still set
    // from the kicked-aim makevectors above. Pushes the spawn off
    // the camera origin so the round visibly leaves the gun model.
    // Note: the falloff math uses this offset spawn_origin too — a
    // ~16qu shift over a 2048qu falloff range is < 1% damage drift,
    // negligible vs. the visual win.
    if (cvar("sv_paintball_projectile"))
    {
        vector muzzle = src + v_forward * PAINTBALL_PROJ_MUZZLE_FORWARD
                            + v_right   * PAINTBALL_PROJ_MUZZLE_RIGHT
                            - '0 0 1'   * PAINTBALL_PROJ_MUZZLE_DOWN;
        W_PaintballSpawnProjectile(muzzle, dir);
        return;
    }

    end = src + dir * 8192;

    W_PlayersExpandHitboxes();
    Lagcomp_BeginRewind(self);
    // Hitscan branch — MOVE_HITMODEL refines the bbox-broadphase to
    // mesh hitboxes so trace_bone_id is populated for the hitgroup
    // classifier downstream.  In paintgun gamemode the multiplier
    // doesn't matter (any hit = tag kill) but in regular play the
    // headshot/leg distinction does, so the trace stays HITMODEL.
    W_ServerTraceLineWithPhysDrops(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    W_PlayersRestoreHitboxes();

    if (trace_fraction < 1)
    {
        dist = vlen(trace_endpos - src);
        damage = W_LinearDamageFalloff(dist, PAINTBALL_CLOSE_DAMAGE,
            PAINTBALL_MIN_DAMAGE, PAINTBALL_DAMAGE_FALLOFF_RANGE);
        hitgroup = W_BoneToHitgroup(trace_bone_id);
        damage = damage * W_HitgroupDamageMultiplier(hitgroup);

        if (W_CanDamageTarget(trace_ent))
        {
            // Per-shot debug overlay: emit regardless of trust mode (the
            // !defer_player block is skipped in trust-1). Self-gates on the cvar.
#ifdef SSQC
            W_SendServerHitboxes(trace_ent);
#endif

            float defer_player = (trace_ent.classname == "player") && W_ShouldDeferToClaim(self);
            if (!defer_player)
            {
                trace_ent.death_hitgroup = hitgroup;
                // Paintgun gamemode: any paintball hit on a player is a
                // tag kill.  Bump damage to far above any reasonable
                // health pool — W_ApplyDamage clamps to remaining HP
                // anyway, and non-player hits keep their normal damage
                // (the gamemode only changes player-vs-player lethality).
                float final_damage = damage;
                if (cvar("sv_gamemode") == GAMEMODE_PAINTGUN
                    && trace_ent.classname == "player")
                    final_damage = 1000;
                W_ApplyDamage(self, trace_ent, final_damage);
            }
        }
        else
            PhysProp_TryPushFromTrace(dir, damage);

        if (trace_ent == world || trace_ent.solid == SOLID_BSP)
        {
            color = SH_PaintballColour(self.wep_action_id);
            W_PaintballSplatEffect(trace_endpos, trace_plane_normal, self, trace_ent, color);
        }

        W_DebugImpact(trace_endpos, damage, hitgroup);
    }

    Lagcomp_EndRewind();
};

// Forward decl so the swept-trace inside W_PaintballProjectileTick
// can call back into the touch handler (defined just below) on a
// missed-by-engine intersection.
void() W_PaintballProjectileTouch;

void() W_PaintballProjectileTick =
{
    // Pass-through restoration runs in two phases:
    //   (a) First tick after touch — restore the pre-glance velocity.
    //       The engine's ClipVelocity unconditionally projected our
    //       velocity onto the bbox tangent at the end of the touch
    //       frame (it runs after SV_PushEntity for MOVETYPE_TOSS
    //       regardless of any state we change inside touch), so the
    //       saved field is the only record of the original trajectory.
    //       Without this we'd integrate the tangent-slide velocity
    //       for the whole 60ms NOCLIP window — that's the cartoony
    //       "bounce" off thin air that the user reported.
    //   (b) End of the 60ms window — restore MOVETYPE_TOSS + SOLID_BBOX
    //       so walls / other targets start blocking again (and gravity
    //       resumes; NOCLIP physics doesn't apply it).  setorigin
    //       re-links into the area lists with the new solid flag.
    if (self.proj_passthrough_until > 0)
    {
        if (self.proj_passthrough_savedvel != '0 0 0')
        {
            self.velocity = self.proj_passthrough_savedvel;
            self.proj_passthrough_savedvel = '0 0 0';
        }
        if (time < self.proj_passthrough_until)
        {
            // Still inside the window — skip drag + swept-trace and
            // keep ticking quickly so phase (b) lands on schedule.
            self.SendFlags |= 1;
            self.nextthink = time + Toss_NextThinkInterval();
            return;
        }
        self.movetype = MOVETYPE_TOSS;
        self.solid    = SOLID_BBOX;
        setorigin(self, self.origin);
        self.proj_passthrough_until = 0;
    }

    // Swept-trace tunneling guard — see W_SnowballProjectileTick for
    // rationale.  The paintball's 1800 qu/s muzzle speed is fast
    // enough that a moving player can slip a "no overlap at frame N,
    // no overlap at frame N+1" gap when the engine's per-frame
    // SV_PushEntity sweep tests against the player's pre-move pose.
    // Skipped while in a pass-through window — re-tracing would just
    // re-touch the same player we're trying to glide past.
    if (self.proj_passthrough_until == 0 && self.proj_prev_origin != self.origin)
    {
        tracebox(self.proj_prev_origin, self.mins, self.maxs,
                 self.origin, MOVE_NORMAL, self);
        if (trace_fraction < 1 && trace_ent && trace_ent != self.owner)
        {
            other = trace_ent;
            W_PaintballProjectileTouch();   // removes self (or sets pass-through)
            return;
        }
    }
    self.proj_prev_origin = self.origin;

    if (time >= self.proj_fuse_end)
    {
        remove(self);
        return;
    }
    // SendFlags pulse keeps the CSQC mirror in sync at sv_toss_tickrate
    // (matches W_SnowballProjectileTick's networking behaviour).
    self.SendFlags |= 1;

    float dt = Toss_NextThinkInterval();
    // Quadratic drag via shared helper (CSQC mirror calls the same
    // function with the same dt). Engine integrates gravity itself
    // for MOVETYPE_TOSS — drag is applied on top via this think.
    self.velocity = W_PaintballApplyDrag(self.velocity, dt);
    self.nextthink = time + dt;
};

void() W_PaintballProjectileTouch =
{
    if (other == self.owner)
        return;

    // Resolve the real surface normal via probe traceline — see
    // W_PaintballProbeNormal comment. trace_plane_normal in touch
    // context is unreliable for fast small projectiles.
    vector n = W_PaintballProbeNormal(self.origin, self.velocity, self);

    float damage = W_PaintballProjectileDamage(self.paintball_spawn_origin, self.origin);

    // Mesh-intersection gate for player targets — bbox touch alone
    // isn't enough since the player bbox is wider than the animated
    // mesh.  Probe MOVE_HITMODEL forward along velocity, fall back to
    // a swept trace from prev-tick origin.  When BOTH probes miss the
    // mesh the projectile just glanced the bbox and we let it keep
    // flying past instead of vanishing in mid-air (was a visible
    // "pop" of the projectile when it grazed a teammate).  Non-player
    // targets (phys props, world) skip this gate entirely.
    //
    // sv_hitbox_expand is applied to `other` for the duration of the
    // probes — without it MOVE_HITMODEL bbox-culls against the strict
    // movement hull and outstretched limbs (e.g. mid-swing arms) are
    // missed by exactly the margin the hitscan path is already
    // forgiving about (W_PlayersExpandHitboxes around hitscan traces).
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
            // Bbox-only graze.  Switch to MOVETYPE_NOCLIP + SOLID_NOT
            // for one short window: FTE's SV_Physics_Toss ClipVelocity
            // would otherwise pin our forward velocity to a slide
            // along the player bbox face (and zero it on top-down
            // impacts), producing a visible "bounce" off thin air.
            // NOCLIP routes through SV_Physics_Noclip which does
            // pure origin += vel*dt with no collision and no gravity;
            // velocity is preserved verbatim until the tick restores
            // MOVETYPE_TOSS at proj_passthrough_until.
            self.proj_passthrough_savedvel = self.velocity;
            self.proj_passthrough_until = time + 0.06;
            self.movetype = MOVETYPE_NOCLIP;
            self.solid    = SOLID_NOT;
            setorigin(self, self.origin);
            // Fire the restore tick on the very next frame — the engine
            // already clipped self.velocity onto the bbox tangent after
            // touch returns, so we want to swap in proj_passthrough_savedvel
            // before NOCLIP integrates very far with the deflected vector.
            self.nextthink = time + 0.001;
            return;
        }

        // Mesh confirmed — fall through to the damage path.  Defer
        // matches the hitscan / claim flow (sh_weapon_standard.qc:420):
        // when sv_trust_clienthits is on AND the shooter pushes
        // cl_predict_hits, the server waits for the client's
        // `cmd paintprojhit` claim (SV_HandleProjhitClaim) instead of
        // self-applying damage here.
        float defer_player = W_ShouldDeferToClaim(self.owner);
        if (!defer_player)
        {
            float final_damage = damage;
            if (cvar("sv_gamemode") == GAMEMODE_PAINTGUN)
                final_damage = 1000;
            W_ApplyDamage(self.owner, other, final_damage);
        }
    }
    else if (W_CanDamageTarget(other))
        W_ApplyDamage(self.owner, other, damage);
    else
        PhysProp_TryPushFromTrace(normalize(self.velocity), damage);

    if (other == world || other.solid == SOLID_BSP)
        W_PaintballSplatEffect(self.origin, n, self.owner, other, self.colormod);

    remove(self);
};

void(vector src, vector dir) W_PaintballSpawnProjectile =
{
    entity ball;

    ball = spawn();
    ball.owner       = self;
    ball.classname   = "proj_paintball";
    ball.movetype    = MOVETYPE_TOSS;
    ball.solid       = SOLID_BBOX;
    setmodel(ball, "models/weapons/wpn_snowball/w_snowball.mdl");
    ball.scale       = PAINTBALL_PROJ_SCALE;
    ball.colormod    = SH_PaintballColour(self.wep_action_id);
    setsize(ball,
        [-PAINTBALL_PROJ_SIZE, -PAINTBALL_PROJ_SIZE, -PAINTBALL_PROJ_SIZE],
        [ PAINTBALL_PROJ_SIZE,  PAINTBALL_PROJ_SIZE,  PAINTBALL_PROJ_SIZE]);
    setorigin(ball, src);
    ball.velocity    = self.velocity + dir * PAINTBALL_PROJ_SPEED;
    ball.avelocity   = '180 360 240';
    ball.gravity     = PAINTBALL_PROJ_GRAVITY;
    ball.touch       = W_PaintballProjectileTouch;
    ball.proj_type   = PROJ_TYPE_PAINTBALL;
    ball.proj_fuse_end = time + PAINTBALL_PROJ_FUSE;
    // Anti-spoof key for the projhit claim — matched in SV_HandleProjhitClaim
    // to confirm the claim references a real projectile owned by this player.
    ball.wep_action_id = self.wep_action_id;
    // Stored for damage falloff math at touch time (see
    // W_PaintballProjectileDamage).
    ball.paintball_spawn_origin = src;
    // Snapshot for the swept-trace tunneling guard in the tick.
    ball.proj_prev_origin = ball.origin;
    ball.SendEntity  = projectile_SendEntity;
    ball.SendFlags   = 1;
    ball.think       = W_PaintballProjectileTick;
    ball.nextthink   = time + Toss_NextThinkInterval();
};

void() W_PaintballFire =
{
    float r;

    r = SH_PaintballTryFire(time);
    if (r == 1)
    {
        self.weaponframe = PAINTBALL_SEQ_SHOOT;
        self.wep_nextframe = time + PAINTBALL_FRAME_INTERVAL;
        W_PaintballShoot();
        sound(self, CHAN_WEAPON, PAINTBALL_FIRE_SOUND, 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_PaintballReload =
{
    if (SH_PaintballTryReload(time))
    {
        self.weaponframe = PAINTBALL_SEQ_RELOAD_OPEN;
        self.wep_nextframe = time + PAINTBALL_FRAME_INTERVAL;
        self.paintball_snd_stage = 0;
    }
};

void() W_PaintballFrame =
{
    float result;
    float elapsed;
    float seq;

    elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;
    self.wep_nextframe += PAINTBALL_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= PAINTBALL_RELOAD_APPLY_TIME)
            seq = PAINTBALL_SEQ_RELOAD_CLOSE;
        else if (elapsed >= PAINTBALL_RELOAD_OPEN_TIME)
            seq = PAINTBALL_SEQ_RELOAD_LOOP;
        else
            seq = PAINTBALL_SEQ_RELOAD_OPEN;
        if (self.weaponframe != seq)
            self.weaponframe = seq;

        if (self.paintball_snd_stage < 1 && elapsed >= PAINTBALL_LIDOPEN_TIME)
        {
            sound(self, CHAN_AUTO, PAINTBALL_LIDOPEN_SOUND, 1, ATTN_NORM);
            self.paintball_snd_stage = 1;
        }
        if (self.paintball_snd_stage < 2 && elapsed >= PAINTBALL_RELOAD_SOUND_TIME)
        {
            sound(self, CHAN_AUTO, PAINTBALL_RELOAD_SOUND, 1, ATTN_NORM);
            self.paintball_snd_stage = 2;
        }
        if (self.paintball_snd_stage < 3 && elapsed >= PAINTBALL_LIDCLOSE_TIME)
        {
            sound(self, CHAN_AUTO, PAINTBALL_LIDCLOSE_SOUND, 1, ATTN_NORM);
            self.paintball_snd_stage = 3;
        }
    }

    result = SH_PaintballTickState(time);
    if (result & 1)
    {
        self.weaponframe = PAINTBALL_SEQ_IDLE;
        self.wep_nextframe = 0;
        self.paintball_snd_stage = 0;
    }
};

void() W_PaintballEquip =
{
    W_StandardEquipSetup(PAINTBALL_VIEWMODEL, PAINTBALL_DISPLAY_NAME,
        PAINTBALL_SEQ_DRAW, PAINTBALL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire = W_PaintballFire;
    self.reload = W_PaintballReload;
    self.wepframe = W_PaintballFrame;
    self.shoot = W_PaintballShoot;
    self.paintball_snd_stage = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(PAINTBALL_BASE_SPREAD, PAINTBALL_MOVE_SPREAD,
        PAINTBALL_FULL_SPREAD_SPEED, 1.3, TRUE);
};

void() W_PaintballDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_paintball = self.mag_paintball;
    tgt.ammo_paintball = self.ammo_paintball;
    self.mag_paintball = 0;
    self.ammo_paintball = 0;

    setmodel(tgt, PAINTBALL_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_paintball";
    tgt.solid = SOLID_NOT;
    tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_PAINTBALL;
    tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_PaintballEquip;
    tgt.weap_drop_func = W_PaintballDrop;
    tgt.pickupcopy = W_PaintballPickupCopy;
    tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid;
    tgt.nextthink = time + 0.7;
};

void() weapon_paintball =
{
    setmodel(self, PAINTBALL_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_paintball";
    self.solid = SOLID_TRIGGER;
    self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_PAINTBALL;
    self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_PaintballEquip;
    self.weap_drop_func = W_PaintballDrop;
    self.pickupcopy = W_PaintballPickupCopy;
    self.touch = weapon_touch;
    self.mag_paintball = MAX_MAG_PAINTBALL;
    self.ammo_paintball = MAX_AMMO_PAINTBALL;
    W_RegisterMapWeapon(weapon_paintball);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_paintball_snd_stage;
float csqc_paintball_snd_action;

void(vector hit_pos, vector hit_normal, entity hit_target, vector color, float half_size) CSQC_SpawnPaintSplat;
void(vector src, vector dir) CSQC_SpawnFakePaintball;

// Builds the muzzle aim direction shared by hitscan-predict and the
// projectile fake spawn so both modes use IDENTICAL spread + kicked
// view bias. Caller passes its own view-angles source (input_angles
// for client-predict, the player's v_angle for the server) and we
// return the final unit forward direction.
vector(vector view_ang, float action_id) CSQC_PaintballComputeFireDir =
{
    float spread, sx, sy, move_speed;
    vector flat_vel, dir;

    // Apply the integrated view-kick to the aim ONLY (don't write back).
    // Same pattern as W_PenetratingHitscanShoot at sh_weapon_standard.qc:497.
    vector kicked = view_ang;
    kicked_x += self.view_kick_pitch;
    kicked_y += self.view_kick_yaw;
    makevectors(kicked);
    vector fwd = v_forward;
    vector rt  = v_right;
    vector up  = v_up;

    flat_vel = self.velocity;
    flat_vel_z = 0;
    move_speed = vlen(flat_vel);

    spread = PAINTBALL_BASE_SPREAD + (move_speed / PAINTBALL_FULL_SPREAD_SPEED) * PAINTBALL_MOVE_SPREAD;
    spread = min(spread, PAINTBALL_BASE_SPREAD + PAINTBALL_MOVE_SPREAD);
    spread = spread * SH_GetSpreadScale() + sh_spread_flat;

    if (spread > 0)
    {
        sx = SH_SpreadJitter(action_id, 0) * spread;
        sy = SH_SpreadJitter(action_id, 1) * spread;
        dir = normalize(fwd + rt * sx + up * sy);
    }
    else
        dir = fwd;

    return dir;
};

void() CSQC_PredictedPaintballImpact =
{
    vector src, dir, end, color;
    float dist, damage, is_player_hit;

    src = self.origin + self.view_ofs;
    dir = CSQC_PaintballComputeFireDir(input_angles, self.wep_action_id);
    end = src + dir * 8192;

    // MOVE_HITMODEL refines the broad-phase bbox hit into per-mesh
    // bone hitboxes so trace_bone_id arrives populated for the
    // hitclaim — server's W_HitgroupClassify can then apply the
    // headshot / limb multipliers identically to the server-auth
    // path.  Paintgun gamemode still overrides damage to a flat
    // tag-kill on the server, but the bone info is correct either
    // way.
    CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
    CSQC_PhysProp_OverrideTrace(src, end);
    CSQC_DroppedWeapon_OverrideTrace(src, end);

    if (trace_fraction >= 1)
        return;

    is_player_hit =
        ((trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
         || (trace_ent.classname == "player_visual_proxy"));

    dist = vlen(trace_endpos - src);
    damage = W_LinearDamageFalloff(dist, PAINTBALL_CLOSE_DAMAGE,
        PAINTBALL_MIN_DAMAGE, PAINTBALL_DAMAGE_FALLOFF_RANGE);

    if (is_player_hit)
    {
        CSQC_TryPlayPredictedHitmarker();
        CSQC_SendHitclaim(trace_ent, damage, trace_bone_id);
    }
    else
    {
        CSQC_SendBreakClaim(trace_ent, damage);
        if (trace_ent == world || trace_ent.solid == SOLID_BSP)
        {
            color = SH_PaintballColour(self.wep_action_id);
            CSQC_SpawnPaintSplat(trace_endpos, trace_plane_normal, trace_ent,
                color, PAINTBALL_SPLAT_HALF_SIZE);
        }
    }

    if (cvar("cl_debug_impacts"))
        CSQC_AddDebugImpact(trace_endpos, src, '1 0.2 0.8', damage, 0);
};

// Local-only fake projectile that the shooter sees instantly while
// the server's mirror flies for everyone else. Identical physics so
// the two stay aligned visually.
void() CSQC_FakePaintballTouch =
{
    if (other == self.owner)
        return;

    // Resolve the real surface normal via probe traceline — see
    // W_PaintballProbeNormal comment. Same fix as the SSQC touch.
    vector n = W_PaintballProbeNormal(self.origin, self.velocity, self);

    // Player hit → emit projhit claim if trust mode is on. The server
    // will look up an active proj_paintball owned by us with matching
    // wep_action_id and apply damage; if it can't find one the claim
    // is rejected (anti-spoof).
    float is_player_hit =
        ((other != world && other.entnum >= 1 && other.entnum <= maxclients)
         || (other.classname == "player_visual_proxy"));

    if (is_player_hit)
    {
        // Mesh-intersection gate.  The bbox is much larger than the
        // animated mesh — a projectile that grazes the bbox without
        // ever touching the body would otherwise still score a hit
        // (the Z-height classifier always returns SOMETHING, so
        // previous logic always landed a body shot).  Resolve once
        // from the projectile's incoming trajectory, using two
        // MOVE_HITMODEL probes:
        //   1. velocity-based: trace forward along the projectile
        //      velocity through the touch point.  Most reliable when
        //      the engine still has a non-zero velocity at touch
        //      (fast projectiles, paintball).
        //   2. fallback: from prev_origin to current origin, the
        //      pre-touch step the engine clipped against.  Works
        //      when the engine zeroed velocity before the touch
        //      callback (slow / settled projectiles).
        // The claim only fires when one of the probes lands on
        // `other` AND populates a non-zero bone — i.e. the trace
        // actually penetrated the mesh, not just the bbox.
        //
        // sv_hitbox_expand is broadcast via serverinfo so the client
        // sees the same forgiveness margin the hitscan path uses.
        // Expand only `other` for the probe window so MOVE_HITMODEL
        // doesn't bbox-cull outstretched reach bones.
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
            // both FTE's SV_Physics_Toss ClipVelocity (which slides
            // us flat against the bbox) and any further collision
            // tests for the window's duration.  Velocity is saved
            // and restored verbatim by CSQC_FakePaintballThink.
            self.proj_passthrough_savedvel = self.velocity;
            self.proj_passthrough_until = time + 0.06;
            self.movetype = MOVETYPE_NOCLIP;
            self.solid    = SOLID_NOT;
            setorigin(self, self.origin);
            // Fast first-tick so CSQC_FakePaintballThink can swap in
            // the saved velocity before NOCLIP integrates much with
            // the engine-clipped tangent vector.
            self.nextthink = time + 0.001;
            return;
        }

        if (cvar("sv_trust_clienthits") >= 1)
        {
            float damage = W_PaintballProjectileDamage(self.paintball_spawn_origin, self.origin);
            entity saved_te = trace_ent;
            trace_ent = other;
            float hitgroup = W_BoneToHitgroup(bone_id);
            trace_ent = saved_te;

            // Wire format: cmd paintprojhit <slot> <damage> <action_id> <life_serial> <hitgroup>
            float slot = (other.classname == "player_visual_proxy")
                         ? other.vis_owner_entnum : other.entnum;
            float life_serial = (other.classname == "player_visual_proxy")
                                ? other.vis_life_serial : 0;
            localcmd(sprintf("cmd paintprojhit %g %g %g %g %g\n",
                             slot, damage, self.wep_action_id,
                             life_serial, hitgroup));
            CSQC_TryPlayPredictedHitmarker();
        }
    }
    else if (other == world || other.solid == SOLID_BSP)
    {
        CSQC_SpawnPaintSplat(self.origin, n, other, self.colormod, PAINTBALL_SPLAT_HALF_SIZE);
    }

    remove(self);
};

void() CSQC_FakePaintballThink =
{
    if (time >= self.paintball_fake_fuse_end)
    {
        remove(self);
        return;
    }

    // Two-phase pass-through restoration — see
    // W_PaintballProjectileTick on the SSQC side for the full rationale.
    //   (a) First tick after touch: restore the pre-glance velocity
    //       (engine ClipVelocity already deflected it onto the bbox
    //       tangent before this think fires).
    //   (b) End of window: restore MOVETYPE_TOSS + SOLID_BBOX so walls
    //       splat us and gravity resumes.
    if (self.proj_passthrough_until > 0)
    {
        if (self.proj_passthrough_savedvel != '0 0 0')
        {
            self.velocity = self.proj_passthrough_savedvel;
            self.proj_passthrough_savedvel = '0 0 0';
        }
        if (time < self.proj_passthrough_until)
        {
            // Still in window — fire again soon, skip drag + origin
            // snapshot so the swept-trace fallback doesn't re-probe
            // from a pass-through-displaced origin once we exit.
            float r0 = serverkeyfloat("sv_toss_tickrate", 40);
            self.nextthink = time + 1.0 / bound(5, r0, 100);
            return;
        }
        self.movetype = MOVETYPE_TOSS;
        self.solid    = SOLID_BBOX;
        setorigin(self, self.origin);
        self.proj_passthrough_until = 0;
    }

    // Snapshot the origin BEFORE the engine moves us this tick — the
    // touch handler's mesh-hit gate uses (proj_prev_origin, origin)
    // as a fallback probe when the velocity-direction trace whiffs.
    // Without this update, the fallback would trace from world origin
    // (uninitialised default) and produce nonsense hits.
    self.proj_prev_origin = self.origin;

    // Mirror the SSQC W_PaintballProjectileTick drag formula via the
    // shared W_PaintballApplyDrag helper. Same dt source: server
    // publishes sv_toss_tickrate via serverinfo, so this matches the
    // server's Toss_NextThinkInterval() exactly. With identical dt +
    // identical formula, client and server arcs stay locked.
    float r = serverkeyfloat("sv_toss_tickrate", 40);
    float dt = 1.0 / bound(5, r, 100);
    self.velocity = W_PaintballApplyDrag(self.velocity, dt);
    self.nextthink = time + dt;
};

void(vector src, vector dir) CSQC_SpawnFakePaintball =
{
    entity ball = spawn();
    ball.classname = "csqc_fake_paintball";
    ball.owner     = self;
    ball.movetype  = MOVETYPE_TOSS;
    ball.solid     = SOLID_BBOX;
    setmodel(ball, "models/weapons/wpn_snowball/w_snowball.mdl");
    ball.scale     = PAINTBALL_PROJ_SCALE;
    ball.colormod  = SH_PaintballColour(self.wep_action_id);
    setsize(ball,
        [-PAINTBALL_PROJ_SIZE, -PAINTBALL_PROJ_SIZE, -PAINTBALL_PROJ_SIZE],
        [ PAINTBALL_PROJ_SIZE,  PAINTBALL_PROJ_SIZE,  PAINTBALL_PROJ_SIZE]);
    setorigin(ball, src);
    ball.velocity  = self.velocity + dir * PAINTBALL_PROJ_SPEED;
    ball.avelocity = '180 360 240';
    ball.gravity   = PAINTBALL_PROJ_GRAVITY;
    ball.drawmask  = MASK_ENGINE;
    // Stash for the touch-side falloff math + projhit anti-spoof key.
    ball.wep_action_id           = self.wep_action_id;
    ball.paintball_spawn_origin  = src;
    ball.paintball_fake_fuse_end = time + PAINTBALL_PROJ_FUSE;
    ball.proj_prev_origin        = src;   // seed the swept-trace fallback
    ball.touch                   = CSQC_FakePaintballTouch;
    ball.think                   = CSQC_FakePaintballThink;

    float r = serverkeyfloat("sv_toss_tickrate", 40);
    float dt = 1.0 / bound(5, r, 100);
    ball.nextthink = time + dt;
};

void() CSQC_PredictPaintballCommand =
{
    float r;
    float elapsed;
    vector src;
    vector dir;

    if (predicted_player.wep_action_id != csqc_paintball_snd_action)
    {
        csqc_paintball_snd_action = predicted_player.wep_action_id;
        csqc_paintball_snd_stage = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_PaintballTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            // Apply view kick on every prediction tick that actually fires
            // a shot (TryFire returns 1 only on the LIVE tick — replays
            // get 0 because state already advanced — so this matches the
            // server's W_PaintballShoot single-shot kick exactly).
            SH_ApplyViewKick(PAINTBALL_KICK_PITCH, PAINTBALL_KICK_VARIANCE,
                             PAINTBALL_KICK_STRENGTH);
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, PAINTBALL_FIRE_SOUND, 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();

                // Paintball gets ONLY smoke at the barrel, no flash —
                // CO2-driven, not powder. Reuses the projectile-spawn
                // muzzle offset constants so smoke + projectile leave
                // from the same point.
                CSQC_MuzzleSmokeAtMuzzle(
                    PAINTBALL_PROJ_MUZZLE_FORWARD,
                    PAINTBALL_PROJ_MUZZLE_RIGHT,
                    PAINTBALL_PROJ_MUZZLE_DOWN,
                    self.wep_action_id, 1);

                // Branch on projectile vs hitscan mode. The fake projectile
                // is guarded by paintball_fake_spawned_serial so any future
                // path that calls this twice for one shot only spawns once.
                if (cvar("sv_paintball_projectile"))
                {
                    if (self.paintball_fake_spawned_serial != self.wep_action_id)
                    {
                        self.paintball_fake_spawned_serial = self.wep_action_id;
                        src = self.origin + self.view_ofs;
                        dir = CSQC_PaintballComputeFireDir(input_angles, self.wep_action_id);
                        // Visual muzzle offset — v_forward / v_right
                        // were just set by ComputeFireDir's makevectors.
                        // Flip RIGHT when cl_lefthand is on so the
                        // spawn aligns with the mirrored viewmodel
                        // (server always offsets to the right; the
                        // small left/right divergence on lefthand
                        // shooters is invisible to remote viewers).
                        float side = cvar("cl_lefthand") ? -1 : 1;
                        src = src + v_forward * PAINTBALL_PROJ_MUZZLE_FORWARD
                                  + v_right   * (PAINTBALL_PROJ_MUZZLE_RIGHT * side)
                                  - '0 0 1'   * PAINTBALL_PROJ_MUZZLE_DOWN;
                        CSQC_SpawnFakePaintball(src, dir);
                    }
                }
                else
                {
                    CSQC_PredictedPaintballImpact();
                }
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

    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_paintball_snd_stage < 1 && elapsed >= PAINTBALL_LIDOPEN_TIME)
        {
            localsound(PAINTBALL_LIDOPEN_SOUND);
            CSQC_RecordPredictedAutoSound();
            csqc_paintball_snd_stage = 1;
        }
        if (csqc_paintball_snd_stage < 2 && elapsed >= PAINTBALL_RELOAD_SOUND_TIME)
        {
            localsound(PAINTBALL_RELOAD_SOUND);
            CSQC_RecordPredictedAutoSound();
            csqc_paintball_snd_stage = 2;
        }
        if (csqc_paintball_snd_stage < 3 && elapsed >= PAINTBALL_LIDCLOSE_TIME)
        {
            localsound(PAINTBALL_LIDCLOSE_SOUND);
            CSQC_RecordPredictedAutoSound();
            csqc_paintball_snd_stage = 3;
        }
    }

    SH_PaintballTickState(csqc_pred_time);
};

void() CSQC_PredictPaintballReload =
{
    if (SH_PaintballTryReload(csqc_pred_time))
    {
        csqc_paintball_snd_stage = 0;
        csqc_paintball_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_PaintballDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return PAINTBALL_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return PAINTBALL_SEQ_SHOOT;
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        if (elapsed >= PAINTBALL_RELOAD_APPLY_TIME)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = max(0, elapsed - PAINTBALL_RELOAD_APPLY_TIME);
            return PAINTBALL_SEQ_RELOAD_CLOSE;
        }
        if (elapsed >= PAINTBALL_RELOAD_OPEN_TIME)
        {
            csqc_viewmodel_sequence_time_override = TRUE;
            csqc_viewmodel_sequence_time = max(0, elapsed - PAINTBALL_RELOAD_OPEN_TIME);
            return PAINTBALL_SEQ_RELOAD_LOOP;
        }
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = elapsed;
        return PAINTBALL_SEQ_RELOAD_OPEN;
    }
    return PAINTBALL_SEQ_IDLE;
};

void() CSQC_PaintballDropClear =
{
    self.mag_paintball = 0;
    self.ammo_paintball = 0;
};

void() CSQC_PaintballEquip =
{
    self.weapon_name = PAINTBALL_DISPLAY_NAME;
    self.weapon_viewmodel = PAINTBALL_VIEWMODEL;
    self.weapon_worldmodel = PAINTBALL_WORLDMODEL;
    self.weapon_deploy_sound = "";
    self.csqc_predict_cmd = CSQC_PredictPaintballCommand;
    self.csqc_predict_reload = CSQC_PredictPaintballReload;
    self.csqc_display_frame = CSQC_PaintballDisplayFrame;
    self.csqc_drop_clear = CSQC_PaintballDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
