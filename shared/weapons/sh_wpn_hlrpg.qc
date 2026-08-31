// ============================================================
//  shared/weapons/sh_wpn_hlrpg.qc  -  HL RPG (Laser-Guided Rocket Launcher)
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 1-rocket magazine, 5 reserve
//  Fire  : spawns a guided rocket projectile (MOVETYPE_FLYMISSILE)
//         Explodes on contact, laser-guided when active
//  Alt   : Toggle laser guide — rocket homes toward aim point
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_hlrpg;
.float ammo_hlrpg;
.float rpg_laser_active;
// Latch for the +attack2 rising edge -- see SH_RPGTryAltFire.  Cleared on the
// falling edge by W_RPGFrame (server) and CSQC_PredictRPGCommand (client).
.float rpg_alt_held;
.entity rpg_rocket;

// --- Sequence indices, read out of valve/models/v_rpg.mdl (10 seqs) ---------
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/wpn_hlrpg/
// v_rpg.mdl, an 80-frame flat bake) by frame number.  It now drives Half-
// Life's own IDST model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index -
// gl_hlmdl.c:780 sets mod->numframes = numseq - so every one of the old
// constants was meaningless against it: RPG_IDLE_FRAME was 80 and this model
// has ten sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1677 already feeds for weapons that set
// .weapon_uses_sequences.
//
// The RPG carries a full LOADED / UNLOADED pair for idle, fidget, holster and
// draw — the launcher visibly has a rocket sitting in the tube or not, so
// picking the wrong one shows a rocket that isn't there.  Indices and every
// pick below are from the SDK, not guessed: rpg.cpp:29-40 (the enum),
// :468-476 (Deploy picks DRAW_UL vs DRAW1 off m_iClip), :496 (Holster),
// :388 (Reload), :585-599 (WeaponIdle picks IDLE_UL vs IDLE off m_iClip),
// and ev_hldm.cpp:1365 (the fire anim, which lives in the client event and
// not in PrimaryAttack — rpg.cpp:510-555 never calls SendWeaponAnim).
//
// Durations below are (numframes - 1) / fps, which is what the engine hands
// back from frameduration() — gl_hlmdl.c:1542, `*duration =
// (sequence->numframes-1)/sequence->timing;` — and therefore what
// SH_SeqDuration() (sh_weapon_standard.qc:399) returns for these sequences.
// An N-frame animation spans N-1 intervals, and Valve hardcodes the same
// arithmetic: rpg.cpp:591 waits `90.0 / 15.0` out of the 91-frame 15 fps idle.
const float RPG_SEQ_IDLE1             = 0;   // idle,     91f @ 15fps = 6.000 s, looping  (rocket loaded)
const float RPG_SEQ_FIDGET1           = 1;   // fidget,   91f @ 15fps = 6.000 s, looping  (rocket loaded)
const float RPG_SEQ_RELOAD            = 2;   // reload,   61f @ 30fps = 2.000 s
const float RPG_SEQ_FIRE              = 3;   // fire,     25f @ 30fps = 0.800 s  (SDK calls this RPG_FIRE2, "to empty")
const float RPG_SEQ_HOLSTER1          = 4;   // holster1, 16f @ 30fps = 0.500 s  (rocket loaded)
const float RPG_SEQ_DRAW1             = 5;   // draw1,    16f @ 30fps = 0.500 s  (rocket loaded)
const float RPG_SEQ_HOLSTER2          = 6;   // holster2, 16f @ 30fps = 0.500 s  (tube empty)
const float RPG_SEQ_DRAW2             = 7;   // draw2,    16f @ 30fps = 0.500 s  (tube empty)  = SDK RPG_DRAW_UL
const float RPG_SEQ_IDLE2             = 8;   // idle2,    91f @ 15fps = 6.000 s, looping  (tube empty)  = SDK RPG_IDLE_UL
const float RPG_SEQ_FIDGET2           = 9;   // fidget2,  91f @ 15fps = 6.000 s, looping  (tube empty)  = SDK RPG_FIDGET_UL

// HOLSTER1/HOLSTER2 and both fidgets are declared for the record only.  This
// mod has no holster animation hook and no idle-fidget scheduler, so nothing
// reads them yet — and note that even Valve never plays HOLSTER2: rpg.cpp:496
// sends HOLSTER1 unconditionally, so the empty-tube holster is dead art in
// Half-Life too.  Kept here so a later fidget/holster pass does not have to
// re-derive the table.

const float RPG_FRAME_INTERVAL        = 0.05;   // wepframe tick rate, not an anim rate
const float RPG_FIRE_DELAY            = 1.5;    // GetNextAttackDelay(1.5), rpg.cpp:544

const float MAX_MAG_HLRPG             = 1;      // RPG_MAX_CLIP, rpg.cpp:446
const float MAX_AMMO_HLRPG            = 5;

// --- Balance ---
const float RPG_EXPLOSION_DAMAGE      = 120;
const float RPG_EXPLOSION_RADIUS      = 300;
const float RPG_EXPLOSION_MIN_DAMAGE  = 20;
const float RPG_INITIAL_SPEED         = 250;
const float RPG_ACCEL_PER_THINK       = 20;   // speed added each 0.05s think
const float RPG_MAX_GUIDED_SPEED      = 1500;
const float RPG_DRYFIRE_DELAY         = 0.2;
const float RPG_KNOCKBACK_PUSH        = 800;
const float RPG_KNOCKBACK_UPLIFT      = 350;

// --- State durations, taken from the sequences themselves ---
// These MUST equal what frameduration() reports for the same sequence, or the
// state machine and the renderer disagree about when an anim ends.  Computed
// (numframes-1)/fps like gl_hlmdl.c:1542 and like the SDK itself (rpg.cpp:591
// spends 90.0/15.0 on the 91-frame idle), which lands them on the same numbers
// the old IDPO bake used — so the migration is duration-neutral, not a revert.
// Nothing keyed to balance rides on them either way: RPG_FIRE_DELAY (1.5 s) is
// what gates the next shot, and it is far longer than the 0.8 s fire anim.
const float RPG_DRAW_DURATION         = 0.500;  // draw1 / draw2  (15/30)
const float RPG_FIRE_DURATION         = 0.800;  // fire           (24/30)
const float RPG_RELOAD_DURATION       = 2.000;  // reload         (60/30)
const float RPG_RELOAD_APPLY_TIME     = RPG_RELOAD_DURATION;  // rocket seats at the end

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling — the SDK writes mixed case in places but the shipped files are all
// lowercase, and FTE's VFS is case-sensitive against real files on Linux.
const string RPG_VIEWMODEL    = "models/v_rpg.mdl";     // rpg.cpp:472,475
const string RPG_WORLDMODEL   = "models/w_rpg.mdl";     // rpg.cpp:400 (Spawn)
const string RPG_DEPLOY_SOUND = "";
const string RPG_DISPLAY_NAME = "RPG";

const string RPG_FIRE_SOUND   = "sounds/weapons/wpn_hlrpg/fire.wav";
const string RPG_FLY_SOUND    = "sounds/weapons/wpn_hlrpg/fly.wav";
// The projectile moves to the valve mount alongside the view/world models —
// valve/models/rpgrocket.mdl is the IDST original the local IDPO copy was
// converted from (rpg.cpp:131).  It is a single-sequence static prop, so it
// needs no .weapon_uses_sequences treatment.
// sh_weapons.qc:355 holds a SECOND hardcoded copy of this path, for
// PROJ_TYPE_RPG_ROCKET (the CSQC setmodel that dresses the replicated rocket
// other players see).  It has been repointed to match, so the shooter's
// predicted fake and every remote client now render the same file — keep the
// two in step if this path ever moves again.
const string RPG_ROCKET_MODEL = "models/rpgrocket.mdl";

// rpg.cpp:62-74, CLaserSpot::Spawn -- "sprites/laserdot.spr", kRenderGlow +
// kRenderFxNoDissipation at renderamt 255.  Present in the mounted valve tree.
const string RPG_LASER_SPRITE = "sprites/laserdot.spr";

// ============================================================
//  SHARED — state machine
// ============================================================

// Should the launcher reload itself right now?
//
// Half-Life does this in the GENERIC weapon loop, not in the RPG class:
// CBasePlayerWeapon::ItemPostFrame ends with "if clip is empty and the weapon
// doesn't set ITEM_FLAG_NOAUTORELOAD and the next-attack debounce has expired,
// Reload()".  Because RPG_MAX_CLIP is 1, EVERY shot empties the tube, so in
// practice the RPG reloads itself after every rocket — which is what the player
// expects and what this mod was missing (it has no auto-reload mechanism at all;
// reload was only ever reachable from an explicit keypress).
//
// The one interlock is CRpg::Reload's own: it refuses while a rocket is still in
// flight AND the laser spot is on, because reloading swings the launcher down
// and would drag the guidance point with it.  Both pieces of state already exist
// here, they just were not read together.
// Defined below SH_RPGTickState, which calls it.
float(float now) SH_RPGTryReload;

float(float now) SH_RPGWantsAutoReload =
{
    if (self.mag_hlrpg > 0)          return FALSE;   // tube still loaded
    if (self.ammo_hlrpg <= 0)        return FALSE;   // nothing to load
    if (now < self.attack_finished)  return FALSE;   // post-shot debounce
    // rpg.cpp: m_cActiveRockets && m_fSpotActive -> don't reload yet.
    if (self.rpg_rocket && self.rpg_rocket != world && self.rpg_laser_active)
        return FALSE;
    return TRUE;
};

float(float now) SH_RPGTickState =
{
    float r = SH_StandardTickState(now, mag_hlrpg, ammo_hlrpg, MAX_MAG_HLRPG,
        RPG_DRAW_DURATION, RPG_FIRE_DURATION,
        RPG_RELOAD_DURATION, RPG_RELOAD_APPLY_TIME);

    // A POLL, not an edge.
    //
    // This used to be gated on bit 0 of the result -- "this tick retired the
    // weapon to idle" -- and that could never fire.  Three independent reasons,
    // all of them arithmetic:
    //
    //   1. SH_RPGWantsAutoReload requires now >= attack_finished, which a shot
    //      sets to now + RPG_FIRE_DELAY (1.5 s).  Bit 0 is raised when the fire
    //      ANIMATION ends, at now + RPG_FIRE_DURATION (0.8 s).  The one tick the
    //      test ran on was guaranteed to be 0.7 s too early.
    //   2. Bit 0 is raised exactly once and never re-armed --
    //      SH_StandardTickState returns 0 immediately once weaponstate is
    //      WS_IDLE -- so there was no second chance.
    //   3. Server-side this whole function is only reachable from W_RPGFrame,
    //      which retires with wep_nextframe = 0; CSQC keeps ticking every frame.
    //      Even with 1 and 2 fixed the two VMs would have disagreed.
    //
    // Half-Life polls instead: the auto-reload lives at the END of the generic
    // CBasePlayerWeapon::ItemPostFrame, which runs every frame the weapon is
    // held, and is gated on the same attack debounce.  So does this now, and
    // W_RPGFrame keeps itself alive while a reload is pending (see there).
    //
    // Clearing bit 0 when a reload starts is still LOAD-BEARING -- leaving it
    // set would let W_RPGFrame zero wep_nextframe on the same tick, the server
    // would stop calling wepframe, and the reload would never complete.  That is
    // the freeze that killed the satchel and the tripmine.
    // IT USED TO BE SERVER-ONLY, and the reason no longer holds.  Predicting an
    // auto-reload once made the first shot appear to reload twice:
    //
    //   t+0    client predicts the shot, its own mag_hlrpg goes 1 -> 0
    //   t+0    client polls, sees an empty tube, starts a PREDICTED reload
    //   t+dt   the server's snapshot arrives.  Its reload has not applied yet,
    //          so the authoritative mag is still 0 and the client's predicted
    //          WS_RELOAD is overwritten by the server's pre-reload state
    //   t+dt   the client polls again on the very next frame and starts a
    //          SECOND reload animation
    //
    // Step three is gone.  Reconcile no longer writes fire-decision state back
    // at all -- client/cl_player.qc:1022, "FIRE-DECISION STATE NO LONGER
    // RECONCILED FROM SERVER" -- and sv_confirmed_weaponstate is written and
    // never read.  The client's WS_RELOAD is now its own and nothing overwrites
    // it, so there is no second poll and no second reload.
    //
    // What server-only cost instead was the ANIMATION.  The comment below said
    // stamping .weaponframe fixed "no reload animation, first or third person",
    // and it fixed the third-person half: .weaponframe is what the proxy plays.
    // The VIEWMODEL is chosen client-side from predicted_player.weaponstate,
    // which the server's copy could not reach -- so on the shooter's own screen
    // the launcher held its idle pose for two seconds and the rocket reappeared
    // by itself.  That is the reported "the rockets don't auto reload after being
    // fired", and the same fault was in both DoD launcher files.
    if (SH_RPGWantsAutoReload(now) && SH_RPGTryReload(now))
    {
#ifdef SSQC
        // STAMP THE ANIMATION, exactly as the manual W_RPGReload does.  Entering
        // WS_RELOAD is not by itself enough on the server: .weaponframe is a
        // sequence index that something has to write, and .wep_nextframe is what
        // keeps W_RPGFrame being called at all.
        //
        // This is the path that matters, not the fallback: the magazine is ONE
        // rocket, so every shot ends empty and every reload in normal play is this
        // auto one.  The manual path only runs if you press reload on a full tube.
        self.weaponframe   = RPG_SEQ_RELOAD;
        self.wep_nextframe = now + RPG_FRAME_INTERVAL;
#endif
        r = r & ~1;
    }

    return r;
};

float(float now) SH_RPGTryFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    return SH_StandardTryFire(now, mag_hlrpg, RPG_FIRE_DELAY, RPG_DRYFIRE_DELAY);
};

float(float now) SH_RPGTryReload =
{
    return SH_StandardTryReload(now, mag_hlrpg, ammo_hlrpg, MAX_MAG_HLRPG, RPG_RELOAD_DURATION);
};

// EDGE-triggered, not level-triggered.  This is why the guide dot never showed.
//
// sv_weapons.qc:3852 calls self.altfire() on EVERY server frame that button1 is
// held -- it is a "while held" dispatch, not a "on press" one.  A bare toggle
// therefore flipped the laser on and off again every 0.3 s for as long as the
// player held right-click, and each flip removed and respawned the spot entity,
// so the dot existed for at most 0.3 s at a time under a brand-new entity number
// the client had to re-acquire.  Worse, CSQC ran the same toggle against its own
// altfire_finished, so the two VMs drifted out of phase and disagreed about
// whether the laser was on at all -- which also gated the rocket homing.
//
// rpg_alt_held latches the press; the frame function (server) and the predict
// tick (client) clear it on the falling edge, exactly as the barnacle grapple
// does with bgrap_fire_held.
float(float now) SH_RPGTryAltFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.rpg_alt_held) return 0;          // already handled this press
    if (now < self.altfire_finished) return 0;

    self.rpg_alt_held     = TRUE;
    self.rpg_laser_active = !self.rpg_laser_active;
    // Short anti-chatter only.  It used to be 0.3 s and doubled as the toggle
    // rate; with a real edge it just stops a stuck/turbo button re-triggering
    // faster than the animation reads.
    self.altfire_finished = now + 0.1;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// The guidance spot.
//
// This weapon had NO laser-spot entity of any kind: rpg_laser_active was a bare
// invisible flag that only the homing code read, so +attack2 toggled guidance
// with nothing on screen to show for it -- the "rightclick doesn't display red
// dot" report.  HL's is a real entity (CLaserSpot, rpg.cpp:62-74) re-traced
// every frame in CRpg::UpdateSpot (:613-635), and it is server-side there too,
// so a plain replicated entity here is the faithful shape as well as the simple
// one: everyone sees the same dot, including the shooter.
.entity rpg_laser_spot;

void(entity player) W_RPGLaserKill =
{
    if (player.rpg_laser_spot)
    {
        remove(player.rpg_laser_spot);
        player.rpg_laser_spot = world;
    }
};

void(entity player) W_RPGLaserUpdate =
{
    // rpg.cpp:380-384 -- the spot is suspended while reloading, because the
    // launcher swings down and the guidance point would swing with it.
    if (!player.rpg_laser_active || player.weaponstate == WS_RELOAD
        || player.is_dead || player.health <= 0)
    {
        W_RPGLaserKill(player);
        return;
    }

    makevectors(player.v_angle);
    vector src = player.origin + player.view_ofs;
    traceline(src, src + v_forward * 8192, MOVE_NORMAL, player);

    if (!player.rpg_laser_spot)
    {
        entity spot = spawn();
        spot.classname = "rpg_laser_spot";
        spot.owner     = player;
        spot.movetype  = MOVETYPE_NONE;
        spot.solid     = SOLID_NOT;
        setmodel(spot, RPG_LASER_SPRITE);
        setsize(spot, '0 0 0', '0 0 0');
        // Additive glow that does not shrink with distance, matching
        // kRenderGlow + kRenderFxNoDissipation.
        spot.effects   = spot.effects | EF_ADDITIVE | EF_FULLBRIGHT;
        // Hidden from the player aiming it, who draws their own from live aim
        // (CSQC_RPGLaserUpdate).  A server-traced dot is a round trip behind the
        // crosshair, which on a sweeping aim reads as the dot dragging after the
        // reticle.  Same shooter/observer split the egon and gauss beams use.
        spot.nodrawtoclient = player;
        player.rpg_laser_spot = spot;
    }

    // Lift the dot off the surface by a hair.  A sprite exactly coplanar with a
    // wall z-fights with it; the same reason every impact effect in this tree
    // offsets along the normal (cl_bulletimpact.qc).
    setorigin(player.rpg_laser_spot, trace_endpos + trace_plane_normal * 2);
};

void(entity player) W_RPGPickupCopy =
{
    player.mag_hlrpg  = self.mag_hlrpg;
    player.ammo_hlrpg = self.ammo_hlrpg;
};

// Rocket explosion — radius damage
void() W_RPGExplode =
{
    // Exclude shooter from explosion effects — they see the client-predicted one
    float saved_dim = dimension_send;
    if (self.owner)
        dimension_send = dimension_send & ~self.owner.dimension_seen;

    te_explosion(self.origin + '0 0 8');

    dimension_send = saved_dim;

    // Radius damage + player knockback + phys-drop blast — single call.
    W_RadiusExplode(self.origin, RPG_EXPLOSION_RADIUS,
                    RPG_EXPLOSION_DAMAGE, RPG_EXPLOSION_MIN_DAMAGE,
                    RPG_KNOCKBACK_PUSH, RPG_KNOCKBACK_UPLIFT, self.owner);

    // Stop fly sound on the same clients that received it — skip shooter,
    // whose CSQC fake rocket will stop its own local fly sound on explode.
    entity fc = player_chain_head;
    while (fc)
    {
        if (fc != self.owner)
        {
            msg_entity = fc;
            sound(self, CHAN_VOICE, "sounds/null.wav", 0, ATTN_NORM, 0,
                  SOUNDFLAG_UNICAST);
        }
        fc = fc.player_chain_next;
    }

    // Clear owner's rocket reference
    if (self.owner)
        self.owner.rpg_rocket = world;

    remove(self);
};

void() W_RPGRocketTouch =
{
    if (other == self.owner)
        return;   // don't explode on shooter
    W_RPGExplode();
};

void() W_RPGRocketThink =
{
    // Pulse CSQC SendFlags so cl_tosssmooth.qc gets a fresh sample
    // every think tick — projectile_SendEntity (sv_weapons.qc) writes
    // origin+velocity for the smoothing extrap.
    self.SendFlags |= 1;

    float spd = vlen(self.velocity);
    vector dir = normalize(self.velocity);

    // Laser guidance: home toward owner's aim point
    if (self.owner && self.owner.rpg_laser_active)
    {
        makevectors(self.owner.v_angle);
        vector src = self.owner.origin + self.owner.view_ofs;
        traceline(src, src + v_forward * 8192, MOVE_NORMAL, self.owner);
        dir = normalize(trace_endpos - self.origin);
    }

    // Always accelerate toward max speed (aggressive ramp-up). Scale by
    // actual think interval (sv_toss_tickrate-derived) so per-second
    // acceleration is invariant — RPG_ACCEL_PER_THINK was tuned for the
    // legacy 0.05 s (20 Hz) tick and we now run at 1 / sv_toss_tickrate.
    float interval = Toss_NextThinkInterval();
    spd = spd + RPG_ACCEL_PER_THINK * (interval / 0.05);
    if (spd > RPG_MAX_GUIDED_SPEED)
        spd = RPG_MAX_GUIDED_SPEED;
    self.velocity = dir * spd;
    self.angles = W_ModelAngles(self.velocity, TRUE);   // IDST model — pitch negated

    self.nextthink = time + interval;
};

void() W_RPGFire =
{
    float r;
    entity rocket;

    r = SH_RPGTryFire(time);
    if (r == 1)
    {
        // Only one fire sequence exists — ev_hldm.cpp:1365 plays RPG_FIRE2
        // unconditionally, because with RPG_MAX_CLIP == 1 the launcher is
        // ALWAYS empty the instant it fires.  SH_StandardTryFire has already
        // decremented (sh_weapon_standard.qc:225), so mag_hlrpg is 0 from here
        // on and the idle we retire to below is the unloaded one.
        self.weaponframe = RPG_SEQ_FIRE;
        self.wep_nextframe = time + RPG_FRAME_INTERVAL;

        // Spawn rocket projectile
        makevectors(self.v_angle);
        rocket = spawn();
        rocket.owner = self;
        rocket.classname = "proj_rpg_rocket";
        rocket.movetype = MOVETYPE_FLYMISSILE;
        rocket.solid = SOLID_BBOX;
        setmodel(rocket, RPG_ROCKET_MODEL);
        setsize(rocket, '-2 -2 -2', '2 2 2');
        // Exhaust trail.  rpg.cpp:196-227 does this with TE_BEAMFOLLOW and
        // sprites/smoke.spr; FTE has no TE_BEAMFOLLOW.  Recipe in
        // particles/trails.cfg, carrying HL's own 224/224/255 and 4 s life.
        //
        // Emitted from CSQC by cl_throwtrail.qc, keyed off proj_type.  It used to
        // be .traileffectnum, which looked engine-native and free -- and did
        // nothing at all: the client only walks that field for delta-replicated
        // packet entities (cl_ents.c:5601), and this rocket is a SendEntity
        // projectile, so it is a CSQC entity on both the networked and the fake
        // path.  Nobody ever saw this smoke, shooter or bystander.
        // rpg.cpp launches from GetGunPosition() + forward*16 + right*8 + up*-8,
        // i.e. out of the tube on the shoulder, not the centre of the view.  The
        // dead-centre spawn this used to do is what made the rocket look like it
        // came out of the player's face.
        setorigin(rocket, self.origin + self.view_ofs
                          + v_forward * 16 + v_right * 8 + v_up * -8);
        // ...and HL adds the component of the player's own velocity along the
        // launch direction, so firing while moving forward doesn't leave the
        // rocket appearing to hang in front of you.
        rocket.velocity = v_forward * RPG_INITIAL_SPEED
                        + v_forward * (self.velocity * v_forward);
        rocket.angles = W_ModelAngles(rocket.velocity, TRUE);   // IDST model — pitch negated
        rocket.touch = W_RPGRocketTouch;
        // CSQC replication via projectile_SendEntity — shooter is hidden
        // by SendEntity FALSE-return (their CSQC fake covers the visual);
        // others get smooth flight via cl_tosssmooth.qc extrap+smooth.
        // Rocket has no fuse-expire (only W_RPGRocketTouch removes it),
        // so proj_fuse_end stays unset and the think loops indefinitely.
        rocket.proj_type   = PROJ_TYPE_RPG_ROCKET;
        rocket.SendEntity  = projectile_SendEntity;
        rocket.SendFlags   = 1;
        rocket.think       = W_RPGRocketThink;
        rocket.nextthink   = time + Toss_NextThinkInterval();

        // Looping fly sound attached to the rocket, unicast to everyone
        // except the shooter.  SOUNDFLAG_FOLLOW makes the engine update the
        // channel's origin to the rocket's position each frame, but only
        // when the client is receiving entity updates for it — the shooter's
        // nodrawtoclient suppresses the rocket entirely, so their client
        // would fall back to the spawn origin and stay stuck there.  Their
        // CSQC fake rocket plays an equivalent local sound instead.
        entity c = player_chain_head;
        while (c)
        {
            if (c != self)
            {
                msg_entity = c;
                sound(rocket, CHAN_VOICE, RPG_FLY_SOUND, 1, ATTN_NORM, 0,
                      SOUNDFLAG_FOLLOW | SOUNDFLAG_UNICAST);
            }
            c = c.player_chain_next;
        }

        // Track active rocket
        self.rpg_rocket = rocket;

        sound(self, CHAN_WEAPON, RPG_FIRE_SOUND, 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_RPGAltFire =
{
    if (!SH_RPGTryAltFire(time))
        return;
    // Toggling the spot ON has to restart the frame function, which is what
    // re-traces it -- an idle RPG has retired its tick, so without this the
    // laser would only appear after the next shot or reload.
    if (self.wep_nextframe <= 0)
        self.wep_nextframe = time + RPG_FRAME_INTERVAL;
    // ...and toggling it OFF should take the dot away on the same frame rather
    // than waiting for the next tick.
    W_RPGLaserUpdate(self);
};

void() W_RPGReload =
{
    if (SH_RPGTryReload(time))
    {
        // Single reload sequence — rpg.cpp:388 only ever calls
        // DefaultReload(RPG_MAX_CLIP, RPG_RELOAD, 2), and only when
        // m_iClip == 0, so there is no "partial reload" variant to pick.
        self.weaponframe   = RPG_SEQ_RELOAD;
        self.wep_nextframe = time + RPG_FRAME_INTERVAL;
    }
};

void() W_RPGFrame =
{
    float result;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of a ten-sequence model
    // within half a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1697), so this function only has to decide
    // WHICH sequence is playing and when the state ends.
    self.wep_nextframe += RPG_FRAME_INTERVAL;

    // Falling edge of +attack2.  The dispatcher has no release hook for this
    // button on a weapon without .altrelease, so the latch is cleared here --
    // the same place and for the same reason the barnacle grapple clears
    // bgrap_fire_held (sh_wpn_opbgrapple.qc).
    if (!self.button1)
        self.rpg_alt_held = FALSE;

    // Re-trace the guidance dot every tick it is on (rpg.cpp CRpg::UpdateSpot).
    W_RPGLaserUpdate(self);

    result = SH_RPGTickState(time);
    if (result & 1)
    {
        // rpg.cpp:585-590 — WeaponIdle picks the unloaded idle when the tube
        // is empty.  This runs after a fire (mag now 0 -> IDLE2) and after a
        // reload (mag now 1 -> IDLE1), so both land on the right art.
        self.weaponframe = (self.mag_hlrpg > 0) ? RPG_SEQ_IDLE1 : RPG_SEQ_IDLE2;

        // Retire ONLY when there is nothing left to poll for.  The auto-reload
        // is gated on the 1.5 s post-shot debounce but the fire animation ends
        // at 0.8 s, so retiring here unconditionally stopped the server ticking
        // 0.7 s before the reload could ever start -- and it never restarted,
        // because the frame function is the only thing that would have.
        //
        // An empty tube is a pending auto-reload, so keep ticking;
        // SH_RPGTickState starts it as soon as the debounce expires, and the
        // tick after that reload completes we retire for real.
        //
        // Empty tube AND empty reserve keeps polling too, deliberately: that is
        // how picking a rocket up off the floor loads the launcher without
        // needing a keypress, which is what HL's always-running ItemPostFrame
        // gives you for free.  It costs one 20 Hz tick for one player holding
        // one empty weapon.
        //
        // An active laser spot also has to keep the tick alive -- this function
        // is the only thing that re-traces it, so retiring here would freeze the
        // dot wherever it happened to be.
        //
        // And an UNRELEASED +attack2 keeps it alive too, or the latch above can
        // never be cleared: switching the laser off retires the tick on the very
        // same frame that set rpg_alt_held, stranding it TRUE, and every later
        // press would then be swallowed as "already handled this press".  One
        // extra tick after the button comes up costs nothing and closes that.
        if (self.mag_hlrpg > 0 && !self.rpg_laser_active && !self.rpg_alt_held)
            self.wep_nextframe = 0;   // idle retire — the only legal place to zero this
    }
};

void() W_RPGEquip =
{
    // rpg.cpp:468-476 — Deploy raises the empty launcher when m_iClip == 0.
    // Ammo is already on the player here: weapon_touch runs pickupcopy at
    // sv_weapons.qc:2789, before it calls weap_draw.
    float draw_seq = (self.mag_hlrpg > 0) ? RPG_SEQ_DRAW1 : RPG_SEQ_DRAW2;

    W_StandardEquipSetup(RPG_VIEWMODEL, RPG_DISPLAY_NAME, draw_seq,
        RPG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_RPGFire;
    self.reload   = W_RPGReload;
    self.wepframe = W_RPGFrame;
    self.altfire  = W_RPGAltFire;
    W_RPGLaserKill(self);
    self.rpg_laser_active = 0;
    self.rpg_rocket = world;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_RPGDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_hlrpg  = self.mag_hlrpg;
    tgt.ammo_hlrpg = self.ammo_hlrpg;

    self.mag_hlrpg  = 0;
    self.ammo_hlrpg = 0;
    W_RPGLaserKill(self);
    self.rpg_laser_active = 0;
    self.rpg_rocket = world;

    setmodel(tgt, RPG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_hlrpg";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLRPG;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_RPGEquip;
    tgt.weap_drop_func = W_RPGDrop;
    tgt.pickupcopy   = W_RPGPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlrpg =
{
    setmodel(self, RPG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_hlrpg";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLRPG;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_RPGEquip;
    self.weap_drop_func = W_RPGDrop;
    self.pickupcopy    = W_RPGPickupCopy;
    self.touch         = weapon_touch;
    self.mag_hlrpg     = MAX_MAG_HLRPG;
    self.ammo_hlrpg    = MAX_AMMO_HLRPG;
    W_RegisterMapWeapon(weapon_hlrpg);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// The shooter's own guidance dot.
//
// The server spawns the authoritative spot and hides it from this player
// (nodrawtoclient), because a server-traced dot lands a round trip behind the
// crosshair and visibly drags when you sweep the aim.  This is the same
// shooter-predicted / observer-networked split the egon and gauss beams use, and
// it is built from the SAME numbers as W_RPGLaserUpdate so the two cannot drift:
// 8192-unit traceline from the eye, lifted 2 units off the surface, additive.
entity csqc_rpg_laser_spot;

void() CSQC_RPGLaserKill =
{
    if (csqc_rpg_laser_spot)
    {
        remove(csqc_rpg_laser_spot);
        csqc_rpg_laser_spot = world;
    }
};

// Dead-man timer.  CSQC_RPGLaserUpdate only runs while the RPG is the ACTIVE
// weapon, so switching away simply stops refreshing the dot -- there is no
// unequip hook that would fire.  Rather than couple the generic
// CSQC_WeaponEquip to this one weapon, the spot removes itself if it is not
// refreshed, the same way the local env_beam does.  Clearing the global from
// inside the expire is what makes it safe to hold in one at all.
void() CSQC_RPGLaserExpire =
{
    if (csqc_rpg_laser_spot == self) csqc_rpg_laser_spot = world;
    remove(self);
};

void() CSQC_RPGLaserUpdate =
{
    entity pl = predicted_player;

    // Mirrors W_RPGLaserUpdate's suspend conditions exactly (rpg.cpp:380-384 --
    // the launcher swings down to reload and the guide point would swing too).
    // STAT_IS_DEAD rather than a .health field: the predicted player carries no
    // health in CSQC (cl_debuginfo.qc:789 uses the same stat for the same reason).
    if (!pl.rpg_laser_active || pl.weaponstate == WS_RELOAD
        || getstatf(STAT_IS_DEAD) || pl.weapon != WEP_HLRPG)
    {
        CSQC_RPGLaserKill();
        return;
    }

    makevectors(input_angles);
    vector src = pl.origin + pl.view_ofs;
    CSQC_WeaponTraceLine(src, src + v_forward * 8192, MOVE_NORMAL, pl);

    if (!csqc_rpg_laser_spot)
    {
        entity spot = spawn();
        spot.classname = "csqc_rpg_laser_spot";
        spot.movetype  = MOVETYPE_NONE;
        spot.solid     = SOLID_NOT;
        setmodel(spot, RPG_LASER_SPRITE);
        setsize(spot, '0 0 0', '0 0 0');
        spot.drawmask  = MASK_ENGINE;
        // laserdot.spr is SPR_ADDITIVE art; FTE does not read that field, so
        // without EF_ADDITIVE the "dot" is an opaque 16x16 black tile.
        spot.effects   = spot.effects | EF_ADDITIVE | EF_FULLBRIGHT;
        spot.think     = CSQC_RPGLaserExpire;
        csqc_rpg_laser_spot = spot;
    }

    setorigin(csqc_rpg_laser_spot, trace_endpos + trace_plane_normal * 2);
    csqc_rpg_laser_spot.nextthink = time + 0.25;   // refresh the dead-man timer
};

void() CSQC_FakeRPGRocketExplode =
{
    // Stop the looping fly sound attached to this CSQC-local ent before
    // the entity vanishes — otherwise CF_FOLLOW leaves it playing forever
    // at the last-known origin.
    sound(self, CHAN_VOICE, "sounds/null.wav", 0, ATTN_NORM);
    pointsound(self.origin, "sounds/weapons/explode1.wav", 1, ATTN_NORM);
    te_explosion(self.origin + '0 0 8');
    remove(self);
};

// Accelerate fake rocket to match server behavior
void() CSQC_FakeRPGRocketThink =
{
    float spd = vlen(self.velocity);
    vector dir = normalize(self.velocity);

    // Laser guidance — MIRRORS W_RPGRocketThink.  This branch was missing
    // entirely, so with the spot on, the shooter's own rocket flew dead straight
    // while the authoritative one curved toward the aim point, and the fake
    // exploded wherever IT happened to land.  The shooter was the only player
    // seeing the wrong flight path and the wrong blast location.
    if (self.owner && self.owner.rpg_laser_active)
    {
        // view_angles, not v_angle: .v_angle is a server-side player field and
        // does not exist on a CSQC entity.  This think runs outside prediction
        // (it is an entity think, not a command), so view_angles — the local
        // player's current aim — is the right source, and is what the CS
        // grenades' own out-of-prediction path uses.
        makevectors(view_angles);
        vector src = self.owner.origin + self.owner.view_ofs;
        traceline(src, src + v_forward * 8192, MOVE_NORMAL, self.owner);
        dir = normalize(trace_endpos - self.origin);
    }

    // Same per-second acceleration as the server: it scales the per-think
    // constant by (interval / 0.05), and this path ticks at exactly 0.05.
    spd = spd + RPG_ACCEL_PER_THINK;
    if (spd > RPG_MAX_GUIDED_SPEED)
        spd = RPG_MAX_GUIDED_SPEED;
    self.velocity = dir * spd;
    self.angles = W_ModelAngles(self.velocity, TRUE);   // IDST model — pitch negated
    self.nextthink = time + 0.05;
};

void() CSQC_FakeRPGRocketTouch =
{
    if (other == self.owner)
        return;
    CSQC_FakeRPGRocketExplode();
};

void() CSQC_PredictRPGCommand =
{
    float r;

    // Alt-fire: toggle laser guide.  Edge-triggered, matching the server -- this
    // block runs every predicted frame the button is held, so a bare toggle here
    // flipped the client's copy of rpg_laser_active in and out of phase with the
    // server's.  See SH_RPGTryAltFire.
    if (input_buttons & 4)
    {
        if (SH_RPGTryAltFire(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }
    else
    {
        self.rpg_alt_held = FALSE;   // falling edge
    }

    // The shooter's own dot, re-traced from the LIVE aim every frame.  The
    // server's spot entity is authoritative and is what everyone else sees, but
    // it arrives a round trip late, so for the person aiming it visibly trailed
    // the crosshair.  Same split as the beams and the projectiles: predicted
    // locally for the shooter, networked for observers.
    CSQC_RPGLaserUpdate();

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_RPGTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, RPG_FIRE_SOUND, 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash(MUZZLE_TINT_DEFAULT);

                // Spawn fake rocket projectile for instant visual
                {
                    entity rocket = spawn();
                    makevectors(input_angles);
                    setmodel(rocket, RPG_ROCKET_MODEL);
                    setsize(rocket, '-2 -2 -2', '2 2 2');
                    // Must match W_RPGFire's launch exactly, or the shooter's
                    // predicted rocket starts somewhere the real one never was.
                    setorigin(rocket, self.origin + self.view_ofs
                                      + v_forward * 16 + v_right * 8 + v_up * -8);
                    rocket.owner = self;
                    rocket.velocity = v_forward * RPG_INITIAL_SPEED
                                    + v_forward * (self.velocity * v_forward);
                    rocket.angles = W_ModelAngles(rocket.velocity, TRUE);   // IDST model — pitch negated
                    rocket.movetype = MOVETYPE_FLYMISSILE;
                    rocket.solid = SOLID_BBOX;
                    rocket.drawmask = MASK_ENGINE;
                    // Same trail as the server rocket.  projectile_SendEntity
                    // hides the real one from its own shooter, so this fake is
                    // the ONLY rocket the person firing ever sees -- and the
                    // only one whose trail they can be shown.  classname is what
                    // cl_throwtrail.qc's walker finds; proj_type picks the recipe.
                    rocket.classname            = "csqc_fake_projectile";
                    rocket.csqc_projectile_type = PROJ_TYPE_RPG_ROCKET;
                    rocket.touch = CSQC_FakeRPGRocketTouch;
                    rocket.think = CSQC_FakeRPGRocketThink;
                    rocket.nextthink = time + 0.05;

                    // Local looping fly sound that follows the shooter's
                    // predicted rocket — the server-side sound is unicast-
                    // skipped for this client so there's no double audio.
                    sound(rocket, CHAN_VOICE, RPG_FLY_SOUND, 1, ATTN_NORM, 0,
                          SOUNDFLAG_FOLLOW);
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

    SH_RPGTickState(csqc_pred_time);
};

void() CSQC_PredictRPGReload =
{
    if (SH_RPGTryReload(csqc_pred_time))
        CSQC_MarkPendingWeaponAck();
};

// Returns a SEQUENCE index now, not an interpolated frame number, so the
// CSQC_StandardDisplayFrame interpolator no longer applies.  The engine does
// the within-sequence advance itself from .frame1time, which is why the
// `elapsed` argument goes unused here — it stays in the signature because
// csqc_display_frame is a shared function pointer type.
//
// The loaded/unloaded picks mirror the server half exactly; predicted_player's
// mag_hlrpg is the same post-decrement value W_RPGFire sees, so a shot the
// client has predicted but the server has not acked still shows the empty
// launcher rather than popping a rocket back into the tube for one frame.
float(float elapsed) CSQC_RPGDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return (predicted_player.mag_hlrpg > 0) ? RPG_SEQ_DRAW1 : RPG_SEQ_DRAW2;
    if (predicted_player.weaponstate == WS_FIRE)
        return RPG_SEQ_FIRE;
    if (predicted_player.weaponstate == WS_RELOAD)
        return RPG_SEQ_RELOAD;
    return (predicted_player.mag_hlrpg > 0) ? RPG_SEQ_IDLE1 : RPG_SEQ_IDLE2;
};

void() CSQC_RPGDropClear =
{
	self.mag_hlrpg = 0;
	self.ammo_hlrpg = 0;
	self.rpg_laser_active = 0;
	self.rpg_alt_held = 0;
	CSQC_RPGLaserKill();   // don't wait out the dead-man timer on a drop
};

void() CSQC_RPGEquip =
{
	self.weapon_name         = RPG_DISPLAY_NAME;
	self.weapon_viewmodel    = RPG_VIEWMODEL;
	self.weapon_worldmodel   = RPG_WORLDMODEL;
	self.weapon_deploy_sound = RPG_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictRPGCommand;
	self.csqc_predict_reload = CSQC_PredictRPGReload;
	self.csqc_display_frame  = CSQC_RPGDisplayFrame;
	self.csqc_drop_clear     = CSQC_RPGDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
