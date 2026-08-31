// ============================================================
//  shared/weapons/sh_wpn_hlgauss.qc  -  HL Gauss Gun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : ammo_gauss (no magazine, direct ammo pool)
//  Fire  : primary = instant hitscan beam (2 ammo), alt = hold to charge
//  Alt   : Hold alt-fire to charge, release to fire charged beam
//         Charge drains 1 ammo every 0.3s, auto-fires if ammo depletes
//         Charged shot pushes player backward
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float ammo_gauss;
.float gauss_charge_state;        // 0=none, 1=winding up, 2=looping
.float gauss_charge_started;      // time when charge began
.float gauss_charge_next_ammo;    // next time to drain 1 ammo during charge

// --- Sequence indices, read out of valve/models/v_gauss.mdl (9 seqs) -------
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/
// wpn_hlgauss/v_gauss.mdl, a flat 73-frame bake) by frame number.  It now
// drives Half-Life's own IDST model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index —
// gl_hlmdl.c:780 sets mod->numframes = numseq — so every one of the old
// constants was meaningless against it: GAUSS_IDLE_FRAME was 73 and this model
// has nine sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// The old bake was a straight 1:1 dump of these same sequences at 20 fps —
// draw 1..12 = 0.55 s vs draw's 0.583 s, fire 13..40 = 1.35 s vs fire2's
// 1.333 s, 41..61 = 1.00 s vs spinup's 1.000 s, 62..72 = 0.50 s vs spin's
// 0.500 s — the two charge sequences land dead on, which is why the durations
// below barely move, and which is also the evidence that the bake's "fire"
// was fire2 and not fire.
//
// Every duration quoted here is the ENGINE's: frameduration() returns
// (numframes-1)/fps (gl_hlmdl.c:1542), because an N-frame sequence spans N-1
// intervals — the same convention the SDK hardcodes, e.g. python.cpp:254 uses
// (70.0/30.0) for a 71-frame 30 fps idle.  Quoting anything else here would
// put these constants a frame period ahead of whatever SH_SeqDuration() hands
// the rest of the tree for the same sequence.
//
// Indices are the SDK's enum gauss_e, gauss.cpp:32-42.
const float GAUSS_SEQ_IDLE            = 0;   // idle,     4.000 s, looping
const float GAUSS_SEQ_IDLE2           = 1;   // idle2,    4.000 s, looping
const float GAUSS_SEQ_FIDGET          = 2;   // fidget,   3.000 s
const float GAUSS_SEQ_SPINUP          = 3;   // spinup,   1.000 s, looping
const float GAUSS_SEQ_SPIN            = 4;   // spin,     0.500 s, looping
const float GAUSS_SEQ_FIRE            = 5;   // fire,     1.000 s  (dead in HL, see below)
const float GAUSS_SEQ_FIRE2           = 6;   // fire2,    1.333 s
const float GAUSS_SEQ_HOLSTER         = 7;   // holster,  0.667 s
const float GAUSS_SEQ_DRAW            = 8;   // draw,     0.583 s

// Which sequence plays when, taken from the SDK rather than from the names:
//   draw    — gauss.cpp:130, DefaultDeploy("models/v_gauss.mdl",
//             "models/p_gauss.mdl", GAUSS_DRAW, "gauss").  That second
//             argument is the third-person held model and it lives in the
//             manifest, not here: sh_weapon_manifest.qc:243 carries
//             "models/p_gauss.mdl" as the WMF_WEP_GAUSS pmodel.
//   spinup  — gauss.cpp:213, first alt-fire frame (m_fInAttack 0 -> 1)
//   spin    — gauss.cpp:227, once the spin-up timer expires (m_fInAttack 1 -> 2)
//   fire2   — ev_hldm.cpp:912, EV_FireGauss, for BOTH the primary shot and the
//             released charge shot.  GAUSS_FIRE (5) is dead code in shipped
//             HL: gauss.cpp never SendWeaponAnim()s it and the event handler
//             hardcodes GAUSS_FIRE2 with no primary/secondary branch.  The
//             constant is kept above only so the enum reads 1:1 against
//             gauss.cpp:32-42.
//   holster — gauss.cpp:139 (no holster path exists in this mod's QC yet)
//   idle    — gauss.cpp:184 (underwater cancel) and :298 (overcharge zap)
const float GAUSS_FRAME_INTERVAL      = 0.05;   // wepframe tick rate, not an anim rate

const float MAX_AMMO_GAUSS            = 120;

// --- Balance ---
const float GAUSS_PRIMARY_DAMAGE      = 20;
const float GAUSS_PRIMARY_AMMO_COST   = 2;
const float GAUSS_PRIMARY_DELAY       = 0.2;
const float GAUSS_CHARGE_START_DELAY  = 0.1;
const float GAUSS_CHARGED_DELAY       = 0.5;
const float GAUSS_MAX_CHARGE_TIME     = 4.0;
const float GAUSS_CHARGE_AMMO_INTERVAL = 0.3;
const float GAUSS_MIN_CHARGE_DAMAGE   = 40;
const float GAUSS_MAX_CHARGE_DAMAGE   = 200;
const float GAUSS_DRYFIRE_DELAY       = 0.2;
const float GAUSS_OVERCHARGE_TIME     = 10.0;   // hold charge this long = self-damage
const float GAUSS_OVERCHARGE_DAMAGE   = 50;     // damage dealt to self on overcharge
const float GAUSS_CHARGE_BLAST_RADIUS = 120;    // charged shot explosion radius
const float GAUSS_CHARGE_BLAST_PUSH   = 600;    // knockback force
const float GAUSS_CHARGE_BLAST_UPLIFT = 250;    // vertical knockback bonus

// --- State durations, taken from the sequences themselves ---
const float GAUSS_DRAW_DURATION       = 0.583;   // draw,  35/60
const float GAUSS_FIRE_DURATION       = 1.333;   // fire2, 40/30 — primary and charged alike

// Spin-up -> spin hand-off.  HL gates this on the weapon-idle timer instead
// (gauss.cpp:215 arms it at +0.5 s, :225-229 swaps to GAUSS_SPIN when it
// expires), which cuts the looping spinup off exactly half way through.  We
// let spinup play its own 1.000 s, which is precisely what the old 41..61 bake
// did, so the charge sound stays lined up with the visible wind-up.  Both
// halves of the charge are gauss_charge_state > 0, so this only ever moves
// pixels — SH_GaussCalcChargeDamage keys off gauss_charge_started, not this.
// It also makes the hand-off seamless: 1.000 s is two whole 0.500 s spin
// loops, so the frame1time the engine wraps at the swap lands on spin's frame
// 0 instead of part way in.
const float GAUSS_SPINUP_DURATION     = 1.000;   // spinup, 30/30

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling and FTE's VFS is case-sensitive against real files on Linux.
// ev_hldm.cpp:902 — m_iBeam = EV_FindModelIndex("sprites/smoke.spr").  Yes, the
// gauss beam really is the smoke sprite; the additive blend and the colour are
// what make it read as energy.  Precached in sh_customdefs.qc.
const string GAUSS_BEAM_SPRITE  = "sprites/smoke.spr";

// ev_hldm.cpp:903 — m_iGlow = m_iBalls = EV_FindModelIndex("sprites/hotglow.spr").
// R_TempSprite() paints it at every reflection and punch-through point with
// kRenderGlow; here it rides the beam's own EndSprite slot, which cl_env_beam.qc
// already draws as an additive billboard tinted with the beam colour.  That gets
// the glow onto BOTH the networked beam and the shooter's local one for free,
// instead of needing a second entity type on each side.
const string GAUSS_GLOW_SPRITE  = "sprites/hotglow.spr";

// ev_hldm.cpp:898 — nMaxHits = 10.  The beam is a walk, not a single trace:
// shallow hits reflect and lose energy, steep ones punch through thin geometry.
const float GAUSS_MAX_HITS      = 10;

// ev_hldm.cpp:920 — `while (flDamage > 10 ...)`.  flDamage is the beam's
// remaining ENERGY as well as the damage it deals, so a beam that has bounced
// enough times simply stops.
const float GAUSS_MIN_ENERGY    = 10;

const string GAUSS_VIEWMODEL    = "models/v_gauss.mdl";
const string GAUSS_WORLDMODEL   = "models/w_gauss.mdl";
const string GAUSS_DEPLOY_SOUND = "";
const string GAUSS_DISPLAY_NAME = "GAUSS";

// ============================================================
//  SHARED — the beam walk
// ============================================================
//
// ONE implementation of EV_FireGauss / CGauss::Fire, compiled into both VMs.
//
// It has to be shared.  The beam reflects off shallow surfaces and punches
// through thin ones, so where it ends up is the product of up to ten traces —
// and the server draws the beam for everyone EXCEPT the shooter while the
// shooter draws its own (HLBeam_SendEntity / CSQC_EnvBeam_Local, the
// FL_SKIPLOCALHOST split HL uses).  Two separate implementations of a
// ten-bounce walk would diverge, and the shooter would watch a beam go
// somewhere the damage did not.
//
// The per-VM differences are only in the three verbs — trace, draw, hurt — and
// they are #ifdef'd inline rather than split into two functions so the geometry
// can never drift apart.
//
// Muzzle offset: HL passes `idx | 0x1000` to R_BeamEntPoint, which anchors the
// first segment to the gun's attachment 1 so it tracks the muzzle for the
// beam's whole 0.1 s life.  A beam entity here has a fixed start point, so this
// is the static stand-in for that attachment.
vector(vector src) SH_GaussMuzzle =
{
    return src + v_right * 8 + v_up * -12;
};

// `damage` is the beam's energy budget, spent as it reflects (ev_hldm.cpp:1027,
// `flDamage = flDamage * (1 - n)`) and as it burns through walls (:1071,
// `flDamage -= n`).
// Where the walk finally stopped.  The charged-shot caller used to read
// trace_endpos / trace_plane_normal straight after the call, on the stated
// assumption that the walk "leaves the trace globals on its last trace".  It
// does not: the walk goes on to call W_ApplyDamage, W_ImpactEffect,
// W_DebugImpact and W_RadiusExplode, any of which can trace again — so the
// terminal explosion landed wherever the last incidental trace happened to hit,
// which is the gauss reading as "inaccurate" on the server side.  Exported
// explicitly instead.
vector gauss_walk_end_pos;
vector gauss_walk_end_norm;

#ifdef SSQC
// A particle leaves NOTHING in a log, so "the balls played and looked wrong" and
// "the balls never fired" are the same observation without this - the trap
// shared/sh_alienfx.qc's header documents having already shipped once.  Three of
// the four emissions below were missing for exactly that reason: nothing could
// tell you they were absent.  Gated SSQC-side because sv_debug_weapons is
// declared CVAR_SIDE_SV and a CSQC read of it is an audit finding.
void(string site, vector p, float count) SH_GaussDebugBalls =
{
    if (!cvar("sv_debug_weapons"))
        return;
    dprint(sprintf("[gauss] balls %s at %v x%g\n", site, p, count));
};
#endif

void(vector src, vector dir, float damage, float is_primary) SH_GaussBeamWalk =
{
    // ev_hldm.cpp:948-961 / :966-979 — the numbers are the SDK's, all six of
    // them.  Widths are tenths (CBeam units), so 1.0 and 2.5 become 10 and 25.
    vector gcol    = is_primary ? '255 128 0' : '255 255 255';
    float  gwidth  = is_primary ? 10 : 25;
    float  gbright = is_primary ? 128 : bound(128, damage, 255);
    float  sprite  = getmodelindex(GAUSS_BEAM_SPRITE);
    float  glow    = getmodelindex(GAUSS_GLOW_SPRITE);

    float  hits_left = GAUSS_MAX_HITS;
    float  punched   = FALSE;
    // The first segment starts at the muzzle; every later one starts where the
    // previous bounced.  (ev_hldm.cpp uses R_BeamEntPoint for the first and
    // R_BeamPoints for the rest, which is the same distinction.)
    vector seg_from  = SH_GaussMuzzle(src);

    while (damage > GAUSS_MIN_ENERGY && hits_left > 0)
    {
        hits_left = hits_left - 1;

        vector dest = src + dir * 8192;
#ifdef SSQC
        W_WeaponTraceLine(src, dest);
#else
        CSQC_WeaponTraceLine(src, dest, MOVE_NORMAL, self);
#endif
        if (trace_allsolid)
            break;

        // Latch everything off the globals before anything else traces.
        vector hit_pos  = trace_endpos;
        vector hit_norm = trace_plane_normal;
        // Publish before anything below can retrace.  Overwritten each segment,
        // so after the loop these hold the LAST one — which is what the charged
        // shot's terminal blast wants.
        gauss_walk_end_pos  = hit_pos;
        gauss_walk_end_norm = hit_norm;
        entity hit_ent  = trace_ent;
        float  hit_frac = trace_fraction;

        // Draw this segment, with the impact glow on its far end.
#ifdef SSQC
        HLBeam_EntFlash(self, seg_from, hit_pos, sprite,
                        gcol, gbright, gwidth, 0, 0, 0.1, glow);
#else
        CSQC_EnvBeam_Local(world, seg_from, hit_pos, sprite,
                           gcol, gbright, gwidth, 0, 0, 0.1, glow);
#endif
        seg_from = hit_pos;

        if (hit_frac >= 1.0)
            break;              // flew the full 8192 without touching anything

#ifdef SSQC
        if (W_CanDamageTarget(hit_ent))
            W_ApplyDamage(self, hit_ent, damage);
        else
            W_ImpactEffect(hit_pos);
        W_DebugImpact(hit_pos, damage, W_BoneToHitgroup(trace_bone_id));
#else
        CSQC_BulletImpact(hit_pos, hit_norm, damage, 0);
#endif

        // Only level geometry reflects or is punched through.  A monster, a
        // player or a prop absorbs the beam (ev_hldm.cpp:986, `solid ==
        // SOLID_BSP`).
        float is_bsp = (hit_ent == world || hit_ent.solid == SOLID_BSP);
        if (!is_bsp)
            break;

        // n = how square-on the hit is.  ev_hldm.cpp:993.
        float n = -(hit_norm * dir);

        if (n < 0.5)
        {
            // Shallow: reflect and lose energy (ev_hldm.cpp:1000-1027).
            dir = normalize(dir + hit_norm * (2 * n));
            src = hit_pos + dir * 8;
#ifdef SSQC
            // The RICOCHET BALLS — ev_hldm.cpp:1016 fires three hotglow sprites
            // off the bounce point along the surface normal.
            //
            // This used to be the ONLY ball emission in the file, on the stated
            // grounds that "a square-on punch-through gets the glow and no balls,
            // which is the tell that tells the two hit types apart".  That was
            // wrong.  ev_hldm.cpp calls R_Sprite_Trail — the bouncing tempent —
            // in FOUR places, and this is just the first; the other three are
            // emitted below.  R_TempSprite, which sits beside each of them, IS a
            // static glow flare that never moves, and that is the one the beam's
            // EndSprite already covers.
            //
            // Server-side only, with no CSQC counterpart, because this multicast
            // already reaches everyone INCLUDING the shooter — the gauss is
            // server-autonomous (W_FireIsServerAutonomous), so the walk really
            // runs here.  Emitting in the #else branch as well would double them
            // for the person firing.
            AlienFX_Multicast(ALIENFX_GAUSS_BALLS, hit_pos, hit_norm);
            SH_GaussDebugBalls("reflect", hit_pos, 3);
            // gauss.cpp:469 — a reflection is a real blast at the bounce point,
            // scaled by how much energy it shed.  This is the gauss's signature
            // trick: skipping a charged shot off a wall to hit round a corner.
            if (n > 0)
                W_RadiusExplode(hit_pos, GAUSS_CHARGE_BLAST_RADIUS * n,
                                damage * n * 0.5, damage * n * 0.1,
                                GAUSS_CHARGE_BLAST_PUSH * n,
                                GAUSS_CHARGE_BLAST_UPLIFT * n, self);
#endif
            if (n == 0)
                n = 0.1;
            damage = damage * (1 - n);
            continue;
        }

        // Square-on: tunnel.  One hole per shot (ev_hldm.cpp:1035-1041).
        if (punched)
            break;
        punched = TRUE;

        // The primary shot is explicitly incapable of breaking through
        // (ev_hldm.cpp:1043).
        if (is_primary)
        {
#ifdef SSQC
            // ev_hldm.cpp:1121, and THE ONE THE PLAYER ACTUALLY SEES.  Every
            // ordinary primary-fire wall hit lands here, and GoldSrc throws the
            // biggest of its four ball sprays off it: EIGHT balls at speed 200,
            // twice the reflect's, straight out along the surface normal.  The
            // SDK's own comment at :1114 is "slug doesn't punch through ever with
            // primary fire, so leave a little glowy bit and make some balls".
            //
            // This branch used to break out of the walk emitting nothing, which
            // is why the gauss looked inert against a wall while a lucky glancing
            // shot sparked.
            //
            // The magnitude MULTIPLIES the recipe's own count, which is GoldSrc's
            // per-call unit of 3 — so 3 here is 9 balls against the SDK's 8.  The
            // alternative was a third r_part block identical to gauss_balls but
            // for `count 1`, to buy back one ball out of nine.  Not worth it, and
            // the discrepancy is recorded rather than left to be rediscovered.
            AlienFX_MulticastMag(ALIENFX_GAUSS_PRIMARY, hit_pos, hit_norm, 3);
            SH_GaussDebugBalls("primary-wall", hit_pos, 9);
#endif
            break;
        }

        // Trace on past the wall, then trace BACK to find where the beam would
        // exit.  The thickness it has to burn through is subtracted from the
        // beam's energy; too thick and the beam simply stops.
        vector punch_start = hit_pos + dir * 8;
#ifdef SSQC
        W_WeaponTraceLine(punch_start, dest);
#else
        CSQC_WeaponTraceLine(punch_start, dest, MOVE_NORMAL, self);
#endif
        if (trace_allsolid)
        {
            damage = 0;
            break;
        }
        vector far_side = trace_endpos;
#ifdef SSQC
        W_WeaponTraceLine(far_side, hit_pos);
#else
        CSQC_WeaponTraceLine(far_side, hit_pos, MOVE_NORMAL, self);
#endif
        vector exit_pos = trace_endpos;
        float  thickness = vlen(exit_pos - hit_pos);

        if (thickness >= damage)
        {
            damage = 0;
            break;
        }
        if (thickness == 0)
            thickness = 1;
        damage = damage - thickness;

#ifdef SSQC
        // ev_hldm.cpp:1081 — the ENTRY hole's balls, thrown back out of the wall
        // towards the shooter (`fwd = tr.endpos - forward`, i.e. against the beam)
        // rather than along a surface normal.  Three of them, same speed as the
        // reflect.  GoldSrc calls these the absorption balls: the energy the wall
        // just took out of the beam, coming back at you.
        AlienFX_Multicast(ALIENFX_GAUSS_PUNCH_IN, hit_pos, -1 * dir);
        SH_GaussDebugBalls("punch-entry", hit_pos, 3);

        // gauss.cpp:519 — the exit wound is a blast on the far side of the
        // wall, which is how a charged gauss kills through cover.
        W_RadiusExplode(exit_pos + dir * 8, damage * 2.5,
                        damage * 0.5, damage * 0.1,
                        GAUSS_CHARGE_BLAST_PUSH, GAUSS_CHARGE_BLAST_UPLIFT, self);

        // ev_hldm.cpp:1096 — and the EXIT bloom, the one emission whose count is
        // not a constant: (int)(flDamage * 0.3), so a full 200-damage charge
        // throws 60 balls.  Divided by the recipe's per-call unit of 3, that is
        // damage * 0.1 on the magnitude byte.  Slow (speed 40) and wide (scatter
        // 200) — hence gauss_balls_wide rather than the block the other three use.
        AlienFX_MulticastMag(ALIENFX_GAUSS_PUNCH_OUT, exit_pos, -1 * dir,
                             damage * 0.1);
        SH_GaussDebugBalls("punch-exit", exit_pos, damage * 0.3);
#endif
        // Resume from the exit point.
        seg_from = exit_pos;
        src      = exit_pos + dir;
    }
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_GaussTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= GAUSS_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= GAUSS_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    // WS_SPECIAL (charging) doesn't auto-transition — it's ended by release or ammo depletion
    return 0;
};

float(float now) SH_GaussTryPrimaryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    // `now`-based — see sh_weapon_standard.qc SH_StandardTryFire.
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_gauss < GAUSS_PRIMARY_AMMO_COST)
    {
        self.attack_finished = now + GAUSS_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + GAUSS_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.ammo_gauss      -= GAUSS_PRIMARY_AMMO_COST;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + GAUSS_PRIMARY_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + GAUSS_PRIMARY_DELAY;
#endif
    return 1;
};

float(float now) SH_GaussTryAltFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_gauss <= 0)
    { self.attack_finished = now + GAUSS_DRYFIRE_DELAY; return -1; }

    self.ammo_gauss          -= 1;
    self.weaponstate          = WS_SPECIAL;
    self.wep_action_id       += 1;
    self.wep_anim_start       = now;
    self.attack_finished      = now + GAUSS_CHARGE_START_DELAY;
    self.gauss_charge_state   = 1;
    self.gauss_charge_started = now;
    self.gauss_charge_next_ammo = now + GAUSS_CHARGE_AMMO_INTERVAL;
    return 1;
};

// Returns damage based on charge time. Clears charge state.
float(float now) SH_GaussCalcChargeDamage =
{
    float charge_elapsed, charge_ratio, damage;

    if (self.gauss_charge_state <= 0)
        return 0;

    charge_elapsed = now - self.gauss_charge_started;
    if (charge_elapsed < 0) charge_elapsed = 0;

    charge_ratio = bound(0, charge_elapsed / GAUSS_MAX_CHARGE_TIME, 1);
    damage = GAUSS_MIN_CHARGE_DAMAGE + (GAUSS_MAX_CHARGE_DAMAGE - GAUSS_MIN_CHARGE_DAMAGE) * charge_ratio;

    self.gauss_charge_state = 0;
    self.gauss_charge_started = 0;
    self.gauss_charge_next_ammo = 0;
    self.weaponstate = WS_FIRE;
    self.wep_action_id += 1;
    self.wep_anim_start = now;
    self.attack_finished = now + GAUSS_CHARGED_DELAY;

    // Pushback — applied in shared code so both server and client handle it
    #ifdef SSQC
    makevectors(self.v_angle);
    #else
    makevectors(input_angles);
    #endif
    self.velocity = self.velocity - v_forward * bound(100, damage * 3, 600);

    return damage;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_GaussPickupCopy =
{ player.ammo_gauss = self.ammo_gauss; };

void(float damage, float is_primary) W_GaussBeamFire =
{
    makevectors(self.v_angle);
    vector src = self.origin + self.view_ofs;
    vector dir = v_forward;

    // The whole shot -- beam segments, reflections, punch-through, per-hit
    // damage and the reflection/exit blasts -- lives in SH_GaussBeamWalk, which
    // is compiled into both VMs so the shooter's own beam bounces exactly where
    // this one does.  See the comment on that function for why it must be
    // shared.
    //
    // The charged shot's terminal explosion stays here: it is fired once for the
    // whole shot rather than once per bounce, and it is the server's business
    // only.  Everything in the walk that is server-only is behind #ifdef SSQC
    // there, including the reflection blasts gauss.cpp:469 does.
    SH_GaussBeamWalk(src, dir, damage, is_primary);

    if (!is_primary)
    {
        // Where the beam finally stopped, taken from the walk's own exported
        // endpoint rather than the trace globals — see the note on
        // gauss_walk_end_pos for why reading the globals here was wrong.
        vector blast_at = gauss_walk_end_pos;
        vector blast_n  = gauss_walk_end_norm;

        // Lifted off the surface along its normal.  Every other explosive in the
        // mod does this (the hand grenade uses origin + '0 0 8', the RPG and the
        // SMG grenade the same) and cl_bulletimpact.qc explains why for impact
        // effects: an effect placed exactly ON the plane is half-buried in it,
        // and a dlight coplanar with a wall barely lights the wall at all.
        //
        // Impact_ParticleOffset() is not used here -- it is a CSQC-side cvar
        // read, and this is the server path -- but the 8 units matches what the
        // other explosives use.
        te_explosion(blast_at + blast_n * 8);

        // Radius damage + player knockback + phys-drop blast -- single call.
        // Gauss charged-blast scales with the beam's damage (50% at centre,
        // 10% at edge), so peak/min are derived params.
        W_RadiusExplode(blast_at, GAUSS_CHARGE_BLAST_RADIUS,
                        damage * 0.5, damage * 0.1,
                        GAUSS_CHARGE_BLAST_PUSH, GAUSS_CHARGE_BLAST_UPLIFT,
                        self);
    }
};

void() W_GaussPrimaryFire =
{
    float r = SH_GaussTryPrimaryFire(time);
    if (r == 1)
    {
        // fire2, not fire — EV_FireGauss plays GAUSS_FIRE2 for the primary shot
        // too (ev_hldm.cpp:912); the primary/secondary split is in the damage
        // and the beam width, never in the viewmodel animation.
        self.weaponframe = GAUSS_SEQ_FIRE2;
        self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
        W_GaussBeamFire(GAUSS_PRIMARY_DAMAGE, TRUE);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GaussAltFire =
{
    float r = SH_GaussTryAltFire(time);
    if (r == 1)
    {
        // gauss.cpp:213 — the first alt-fire frame sends GAUSS_SPINUP; the
        // swap to GAUSS_SPIN happens in W_GaussFrame once the wind-up is done.
        self.weaponframe = GAUSS_SEQ_SPINUP;
        self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/charge.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_GaussAltRelease =
{
    float damage;

    if (self.weaponstate != WS_SPECIAL) return;

    damage = SH_GaussCalcChargeDamage(time);
    if (damage > 0)
    {
        self.weaponframe = GAUSS_SEQ_FIRE2;
        self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
        W_GaussBeamFire(damage, FALSE);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
    }
};

void() W_GaussFrame =
{
    self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;

    if (self.weaponstate == WS_IDLE)
    {
        self.weaponframe = GAUSS_SEQ_IDLE;
        return;
    }

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of a nine-sequence model in
    // under half a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1696), so this function only has to decide
    // WHICH sequence is playing and when the state ends — and the end test is
    // elapsed time, not a frame counter hitting *_END.
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_FIRE)
    {
        self.weaponframe = (self.weaponstate == WS_DRAW) ? GAUSS_SEQ_DRAW
                                                         : GAUSS_SEQ_FIRE2;

        // SH_GaussTickState already held the authoritative elapsed-time
        // version of this test — it is what CSQC has always run — while the
        // server kept a second, frame-based copy of it that disagreed by a
        // tick or two.  One test now, shared by both halves.
        if (SH_GaussTickState(time))          // enters WS_IDLE, clears wep_anim_start
            self.weaponframe = GAUSS_SEQ_IDLE;
        return;
    }

    if (self.weaponstate == WS_SPECIAL)
    {
        // Charge animation: spinup then the spin loop.  The hand-off is a
        // latch on elapsed time (gauss.cpp:225-229 does the same thing off
        // m_flTimeWeaponIdle) rather than the old frame-counter compare.
        // Re-pointing .frame mid-state is safe: spin loops, so the engine
        // wraps whatever frame1time it is handed inside the 0.500 s.
        if (self.gauss_charge_state == 1 && elapsed >= GAUSS_SPINUP_DURATION)
            self.gauss_charge_state = 2;

        self.weaponframe = (self.gauss_charge_state >= 2) ? GAUSS_SEQ_SPIN
                                                          : GAUSS_SEQ_SPINUP;

        // Overcharge: held too long — hurts self, plays fire animation.
        // (HL sends GAUSS_IDLE here instead, gauss.cpp:298, because vanilla
        // over-charging zaps you WITHOUT discharging the gun.  This mod fires
        // it — SH_GaussCalcChargeDamage sets WS_FIRE — so the fire animation
        // is the one that matches what actually happens.  Not changing that:
        // it is behaviour, not a model detail.)
        if ((time - self.gauss_charge_started) >= GAUSS_OVERCHARGE_TIME)
        {
            SH_GaussCalcChargeDamage(time);   // clears charge state, sets WS_FIRE
            self.weaponframe = GAUSS_SEQ_FIRE2;
            W_ApplyDamage(self, self, GAUSS_OVERCHARGE_DAMAGE);
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
            return;
        }

        // Auto-fire if ammo depleted during charge (gauss.cpp:252-259)
        if (self.ammo_gauss <= 0)
        {
            float damage = SH_GaussCalcChargeDamage(time);
            if (damage > 0)
            {
                self.weaponframe = GAUSS_SEQ_FIRE2;
                W_GaussBeamFire(damage, FALSE);
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NORM);
            }
            return;
        }

        // Drain ammo periodically during charge
        if (self.gauss_charge_next_ammo > 0 && time >= self.gauss_charge_next_ammo)
        {
            if ((time - self.gauss_charge_started) < GAUSS_MAX_CHARGE_TIME)
            {
                self.ammo_gauss -= 1;
                if (self.ammo_gauss < 0) self.ammo_gauss = 0;
                self.gauss_charge_next_ammo = time + GAUSS_CHARGE_AMMO_INTERVAL;
            }
            else
                self.gauss_charge_next_ammo = 0;
        }
        return;
    }

    // Any state this weapon has no animation for (WS_RELOAD can be reached by
    // the generic reload key even though gauss has no magazine) falls back to
    // the looping idle rather than to a stale sequence index.
    self.weaponframe = GAUSS_SEQ_IDLE;
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
};

void() W_GaussEquip =
{
    // This weapon predates W_StandardEquipSetup and still inlines the same
    // field writes (it needs altfire/altrelease, which the helper clears).
    // Left inline deliberately: the migration only has to turn the draw
    // START FRAME into the draw SEQUENCE, which is what these two lines do —
    // weapon_draw_start_frame / weaponframe are the helper's `draw_start`
    // argument (sh_weapon_standard.qc:1158,1163).
    self.weaponmodel = GAUSS_VIEWMODEL;
    self.weapon_name = GAUSS_DISPLAY_NAME;
    self.weapon_draw_start_frame = GAUSS_SEQ_DRAW;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_GaussPrimaryFire; self.reload = __NULL__; self.wepframe = W_GaussFrame;
    self.altfire = W_GaussAltFire; self.altrelease = W_GaussAltRelease;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = GAUSS_SEQ_DRAW;
    self.wep_nextframe = time + GAUSS_FRAME_INTERVAL;
    // GoldSrc IDST viewmodel: .frame is a sequence index and the engine walks
    // the sequence from .frame1time (sh_weapons.qc:701, cl_weapons.qc:1677).
    self.weapon_uses_sequences = TRUE;
    self.gauss_charge_state = 0; self.gauss_charge_started = 0; self.gauss_charge_next_ammo = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, TRUE);
};

void() W_GaussDrop =
{
    entity tgt = weapon_drop_target;
    tgt.ammo_gauss = self.ammo_gauss;
    self.ammo_gauss = 0;
    setmodel(tgt, GAUSS_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_gauss"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_GAUSS; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_GaussEquip; tgt.weap_drop_func = W_GaussDrop;
    tgt.pickupcopy = W_GaussPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_gauss =
{
    setmodel(self, GAUSS_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_gauss"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_GAUSS; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_GaussEquip; self.weap_drop_func = W_GaussDrop;
    self.pickupcopy = W_GaussPickupCopy; self.touch = weapon_touch;
    self.ammo_gauss = MAX_AMMO_GAUSS;
    W_RegisterMapWeapon(weapon_gauss);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictGaussCommand =
{
    float r;

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_GaussTryPrimaryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                // ev_hldm.cpp's own beam colour, 255/128/0 -- the gauss does not
                // burn powder, so the generic orange flash was a coincidence
                // rather than a match.
                CSQC_MuzzleFlash('1.0 0.50 0.0');
                // Gauss is perfectly accurate — direct trace, no spread system.
                //
                // The shooter draws its OWN beam here rather than waiting for
                // the server's.  HLBeam_SendEntity excludes the owner for
                // exactly this reason, matching the FL_SKIPLOCALHOST split HL
                // uses (egon.cpp / ev_hldm.cpp): a beam that has to survive a
                // round trip visibly lags the crosshair.  Both sides call the
                // SAME SH_GaussBeamWalk, so the bounces agree.
                {
                    makevectors(input_angles);
                    vector gsrc = self.origin + self.view_ofs;
                    SH_GaussBeamWalk(gsrc, v_forward, GAUSS_PRIMARY_DAMAGE, TRUE);
                    if (cvar("cl_debug_impacts") && trace_fraction < 1.0)
                        CSQC_AddDebugImpact(trace_endpos, gsrc, '0 1 0', 0, 0);
                }
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Alt-fire: start charge — state change runs during replay (costs ammo, won't infinite-loop)
    // sounds only play during live prediction
    if (input_buttons & 4)
    {
        r = SH_GaussTryAltFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/charge.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Overcharge: held too long — hurts self, play fire animation
    if (self.weaponstate == WS_SPECIAL && self.gauss_charge_state > 0
        && (csqc_pred_time - self.gauss_charge_started) >= GAUSS_OVERCHARGE_TIME)
    {
        SH_GaussCalcChargeDamage(csqc_pred_time);
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NONE);
            CSQC_RecordPredictedWeaponSound();
        }
    }

    // Alt-fire release: fire charged shot — runs during replay for velocity push
    if (self.weaponstate == WS_SPECIAL
        && self.gauss_charge_state > 0 && !(input_buttons & 4))
    {
        float damage = SH_GaussCalcChargeDamage(csqc_pred_time);
        if (damage > 0)
        {
            CSQC_MarkPendingWeaponAck();

            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlgauss/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                // The charged shot's beam is pure white (ev_hldm.cpp), so its
                // flash is too.
                CSQC_MuzzleFlash('1 1 1');
                // Charged shot — same shared walk, so the shooter sees the
                // punch-through and the reflections land where the server puts
                // them.  See the primary branch above.
                {
                    makevectors(input_angles);
                    vector alt_gsrc = self.origin + self.view_ofs;
                    SH_GaussBeamWalk(alt_gsrc, v_forward, damage, FALSE);
                    if (cvar("cl_debug_impacts") && trace_fraction < 1.0)
                        CSQC_AddDebugImpact(trace_endpos, alt_gsrc, '0 1 0', 0, 0);
                }
            }
        }
    }

    SH_GaussTickState(csqc_pred_time);
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, and it wraps the
// looping sequences on its own, so the hand-rolled modulo for the charge loop
// is gone with the rest of it.
//
// `elapsed` survives here — unlike most weapons, where it is only kept because
// csqc_display_frame is a shared function-pointer type.  The charge state owns
// two sequences and the client cannot read which one the server picked:
// gauss_charge_state only ever becomes 2 inside W_GaussFrame, which is server
// side, and CSQC_PredictGaussCommand never runs it.  Elapsed since
// wep_anim_start is the same clock the server latches on, so both agree.
float(float elapsed) CSQC_GaussDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return GAUSS_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return GAUSS_SEQ_FIRE2;          // ev_hldm.cpp:912, both fire modes
    if (predicted_player.weaponstate == WS_SPECIAL)
        return (elapsed >= GAUSS_SPINUP_DURATION) ? GAUSS_SEQ_SPIN
                                                  : GAUSS_SEQ_SPINUP;
    return GAUSS_SEQ_IDLE;
};

void() CSQC_GaussDropClear =
{
	self.ammo_gauss = 0;
};

void() CSQC_GaussEquip =
{
	self.weapon_name         = GAUSS_DISPLAY_NAME;
	self.weapon_viewmodel    = GAUSS_VIEWMODEL;
	self.weapon_worldmodel   = GAUSS_WORLDMODEL;
	self.weapon_deploy_sound = GAUSS_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictGaussCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_GaussDisplayFrame;
	self.csqc_drop_clear     = CSQC_GaussDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
