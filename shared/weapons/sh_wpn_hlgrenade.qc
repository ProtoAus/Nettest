// ============================================================
//  shared/weapons/sh_wpn_hlgrenade.qc  -  HL Hand Grenade
//
//  Slot  : SLOT_UTILITY  (impulse 1 / key 1)
//  Stats : ammo_hlgrenade (direct ammo pool, max 5)
//  Fire  : hold +attack to pull pin → starts a 5 s absolute fuse from
//         the moment the pin is pulled.  Release at any time to throw
//         with a fixed velocity (forward + up + player velocity).  The
//         grenade's airborne fuse = max(0, 5 − hold_time), so cooking
//         past 5 s detonates the grenade essentially on release.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float hlgren_throw_vel;      // pending-spawn flag (1 = grenade entity needs to spawn after THROW_DELAY)
.float hlgren_spawn_time;     // time when the grenade entity should actually spawn
.float hlgren_fake_spawned_serial; // CSQC: wep_action_id of the throw whose fake gren is currently in flight. Each unack'd throw cmd replays every tick under high ping; without this guard the live frame after each replay re-fires the spawn block (because SH_HLGrenadeThrow keeps re-setting hlgren_throw_vel=1) and pumps out a duplicate fake every reconcile tick.

float(float spent_wep) W_UtilityNextAfterSpent;

// --- Animation frames ---
const float HLGREN_FRAME_INTERVAL         = 0.05;    // 1/20

const float HLGREN_DRAW_START             = 0;
const float HLGREN_DRAW_END               = 10;

const float HLGREN_PIN_START              = 11;
const float HLGREN_PIN_END                = 22;

// Single throw animation — used for every release regardless of cook time.
const float HLGREN_THROW_START            = 61;
const float HLGREN_THROW_END              = 79;
const float HLGREN_THROW_INTERVAL         = 0.033;   // ~30fps

// Idle is a looping animation (Quake MDL — manual frame stepping in the
// CSQC display function, since this format has no built-in sequence
// playback). Frames 80..125 = "no arms / empty hand" rest pose.
const float HLGREN_IDLE_START             = 80;
const float HLGREN_IDLE_END               = 125;
const float HLGREN_IDLE_FRAME             = 80;   // first idle frame (server seed)

const float MAX_AMMO_HLGRENADE            = 5;

// --- Balance ---
const float HLGREN_EXPLOSION_DAMAGE       = 100;
const float HLGREN_EXPLOSION_RADIUS       = 250;
const float HLGREN_EXPLOSION_MIN_DAMAGE   = 10;
// Total fuse from pin pull to detonation.  The grenade's nextthink is
// anchored to (pin_pull_time + HLGREN_FUSE_TIME), so cooking eats into
// the airborne portion of the fuse.
const float HLGREN_FUSE_TIME              = 3.5;   // tight "live" feel
// Fixed throw velocity (no charge mechanic).  Player velocity is added
// on top in W_HLGrenadeFrame.
const float HLGREN_THROW_FORWARD          = 336;   // 480 × 0.7 — additional 30% reduction
const float HLGREN_THROW_UPWARD           = 160;   // halved from 320 — flatter arc
const float HLGREN_DRYFIRE_DELAY          = 0.2;
const float HLGREN_THROW_DELAY            = 0.1;  // delay after release before grenade spawns
const float HLGREN_KNOCKBACK_PUSH         = 800;
const float HLGREN_KNOCKBACK_UPLIFT       = 350;

// --- Pre-computed durations ---
const float HLGREN_DRAW_DURATION          = (HLGREN_DRAW_END - HLGREN_DRAW_START) * HLGREN_FRAME_INTERVAL;
const float HLGREN_PIN_DURATION           = (HLGREN_PIN_END - HLGREN_PIN_START) * HLGREN_FRAME_INTERVAL;
const float HLGREN_THROW_DURATION         = (HLGREN_THROW_END - HLGREN_THROW_START) * HLGREN_THROW_INTERVAL;

const string HLGREN_VIEWMODEL    = "models/weapons/wpn_hlgrenade/v_grenade.mdl";
const string HLGREN_WORLDMODEL   = "models/weapons/wpn_hlgrenade/w_grenade.mdl";
const string HLGREN_DEPLOY_SOUND = "";
const string HLGREN_DISPLAY_NAME = "GRENADE";

const string HLGREN_GRENADE_MODEL = "models/weapons/wpn_hlgrenade/w_grenade.mdl";

// ============================================================
//  SHARED — state machine (custom, not SH_SimpleTickState)
// ============================================================

// Returns: 1 = transitioned to idle, 0 = no change
//
// WS_FIRE timing has two phases when more grenades are in the pool:
//   [0, THROW_DURATION)               — throw animation
//   [THROW_DURATION, +DRAW_DURATION)  — pull-out-the-next-grenade
//                                       (DRAW frames, mirrors snowball)
// Last-grenade throws skip the deploy phase — the auto-switch tail in
// W_HLGrenadeFrame fires immediately so the player isn't left waving
// an empty hand for the draw animation.
float(float now) SH_HLGrenadeTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= HLGREN_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    // WS_SPECIAL (pin pull) doesn't auto-transition — the cook can run
    // indefinitely.  The fuse is anchored to the pin-pull moment via
    // .altfire_finished, so over-cooking just shortens the airborne
    // portion of the fuse on release (down to zero).
    if (self.weaponstate == WS_SPECIAL)
        return 0;

    if (self.weaponstate == WS_FIRE)
    {
        float fire_total = HLGREN_THROW_DURATION;
        if (self.ammo_hlgrenade > 0)
            fire_total = fire_total + HLGREN_DRAW_DURATION;
        if (elapsed >= fire_total)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// +attack pressed: pull pin (enter WS_SPECIAL)
// Returns: 1 = pin pulled, -1 = dry fire, 0 = blocked
float(float now) SH_HLGrenadeTryPinPull =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_hlgrenade <= 0)
    { self.attack_finished = now + HLGREN_DRYFIRE_DELAY; return -1; }

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    // Store pin pull start time in altfire_finished for throw velocity calculation
    self.altfire_finished = now;
    return 1;
};

// +attack released: throw grenade (enter WS_FIRE).  Returns 1 on a
// successful release, 0 if not in pin-pull state.  Velocity is fixed
// in W_HLGrenadeFrame's spawn branch so no value needs to flow forward
// from here — the pin-pull timestamp lives on .altfire_finished and is
// read at spawn time to anchor the grenade's detonation.
float(float now) SH_HLGrenadeThrow =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_SPECIAL) return 0;

    self.ammo_hlgrenade  -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + 1.5;   // prevent re-pull while button held

    // If that was the last grenade, move the active utility pointer to
    // the next utility item right away so a death mid-throw can't leak an
    // empty-grenade pickup. The actual weapon-switch to whatever's next
    // happens at throw-anim end.
    if (self.ammo_hlgrenade <= 0)
        self.slot_utility = W_UtilityNextAfterSpent(WEP_HLGRENADE);

    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_HLGrenadePickupCopy =
{ player.ammo_hlgrenade = self.ammo_hlgrenade; };

// Hand grenade explosion — radius damage
void() W_HLGrenadeExplode =
{
    // Sole FX source for non-shooter clients: sprite + particles +
    // light + boom. Server no longer calls te_explosion or sound() —
    // dimension_send doesn't actually filter multicasts/temp-entities
    // for an owner-exclude in this codebase, so anything routed that
    // way leaked to the shooter ~ping ms after their predicted boom.
    // Instead we write the shooter's entnum as an exclude byte and the
    // CSQC handler skips itself when it matches player_localentnum
    // (matches CSQC_EVENT_WEAPON_PICKUP_SOUND / BREAKABLE_*_SOUND
    // pattern). Shooter handles FX via CSQC_FakeHLGrenadeExplode.
    float snd = random();
    float snd_idx = (snd < 0.333) ? 0 : (snd < 0.666 ? 1 : 2);
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_GRENADE_EXPLODE);
    WriteByte(MSG_MULTICAST, self.owner ? num_for_edict(self.owner) : 0);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z + 8);
    WriteByte(MSG_MULTICAST, snd_idx);
    multicast(self.origin, MULTICAST_PVS);

    // Radius damage + player knockback + phys-drop blast — single call.
    W_RadiusExplode(self.origin, HLGREN_EXPLOSION_RADIUS,
                    HLGREN_EXPLOSION_DAMAGE, HLGREN_EXPLOSION_MIN_DAMAGE,
                    HLGREN_KNOCKBACK_PUSH, HLGREN_KNOCKBACK_UPLIFT, self.owner);

    remove(self);
};

void() W_HLGrenadeThink =
{
    W_HLGrenadeExplode();   // fuse expired
};

// Periodic tick wrapper — runs at sv_toss_tickrate during the entire
// grenade lifetime to (a) drive CSQC SendFlags pulses for smooth flight
// and (b) trigger detonation when the absolute fuse time hits. Replaces
// the one-shot W_HLGrenadeThink/nextthink pattern at the spawn site.
void() W_HLGrenadeProjectileTick =
{
    self.SendFlags |= 1;
    if (time >= self.proj_fuse_end)
    {
        W_HLGrenadeExplode();   // removes self
        return;
    }
    self.nextthink = time + Toss_NextThinkInterval();
};

void() W_HLGrenadeBounce =
{
    // Bounce sound — only on world/bsp (not on players). Routed through
    // CSQC_EVENT_GRENADE_BOUNCE with the shooter's entnum as exclude
    // byte (matches CSQC_EVENT_WEAPON_PICKUP_SOUND / BREAKABLE_*_SOUND
    // pattern in this codebase — dimension_send doesn't actually filter
    // multicasts the way you'd expect, so an explicit entnum compare on
    // the CSQC side is the only thing that reliably hides the bounce
    // from the shooter). Shooter plays their own bounces locally via
    // CSQC_FakeHLGrenadeBounce.
    if (other.classname != "player")
    {
        float snd = random();
        float snd_idx = (snd < 0.333) ? 0 : (snd < 0.666 ? 1 : 2);
        WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
        WriteByte(MSG_MULTICAST, CSQC_EVENT_GRENADE_BOUNCE);
        WriteByte(MSG_MULTICAST, self.owner ? num_for_edict(self.owner) : 0);
        WriteCoord(MSG_MULTICAST, self.origin_x);
        WriteCoord(MSG_MULTICAST, self.origin_y);
        WriteCoord(MSG_MULTICAST, self.origin_z);
        WriteByte(MSG_MULTICAST, snd_idx);
        multicast(self.origin, MULTICAST_PVS);
    }
};

void() W_HLGrenadeFire =
{
    float r;

    r = SH_HLGrenadeTryPinPull(time);
    if (r == 1)
    {
        self.weaponframe = HLGREN_PIN_START;
        self.wep_nextframe = time + HLGREN_FRAME_INTERVAL;
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_HLGrenadeRelease =
{
    if (!SH_HLGrenadeThrow(time)) return;

    self.weaponframe   = HLGREN_THROW_START;
    self.wep_nextframe = time + HLGREN_THROW_INTERVAL;

    // Mark the grenade entity as pending — W_HLGrenadeFrame's WS_FIRE
    // branch spawns it after HLGREN_THROW_DELAY.  The actual fuse is
    // derived at spawn time from self.altfire_finished (pin-pull time)
    // so no hold-time value needs to be stashed here.
    self.hlgren_throw_vel  = 1;
    self.hlgren_spawn_time = time + HLGREN_THROW_DELAY;
};

void() W_HLGrenadeFrame =
{
    float result;

    if (self.weaponstate == WS_SPECIAL)
    {
        // Pin pull animation — advance frames, clamp at end but keep ticking
        self.weaponframe += 1;
        self.wep_nextframe += HLGREN_FRAME_INTERVAL;
        if (self.weaponframe >= HLGREN_PIN_END)
            self.weaponframe = HLGREN_PIN_END;

        // Check for primary fire release — throw the grenade
        if (!self.button0)
            W_HLGrenadeRelease();
        return;
    }

    if (self.weaponstate == WS_FIRE)
    {
        // Spawn grenade entity after the throw delay
        if (self.hlgren_throw_vel > 0 && time >= self.hlgren_spawn_time)
        {
            entity gren;
            self.hlgren_throw_vel = 0;  // only spawn once

            makevectors(self.v_angle);
            gren = spawn();
            gren.owner = self;
            gren.classname = "proj_hlgrenade";
            gren.movetype = MOVETYPE_TOSS;
            gren.solid = SOLID_BBOX;
            setmodel(gren, HLGREN_GRENADE_MODEL);
            setsize(gren, '-2 -2 -2', '2 2 2');
            setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
            gren.velocity = self.velocity
                          + v_forward * HLGREN_THROW_FORWARD
                          + v_up      * HLGREN_THROW_UPWARD;
            gren.avelocity = '180 360 120';
            gren.gravity = 0.5;
            gren.touch = W_HLGrenadeBounce;
            // CSQC replication via projectile_SendEntity (sv_weapons.qc):
            // shooter is hidden by SendEntity returning FALSE, others get
            // origin+velocity+avelocity at sv_toss_tickrate for smooth
            // flight via cl_tosssmooth.qc extrap+smooth.
            gren.proj_type   = PROJ_TYPE_HLGRENADE;
            gren.SendEntity  = projectile_SendEntity;
            gren.SendFlags   = 1;
            // Absolute fuse anchor (pin-pull moment + HLGREN_FUSE_TIME).
            // The periodic-tick wrapper detonates when time >= proj_fuse_end,
            // so cooking the grenade eats into airborne fuse exactly the
            // same way the previous one-shot nextthink did.
            gren.proj_fuse_end = self.altfire_finished + HLGREN_FUSE_TIME;
            // "Favor the thrower": subtract owner ping so the explosion
            // arrives at the shooter's screen at the same wall-clock
            // moment their CSQC_FakeHLGrenadeExplode prediction detonates.
            // Other PVS clients see the explosion ~ping ms earlier than
            // they would naturally — small artifact, big win for the
            // high-ping thrower's sense of agency.
            gren.proj_fuse_end -= stof(infokey(self, "ping")) * 0.001;
            if (gren.proj_fuse_end <= time + 0.01)
                gren.proj_fuse_end = time + 0.01;
            gren.think     = W_HLGrenadeProjectileTick;
            gren.nextthink = time + Toss_NextThinkInterval();
        }

        // Throw animation frame advance
        self.wep_nextframe += HLGREN_THROW_INTERVAL;
        self.weaponframe   += 1;
    }
    else
    {
        // Idle wrap — the model's "no-arms rest" pose is frames
        // 80..125 inclusive. Letting weaponframe walk past 125
        // emits engine warnings ("Too high frame 126
        // (models/weapons/wpn_hlgrenade/v_grenade.mdl)") and may
        // render undefined. Wrap back to HLGREN_IDLE_START.
        self.weaponframe += 1;
        if (self.weaponframe > HLGREN_IDLE_END)
            self.weaponframe = HLGREN_IDLE_START;
        self.wep_nextframe += HLGREN_FRAME_INTERVAL;
    }

    result = SH_HLGrenadeTickState(time);
    if (result & 1)
    {
        self.weaponframe   = HLGREN_IDLE_FRAME;
        self.wep_nextframe = 0;

        // Throw anim ended with the slot already cleared by the empty-
        // ammo branch in SH_HLGrenadeThrow — wipe the SSQC-only equip /
        // drop function pointers and switch the player to whatever's next
        // in their loadout. Without this they'd be left "holding" an
        // invisible grenade until another weapon is selected manually.
        if (self.ammo_hlgrenade <= 0 && self.weapon == WEP_HLGRENADE)
        {
            // See sh_wpn_csgrenades.qc — explicit fallback chain matches
            // CSQC prediction so the empty grenade can't stick visually.
            if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
            else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
            else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
        }
    }
};

void() W_HLGrenadeEquip =
{
    W_StandardEquipSetup(HLGREN_VIEWMODEL, HLGREN_DISPLAY_NAME, HLGREN_DRAW_START,
        HLGREN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire       = W_HLGrenadeFire;
    self.reload     = __NULL__;
    self.wepframe   = W_HLGrenadeFrame;
    self.hlgren_throw_vel = 0;
    self.hlgren_spawn_time = 0;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_HLGrenadeDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_hlgrenade = self.ammo_hlgrenade;
    self.ammo_hlgrenade = 0;

    setmodel(tgt, HLGREN_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_hlgrenade";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLGRENADE;
    tgt.weapon_slot  = SLOT_UTILITY;
    tgt.weap_draw    = W_HLGrenadeEquip;
    tgt.weap_drop_func = W_HLGrenadeDrop;
    tgt.pickupcopy   = W_HLGrenadePickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlgrenade =
{
    setmodel(self, HLGREN_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_hlgrenade";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLGRENADE;
    self.weapon_slot   = SLOT_UTILITY;
    self.weap_draw     = W_HLGrenadeEquip;
    self.weap_drop_func = W_HLGrenadeDrop;
    self.pickupcopy    = W_HLGrenadePickupCopy;
    self.touch         = weapon_touch;
    self.ammo_hlgrenade = MAX_AMMO_HLGRENADE;
    W_RegisterMapWeapon(weapon_hlgrenade);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Forward — CSQC_PredictSelectWeapon lives in client/cl_weapons.qc which
// compiles AFTER this file. Used by the auto-switch tail in
// CSQC_PredictHLGrenadeCommand to drop the grenade slot once the last
// throw completes.
void(float new_weapon) CSQC_PredictSelectWeapon;

// --- Fake grenade projectile (CSQC-only, shooter visual) ---
//
// The server's W_HLGrenadeFrame spawns the real projectile with
// nodrawtoclient = self, so the shooter never sees it. This fake mirrors
// the same physics (MOVETYPE_TOSS, gravity 0.5, avelocity, bbox) and the
// fuse-anchored-to-pin-pull behavior so the predicted explosion lands at
// the same time + place the server's truth will. Other players see only
// the server entity; the shooter sees only this fake.

void() CSQC_FakeHLGrenadeExplode =
{
    // Randomized explosion sound — matches the SSQC W_HLGrenadeExplode
    // sample variety so the predicted boom on the shooter and the
    // server's broadcast on everyone else feel like the same weapon.
    string s;
    float r = random();
    if      (r < 0.333) s = "sounds/weapons/wpn_hlgrenade/explode1.wav";
    else if (r < 0.666) s = "sounds/weapons/wpn_hlgrenade/explode2.wav";
    else                s = "sounds/weapons/wpn_hlgrenade/explode3.wav";
    pointsound(self.origin, s, 1, ATTN_NORM);

    // te_explosion in CSQC only emits particles + sound — the classic
    // Quake explode sprite has to be spawned explicitly.
    vector epos = self.origin + '0 0 8';
    te_explosion(epos);
    CSQC_SpawnExplodeSprite(epos);
    CSQC_SpawnScorchDecal(epos, 2);
    // Brighter dynamic light — same call the CSQC_EVENT_GRENADE_EXPLODE
    // handler runs for non-shooters, so every viewer (shooter via this
    // predict path, others via the server multicast) sees the identical
    // light pulse.
    CSQC_AddExplosionLight(epos);
    remove(self);
};

void() CSQC_FakeHLGrenadeBounce =
{
    // Bounce sound on world / brush only. Skip the shooter (== owner)
    // and any player ent — server's W_HLGrenadeBounce uses the same
    // "not on player" gate. Randomized to match SSQC variety.
    if (other == self.owner) return;
    if (other.entnum >= 1 && other.entnum <= maxclients) return;
    string s;
    float r = random();
    if      (r < 0.333) s = "sounds/weapons/wpn_hlgrenade/hit1.wav";
    else if (r < 0.666) s = "sounds/weapons/wpn_hlgrenade/hit2.wav";
    else                s = "sounds/weapons/wpn_hlgrenade/hit3.wav";
    pointsound(self.origin, s, 1, ATTN_NORM);
};

// --- Pin-pull / throw / spawn prediction ---

void() CSQC_PredictHLGrenadeCommand =
{
    float r;

    // +attack: pin pull (or dry-fire if no ammo). attack_finished gating
    // inside SH_HLGrenadeTryPinPull stops replay re-firing.
    if (input_buttons & 1)
    {
        r = SH_HLGrenadeTryPinPull(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            // Server's W_HLGrenadeFire plays no pin-pull sound, so we
            // don't predict one either. Animation alone signals the pull.
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

    // +attack release while in WS_SPECIAL: throw. Mirrors W_HLGrenadeFrame's
    // !self.button0 check. SH_HLGrenadeThrow decrements ammo on both sides
    // through the shared code path so no separate predict-decrement is
    // needed (reset-and-replay restores authoritative count each reconcile).
    if (self.weaponstate == WS_SPECIAL && !(input_buttons & 1))
    {
        if (SH_HLGrenadeThrow(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            // Stamp the same spawn-delay clock the server uses so the
            // fake projectile appears at the same elapsed moment.
            self.hlgren_throw_vel  = 1;
            self.hlgren_spawn_time = csqc_pred_time + HLGREN_THROW_DELAY;
        }
    }

    // Spawn the fake projectile after the throw delay — mirrors the SSQC
    // W_HLGrenadeFrame WS_FIRE branch.
    //
    // Two stacked single-spawn guards needed:
    //   1. hlgren_throw_vel = 0 after spawn — blocks re-spawn within the
    //      same tick.
    //   2. hlgren_fake_spawned_serial == wep_action_id — blocks re-spawn
    //      across ticks once a fake for THIS throw exists. Under high
    //      ping the unack'd throw cmd replays every reconcile tick, and
    //      each replay's SH_HLGrenadeThrow re-sets hlgren_throw_vel=1.
    //      Without the serial check, the live frame after each replay
    //      would pump out another fake — visibly two-or-more grenades
    //      bouncing for the thrower until the throw acks.
    //
    // pm_suppress_sounds also gates this so replay frames themselves
    // never spawn (only the live frame should). wep_action_id is bumped
    // exactly once in SH_HLGrenadeThrow per throw and is preserved
    // across reconcile (not in the confirmed-state buffers), so it's
    // a stable per-throw identity.
    if (self.weaponstate == WS_FIRE
        && self.hlgren_throw_vel > 0
        && csqc_pred_time >= self.hlgren_spawn_time
        && !pm_suppress_sounds
        && self.hlgren_fake_spawned_serial != self.wep_action_id)
    {
        self.hlgren_throw_vel = 0;
        self.hlgren_fake_spawned_serial = self.wep_action_id;

        entity gren = spawn();
        makevectors(input_angles);
        setmodel(gren, HLGREN_GRENADE_MODEL);
        setsize(gren, '-2 -2 -2', '2 2 2');
        setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
        gren.owner     = self;
        gren.velocity  = self.velocity
                       + v_forward * HLGREN_THROW_FORWARD
                       + v_up      * HLGREN_THROW_UPWARD;
        gren.avelocity = '180 360 120';
        gren.movetype  = MOVETYPE_TOSS;
        gren.solid     = SOLID_BBOX;
        gren.gravity   = 0.5;
        gren.drawmask  = MASK_ENGINE;
        gren.touch     = CSQC_FakeHLGrenadeBounce;
        gren.think     = CSQC_FakeHLGrenadeExplode;
        // Tag fake so cl_throwtrail's find() iterator picks it up
        // alongside the server-replicated csqc_projectile entities.
        gren.classname             = "csqc_projectile";
        gren.csqc_projectile_type  = PROJ_TYPE_HLGRENADE;
        // Anchor detonation to the pin-pull moment — matches the SSQC
        // W_HLGrenadeFrame anchor (gren.nextthink = altfire_finished + 5).
        //
        // CRITICAL: nextthink must be in engine `time` units (the domain
        // FTE uses to tick CSQC entity thinks). altfire_finished was
        // stamped from csqc_pred_time (= cltime) which can drift ahead
        // of `time` by a frame's worth at high client framerate — using
        // it directly made the fake explode ~1s after the server at
        // zero ping. Compute remaining fuse in the cltime domain (same
        // anchor) then add to `time`.
        float remaining_fuse = HLGREN_FUSE_TIME - (csqc_pred_time - self.altfire_finished);
        if (remaining_fuse < 0.01) remaining_fuse = 0.01;
        gren.nextthink = time + remaining_fuse;
    }

    float was_fire = (self.weaponstate == WS_FIRE);
    SH_HLGrenadeTickState(csqc_pred_time);

    // Mirror the SSQC W_HLGrenadeFrame's auto-switch tail. Once the throw
    // animation rolls over to WS_IDLE we switch to the next available weapon
    // so the predicted viewmodel doesn't briefly hold an empty grenade.
    if (was_fire && self.weaponstate == WS_IDLE
        && self.ammo_hlgrenade <= 0
        && self.weapon == WEP_HLGRENADE)
    {
        if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
        else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
        else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
        else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
    }
};

float(float elapsed) CSQC_HLGrenadeDisplayFrame =
{
    float frame;

    if (predicted_player.weaponstate == WS_DRAW)
    {
        frame = HLGREN_DRAW_START + elapsed / HLGREN_FRAME_INTERVAL;
        return bound(HLGREN_DRAW_START, frame, HLGREN_DRAW_END - 1);
    }
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // Pin pull animation — clamp at end
        frame = HLGREN_PIN_START + elapsed / HLGREN_FRAME_INTERVAL;
        return bound(HLGREN_PIN_START, frame, HLGREN_PIN_END);
    }
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Two-phase display while WS_FIRE is held (see
        // SH_HLGrenadeTickState comment for the timing window):
        //   [0, THROW_DURATION)              → THROW frames (release)
        //   [THROW_DURATION, +DRAW_DURATION) → DRAW frames (pull-the-next)
        // The DRAW phase only matters when ammo > 0 — the tick
        // state exits WS_FIRE early on the last grenade so we never
        // hit this branch with an empty hand.
        if (elapsed >= HLGREN_THROW_DURATION)
        {
            float draw_elapsed = elapsed - HLGREN_THROW_DURATION;
            frame = HLGREN_DRAW_START + draw_elapsed / HLGREN_FRAME_INTERVAL;
            return bound(HLGREN_DRAW_START, frame, HLGREN_DRAW_END - 1);
        }
        // Single throw animation — no charge tiers any more.
        frame = HLGREN_THROW_START + elapsed / HLGREN_THROW_INTERVAL;
        return bound(HLGREN_THROW_START, frame, HLGREN_THROW_END - 1);
    }

    // Idle: loop frames 80..125 so the empty-hand viewmodel gently
    // animates instead of freezing on a single frame (csknife's idle
    // does this via GoldSrc sequence playback; Quake MDL has no built-in
    // looping so we step the frame manually here). Use cltime as the
    // anchor — wep_anim_start gets reset to 0 on entering idle so
    // `elapsed` would jump to a huge number on first idle tick anyway,
    // and cltime never resets so the loop stays continuous across
    // weapon-state changes.
    float idle_count = HLGREN_IDLE_END - HLGREN_IDLE_START + 1;
    float idle_step  = floor(cltime * (1.0 / HLGREN_FRAME_INTERVAL));
    float idle_idx   = idle_step - floor(idle_step / idle_count) * idle_count;
    return HLGREN_IDLE_START + idle_idx;
};

void() CSQC_HLGrenadeDropClear =
{
	self.ammo_hlgrenade = 0;
};

void() CSQC_HLGrenadeEquip =
{
	self.weapon_name         = HLGREN_DISPLAY_NAME;
	self.weapon_viewmodel    = HLGREN_VIEWMODEL;
	self.weapon_worldmodel   = HLGREN_WORLDMODEL;
	self.weapon_deploy_sound = HLGREN_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictHLGrenadeCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_HLGrenadeDisplayFrame;
	self.csqc_drop_clear     = CSQC_HLGrenadeDropClear;
};

#endif // CSQC
