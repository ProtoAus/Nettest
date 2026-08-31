// ============================================================
//  shared/weapons/sh_wpn_thm16a1.qc  -  They Hunger M16A1
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 20-round magazine, 600 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : 3-round burst (WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_m16a1.as and
//  hunger/weapons/m16a1/v_m16.mdl.  Previously a pickup alias onto WEP_HLSMG,
//  which gave it an M203 it does not have and lost the burst it does.
//
//  NB the model collision that sv_goldsrc_pickups.qc already documents: THIS
//  m16 is models/hunger/weapons/m16a1/w_m16.mdl, and Sven Co-op's own
//  weapon_m16 is models/w_m16.mdl.  Same basename, two different guns, both
//  mounted.  The full path is what keeps them apart.

// --- Ammo fields ---
.float mag_thm16;
.float ammo_thm16;

// Burst state.  Player fields, not globals: the same shared tick runs on the
// server and inside CSQC prediction, and each needs its own count.
.float thm16_burst_count;   // rounds still queued in the current burst (0 = not bursting)
.float thm16_burst_next;    // time the next queued round goes off

// Server-side reload sound latch; CSQC keeps its own single global.
.float thm16_reload_snd_stage;

// --- Sequence indices, out of hunger/weapons/m16a1/v_m16.mdl (6 seqs) -------
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
//
// Indices match TheyHungerM16A1Animation_e (weapon_m16a1.as:18-26).  NONE of
// the six carries STUDIO_LOOPING.
const float THM16_SEQ_IDLE_FIDGET   = 0;   // idle_fidget,  2.700 s  ( 82f @ 30)
const float THM16_SEQ_IDLE          = 1;   // idle,         3.367 s  (102f @ 30)
const float THM16_SEQ_RELOAD        = 2;   // reload,       2.033 s  ( 62f @ 30)
const float THM16_SEQ_RELOAD_EMPTY  = 3;   // reload_empty, 2.533 s  ( 77f @ 30)
const float THM16_SEQ_DEPLOY        = 4;   // deploy,       0.533 s  ( 17f @ 30)
const float THM16_SEQ_SHOOT         = 5;   // fire,         1.017 s  ( 62f @ 60)

const float THM16_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate
const float THM16_FIRE_DELAY        = 0.14;   // weapon_m16a1.as:258

// Burst cadence, weapon_m16a1.as:282 / :340 — the first round goes off with
// the trigger, the second 0.055 s later, the third 0.1 s after that; :284 then
// locks BOTH triggers out for 0.5 s.
const float THM16_BURST_FIRST_GAP   = 0.055;
const float THM16_BURST_GAP         = 0.1;
const float THM16_BURST_COOLDOWN    = 0.5;

// Idle re-send cadence — weapon_m16a1.as:257.  No looping sequence exists in
// this model, so SH_SeqIdleDisplay has to re-send one or the viewmodel clamps
// to a still frame (gl_hlmdl.c:1076-1082).
const float THM16_IDLE_REARM_MIN    = 10;
const float THM16_IDLE_REARM_MAX    = 15;

// Reload sound instants, elapsed from wep_anim_start.  Only the empty reload
// has a bolt to release.
const float THM16_RELOAD_MAGOUT_TIME = 0.300;
const float THM16_RELOAD_MAGIN_TIME  = 1.200;
const float THM16_RELOAD_BOLT_TIME   = 2.100;   // reload_empty only

const float MAX_MAG_THM16           = 20;    // M16A1_MAX_CLIP,  weapon_m16a1.as:15
// M16A1_MAX_CARRY IS 600 IN weapon_m16a1.as:13 AND 600 DOES NOT FIT ON THE WIRE.
// The proxy ships slot_primary_ammo as a single byte (server/sv_player.qc:2378,
// read back at client/cl_player.qc:6128), and the engine MASKS rather than
// clamps an out-of-range WriteByte (pr_cmds.c:5271-5274, 5304) — so 600 & 255
// arrived as 88.  This was the only manifest row in all 147 with a mag, ammo or
// aux value above 255, which is why nothing else showed it.
//
// It was not merely a wrong HUD number: the section is rewritten on every ammo
// change, so the client was re-corrupted to 88 every snapshot and CSQC's shared
// try-fire gates ran against 88 while the server ran against 600.  Capping the
// value keeps client and server agreeing; widening the field to a short would
// also work but is a lock-step change across six read/write sites plus a
// PM_CSQC_PROXY_VERSION bump, for one weapon.  250 is what every other They
// Hunger gun already carries (sh_wpn_th1911.qc:94, thtommygun.qc:56,
// thgreasegun.qc:54).
//
// MUST move together with the manifest row (sh_weapon_manifest.qc:640):
// Ammo_TopUpWeapon caps at WeaponManifest_DefaultAmmo (sv_goldsrc_ammo.qc:206),
// so a manifest still holding 600 would let an ammo box push it back over 255.
const float MAX_AMMO_THM16          = 250;   // was M16A1_MAX_CARRY 600 — see above

// --- Balance ---
// weapon_m16a1.as:170 fires VECTOR_CONE_1DEGREES flat.  HL's cone constants
// are the sine of the half angle per axis, the same unit this mod's spread
// argument uses, so the constant carries across; the move spread is this
// mod's own addition.
const float THM16_BASE_SPREAD          = 0.00873;   // VECTOR_CONE_1DEGREES
const float THM16_BURST_SPREAD         = 0.02;      // burst walks off target — this mod's own
const float THM16_MOVE_SPREAD          = 0.055;
const float THM16_FULL_SPREAD_SPEED    = 320;
// :170 fires BULLET_PLAYER_SAW, a Sven Co-op skill value with no counterpart
// in this mod (there is no sk_plr_556 in any mounted skill.cfg), so the number
// comes from the mod's own 5.56 rifle instead — the M4A1 at 24/14 — trimmed a
// little for a 20-round magazine.
const float THM16_CLOSE_DAMAGE         = 22;
const float THM16_MIN_DAMAGE           = 13;
const float THM16_DAMAGE_FALLOFF_RANGE = 3072;
const float THM16_DRYFIRE_DELAY        = 0.2;
const float THM16_KICK_PITCH    = 0.8;   // sv_gunkick
const float THM16_KICK_VARIANCE = 0.35;
const float THM16_KICK_STRENGTH = 1.6;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float THM16_MUZZLE_FORWARD = 46;
const float THM16_MUZZLE_RIGHT   = 4.5;
const float THM16_MUZZLE_DOWN    = 6.5;

// --- State durations, taken from the sequences themselves ---
const float THM16_DRAW_DURATION         = 0.533;   // deploy
const float THM16_FIRE_DURATION         = 1.017;   // fire
const float THM16_RELOAD_DURATION       = 2.033;   // reload
const float THM16_RELOAD_EMPTY_DURATION = 2.533;   // reload_empty

const string THM16_VIEWMODEL    = "models/hunger/weapons/m16a1/v_m16.mdl";
const string THM16_WORLDMODEL   = "models/hunger/weapons/m16a1/w_m16.mdl";
const string THM16_DEPLOY_SOUND = "";
const string THM16_DISPLAY_NAME = "M16A1";

// ============================================================
//  SHARED — state machine
// ============================================================

// Which reload is playing, and therefore how long WS_RELOAD lasts.  Keyed off
// the magazine, which is replicated and reads the same on both sides, rather
// than .weaponframe, which no file under client/ can see.
float() SH_THM16ReloadDuration =
{
    if (self.mag_thm16 > 0)
        return THM16_RELOAD_DURATION;
    return THM16_RELOAD_EMPTY_DURATION;
};

float(float now) SH_THM16TickState =
{
    float elapsed;

    // WS_SPECIAL = a burst is playing.  The model has only one fire sequence,
    // so a burst looks like a shot; what differs is the state, which is what
    // keeps the queued rounds and the cooldown apart from single fire.
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= THM16_FIRE_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    float rel = SH_THM16ReloadDuration();
    return SH_StandardTickState(now, mag_thm16, ammo_thm16, MAX_MAG_THM16,
        THM16_DRAW_DURATION, THM16_FIRE_DURATION, rel, rel);
};

float(float now) SH_THM16TryFire =
{
    // Do not interrupt a burst that still has rounds queued — but a FINISHED
    // burst is not a block, only attack_finished is.  weapon_m16a1.as:284 sets
    // m_flNextPrimaryAttack and m_flNextSecondaryAttack to the same +0.5 s, so
    // the two triggers share one cooldown, which attack_finished already is.
    if (self.thm16_burst_count > 0)
        return 0;
    return SH_StandardTryFire(now, mag_thm16, THM16_FIRE_DELAY, THM16_DRYFIRE_DELAY);
};

float(float now) SH_THM16TryReload =
{
    float r = SH_StandardTryReload(now, mag_thm16, ammo_thm16, MAX_MAG_THM16,
                                   SH_THM16ReloadDuration());
    if (r == 1)
        self.thm16_burst_count = 0;   // .as:301 clears m_iBurstLeft on reload
    return r;
};

// Start a burst.  Returns 1 = started, -1 = dry, 0 = blocked.
// The first round goes off here; the rest are queued for the frame tick.
float(float now) SH_THM16TryBurst =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW) return 0;
    if (self.thm16_burst_count > 0) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_thm16 <= 0)
    {
        self.attack_finished = now + THM16_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + THM16_DRYFIRE_DELAY;
#endif
        return -1;
    }

    // .as:280 — `m_iBurstCount = min(3, m_iClip)`, so a burst with one or two
    // rounds left fires only what is there rather than dry-clicking the rest.
    float queued = 2;
    if (self.mag_thm16 - 1 < queued)
        queued = self.mag_thm16 - 1;

    self.mag_thm16       -= 1;
    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.thm16_burst_count = queued;
    self.thm16_burst_next  = now + THM16_BURST_FIRST_GAP;
    self.attack_finished   = now + THM16_BURST_COOLDOWN;
#ifdef CSQC
    self.csqc_fire_guard   = self.attack_finished;
#endif
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THM16PickupCopy =
{
    player.mag_thm16  = self.mag_thm16;
    player.ammo_thm16 = self.ammo_thm16;
};

void() W_THM16Shoot =
{
    W_PenetratingHitscanShoot(THM16_BASE_SPREAD, THM16_MOVE_SPREAD, THM16_FULL_SPREAD_SPEED,
        THM16_CLOSE_DAMAGE, THM16_MIN_DAMAGE, THM16_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        THM16_KICK_PITCH, THM16_KICK_VARIANCE, THM16_KICK_STRENGTH);
};

void() W_THM16BurstShoot =
{
    W_PenetratingHitscanShoot(THM16_BURST_SPREAD, THM16_MOVE_SPREAD, THM16_FULL_SPREAD_SPEED,
        THM16_CLOSE_DAMAGE, THM16_MIN_DAMAGE, THM16_DAMAGE_FALLOFF_RANGE, 32, 0.96,
        THM16_KICK_PITCH, THM16_KICK_VARIANCE, THM16_KICK_STRENGTH);
};

// .as:196-200 rolls one of three fire wavs per shot.
void() W_THM16FireSound =
{
    float r = random();
    if (r < 0.333)
        sound(self, CHAN_WEAPON, "hunger/weapons/m16a1/m16_fire1.wav", 1, ATTN_NORM);
    else if (r < 0.666)
        sound(self, CHAN_WEAPON, "hunger/weapons/m16a1/m16_fire2.wav", 1, ATTN_NORM);
    else
        sound(self, CHAN_WEAPON, "hunger/weapons/m16a1/m16_fire3.wav", 1, ATTN_NORM);
};

void() W_THM16Fire =
{
    float r = SH_THM16TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = THM16_SEQ_SHOOT;
        self.wep_nextframe = time + THM16_FRAME_INTERVAL;

        W_THM16Shoot();
        W_THM16FireSound();
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THM16AltFire =
{
    float r = SH_THM16TryBurst(time);

    if (r == 1)
    {
        self.weaponframe   = THM16_SEQ_SHOOT;
        self.wep_nextframe = time + THM16_FRAME_INTERVAL;

        W_THM16BurstShoot();
        // .as:287-294 — the three-round burst has its own one-shot wav, but a
        // short burst (fewer than three rounds left) falls back to the
        // individual fire sounds.
        if (self.thm16_burst_count >= 2)
            sound(self, CHAN_WEAPON, "hunger/weapons/m16a1/m16_burst.wav", 1, ATTN_NORM);
        else
            W_THM16FireSound();
        W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_THM16Reload =
{
    if (SH_THM16TryReload(time))
    {
        self.weaponframe   = (self.mag_thm16 > 0) ? THM16_SEQ_RELOAD
                                                  : THM16_SEQ_RELOAD_EMPTY;
        self.wep_nextframe = time + THM16_FRAME_INTERVAL;
        self.thm16_reload_snd_stage = 0;
    }
};

void() W_THM16Frame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += THM16_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        if (self.thm16_reload_snd_stage < 1 && reload_elapsed >= THM16_RELOAD_MAGOUT_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/m16a1/m16_magout.wav", 1, ATTN_NORM);
            self.thm16_reload_snd_stage = 1;
        }
        if (self.thm16_reload_snd_stage < 2 && reload_elapsed >= THM16_RELOAD_MAGIN_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/m16a1/m16_magin.wav", 1, ATTN_NORM);
            self.thm16_reload_snd_stage = 2;
        }
        if (self.thm16_reload_snd_stage < 3 && reload_elapsed >= THM16_RELOAD_BOLT_TIME
            && self.weaponframe == THM16_SEQ_RELOAD_EMPTY)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/m16a1/m16_boltcatch.wav", 1, ATTN_NORM);
            self.thm16_reload_snd_stage = 3;
        }
    }

    // Queued burst rounds.  Deliberately outside the weaponstate test — .as's
    // ItemPostFrame runs this ahead of everything else and lets the burst
    // finish whatever else the player asked for.
    if (self.thm16_burst_count > 0 && time >= self.thm16_burst_next)
    {
        if (self.mag_thm16 > 0)
        {
            self.mag_thm16 -= 1;
            self.wep_action_id += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            W_THM16BurstShoot();
            W_ShellEffect(SHELL_RIFLE, '8 6 -4', '6 46 36', '240 720 120');
        }
        self.thm16_burst_count -= 1;
        self.thm16_burst_next   = time + THM16_BURST_GAP;
    }

    result = SH_THM16TickState(time);
    if (result & 1)
    {
        self.weaponframe = THM16_SEQ_IDLE;
        // Idle retire — the only legal zero here (sv_weapons.qc:3820).  Held
        // back while a burst is still queued: a zero stops wepframe from being
        // called at all, and the loop above is the only thing that fires the
        // remaining rounds.  The burst finishes 0.155 s in and WS_SPECIAL runs
        // for 1.017 s, so this guard should never be the one that fires — it
        // is here so that shortening the sequence later cannot silently eat
        // two rounds.
        if (self.thm16_burst_count <= 0)
            self.wep_nextframe = 0;
    }
};

void() W_THM16Equip =
{
    W_StandardEquipSetup(THM16_VIEWMODEL, THM16_DISPLAY_NAME, THM16_SEQ_DEPLOY,
        THM16_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_THM16Fire;
    self.altfire  = W_THM16AltFire;
    self.reload   = W_THM16Reload;
    self.wepframe = W_THM16Frame;
    self.shoot    = W_THM16Shoot;
    self.thm16_burst_count = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(THM16_BASE_SPREAD, THM16_MOVE_SPREAD, THM16_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_THM16Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_thm16  = self.mag_thm16;
    tgt.ammo_thm16 = self.ammo_thm16;

    self.mag_thm16  = 0;
    self.ammo_thm16 = 0;
    self.thm16_burst_count = 0;

    setmodel(tgt, THM16_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_m16a1";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_THM16;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_THM16Equip;
    tgt.weap_drop_func = W_THM16Drop;
    tgt.pickupcopy     = W_THM16PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_thm16a1 =
{
    setmodel(self, THM16_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_m16a1";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_THM16;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_THM16Equip;
    self.weap_drop_func = W_THM16Drop;
    self.pickupcopy     = W_THM16PickupCopy;
    self.touch          = weapon_touch;
    self.mag_thm16      = MAX_MAG_THM16;
    self.ammo_thm16     = MAX_AMMO_THM16;
    W_RegisterMapWeapon(weapon_thm16a1);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_thm16_reload_snd_stage;

void() CSQC_THM16FireSound =
{
    float r = random();
    if (r < 0.333)
        localsound("hunger/weapons/m16a1/m16_fire1.wav");
    else if (r < 0.666)
        localsound("hunger/weapons/m16a1/m16_fire2.wav");
    else
        localsound("hunger/weapons/m16a1/m16_fire3.wav");
};

void() CSQC_PredictTHM16Command =
{
    float r;

    if (input_buttons & 4)
    {
        r = SH_THM16TryBurst(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (self.thm16_burst_count >= 2)
                    localsound("hunger/weapons/m16a1/m16_burst.wav");
                else
                    CSQC_THM16FireSound();
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(THM16_BURST_SPREAD, THM16_MOVE_SPREAD, THM16_FULL_SPREAD_SPEED,
                    THM16_CLOSE_DAMAGE, THM16_MIN_DAMAGE, THM16_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    THM16_KICK_PITCH, THM16_KICK_VARIANCE, THM16_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(THM16_MUZZLE_FORWARD, THM16_MUZZLE_RIGHT,
                    THM16_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THM16_MUZZLE_FORWARD, THM16_MUZZLE_RIGHT,
                    THM16_MUZZLE_DOWN, self.wep_action_id, 2);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/dryfire1.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_THM16TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                CSQC_THM16FireSound();
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(THM16_BASE_SPREAD, THM16_MOVE_SPREAD, THM16_FULL_SPREAD_SPEED,
                    THM16_CLOSE_DAMAGE, THM16_MIN_DAMAGE, THM16_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    THM16_KICK_PITCH, THM16_KICK_VARIANCE, THM16_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(THM16_MUZZLE_FORWARD, THM16_MUZZLE_RIGHT,
                    THM16_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(THM16_MUZZLE_FORWARD, THM16_MUZZLE_RIGHT,
                    THM16_MUZZLE_DOWN, self.wep_action_id, 2);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/dryfire1.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Queued burst rounds — the mirror of the block in W_THM16Frame.
    if (self.thm16_burst_count > 0 && csqc_pred_time >= self.thm16_burst_next)
    {
        if (self.mag_thm16 > 0)
        {
            self.mag_thm16 -= 1;
            self.wep_action_id += 1;
            self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
            if (CSQC_BeginFireActionEffects())
            {
                CSQC_PredictedPenetratingImpact(THM16_BURST_SPREAD, THM16_MOVE_SPREAD, THM16_FULL_SPREAD_SPEED,
                    THM16_CLOSE_DAMAGE, THM16_MIN_DAMAGE, THM16_DAMAGE_FALLOFF_RANGE, 32, 0.96,
                    THM16_KICK_PITCH, THM16_KICK_VARIANCE, THM16_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(THM16_MUZZLE_FORWARD, THM16_MUZZLE_RIGHT,
                    THM16_MUZZLE_DOWN, self.wep_action_id);
                CSQC_EndFireActionEffects();
            }
        }
        self.thm16_burst_count -= 1;
        self.thm16_burst_next   = csqc_pred_time + THM16_BURST_GAP;
    }

    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_thm16_reload_snd_stage < 1 && reload_elapsed >= THM16_RELOAD_MAGOUT_TIME)
        {
            localsound("hunger/weapons/m16a1/m16_magout.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thm16_reload_snd_stage = 1;
        }
        if (csqc_thm16_reload_snd_stage < 2 && reload_elapsed >= THM16_RELOAD_MAGIN_TIME)
        {
            localsound("hunger/weapons/m16a1/m16_magin.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thm16_reload_snd_stage = 2;
        }
        if (csqc_thm16_reload_snd_stage < 3 && reload_elapsed >= THM16_RELOAD_BOLT_TIME
            && self.mag_thm16 <= 0)
        {
            localsound("hunger/weapons/m16a1/m16_boltcatch.wav"); CSQC_RecordPredictedAutoSound();
            csqc_thm16_reload_snd_stage = 3;
        }
    }

    SH_THM16TickState(csqc_pred_time);
};

void() CSQC_PredictTHM16Reload =
{
    if (SH_THM16TryReload(csqc_pred_time))
    { csqc_thm16_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_THM16DisplayFrame =
{
    // FIRST, for every state — see sh_weapon_standard.qc.  v_m16.mdl has no
    // looping sequence, so without this the rifle freezes on a still frame.
    float idle = SH_SeqIdleDisplay(cltime, WEP_THM16, predicted_player.weaponstate,
                                   THM16_SEQ_IDLE, THM16_SEQ_IDLE_FIDGET,
                                   THM16_IDLE_REARM_MIN, THM16_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return THM16_SEQ_DEPLOY;
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_thm16 > 0) ? THM16_SEQ_RELOAD
                                                : THM16_SEQ_RELOAD_EMPTY;
    // WS_FIRE and WS_SPECIAL both play the one fire sequence the model has.
    return THM16_SEQ_SHOOT;
};

void() CSQC_THM16DropClear =
{
    self.mag_thm16  = 0;
    self.ammo_thm16 = 0;
    self.thm16_burst_count = 0;
};

void() CSQC_THM16Equip =
{
    self.weapon_name         = THM16_DISPLAY_NAME;
    self.weapon_viewmodel    = THM16_VIEWMODEL;
    self.weapon_worldmodel   = THM16_WORLDMODEL;
    self.weapon_deploy_sound = THM16_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHM16Command;
    self.csqc_predict_reload = CSQC_PredictTHM16Reload;
    self.csqc_display_frame  = CSQC_THM16DisplayFrame;
    self.csqc_drop_clear     = CSQC_THM16DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
