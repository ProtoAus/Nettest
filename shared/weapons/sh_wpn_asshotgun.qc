// ============================================================
//  shared/weapons/sh_wpn_asshotgun.qc  -  pizza_ya_san shortened shotgun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 4-shell magazine, 125 reserve, 9 pellets, buckshot
//  Fire  : lag-compensated pellet hitscan
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop_downloads/scripts/maps/pizza_ya_san/weapon_as_shotgun.as
//  ("HLベース改造ショットガン" — a modified HL shotgun) and
//  svencoop_downloads/models/pizza_ya_san/{v,p,w}_shotgun_shorty.mdl.
//
//  THIS IS A LIVE GAP, NOT POLISH.  pizza_ya_san.as:5 registers
//  `weapon_shotgun -> weapon_as_shotgun` in g_ItemMappings, so EVERY shotgun
//  placed in that map resolves to this classname — and this classname had no
//  spawn function at all, so those placements fell into
//  SV_OnEntityNoSpawnFunction.  server/sv_goldsrc_ammo.qc's dispenser had a
//  one-line rewrite to weapon_shotgun that covered the squadmaker path only.
//
//  Numbers are the script's own (weapon_as_shotgun.as:10-15): 12 given, 125
//  carried, MAX_CLIP 4 — half Half-Life's 8, which is the whole point of a
//  shortened gun — 9 pellets, 15 degree cone, 0.65 s refire, -5.0 punch.
//
//  SECONDARY IS NOT A DOUBLE BARREL.  :236-246 calls PrimaryAttack() and then
//  plays SHOTGUN_FIRE2 and stretches the refire to 1.7 s.  One shell, a heavier
//  animation, a long pause: a cosmetic "big shot", not HL's two-barrel blast.
//  Reproduced as written rather than as the HL shotgun it derives from.

// --- Ammo fields ---
.float mag_asshotgun;
.float ammo_asshotgun;

// --- Sequence indices, read out of pizza_ya_san/v_shotgun_shorty.mdl (10) ----
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).
const float ASSG_SEQ_IDLE          = 0;   // sm_idle,          2.317 s (140f @ 60)  LOOPING
const float ASSG_SEQ_SHOOT         = 1;   // shoot1,           1.050 s  (64f @ 60)
const float ASSG_SEQ_SHOOT2        = 2;   // shoot_FullAUTO,   1.050 s  (64f @ 60)  <- the heavy secondary
const float ASSG_SEQ_RELOAD_MIDDLE = 3;   // reload_middle,    0.467 s  (29f @ 60)
const float ASSG_SEQ_RELOAD_END    = 4;   // reload_end,       0.833 s  (51f @ 60)
const float ASSG_SEQ_RELOAD_START  = 5;   // reload_start,     0.733 s  (45f @ 60)
const float ASSG_SEQ_DRAW          = 6;   // draw,             0.517 s  (32f @ 60)
const float ASSG_SEQ_HOLSTER       = 7;   // reholster — no holster state here
const float ASSG_SEQ_IDLE4         = 8;   // idle4,            2.317 s (140f @ 60)
const float ASSG_SEQ_DEEPIDLE      = 9;   // deepidle,         4.633 s (140f @ 30)  <- :17-29's IDLE_DEEP

const float ASSG_FRAME_INTERVAL = 0.05;

const float ASSG_FIRE_DELAY     = 0.65;   // .as:186-228
const float ASSG_FIRE2_DELAY    = 1.7;    // .as:236-246
const float ASSG_DRYFIRE_DELAY  = 0.3;

const float MAX_MAG_ASSHOTGUN   = 4;      // MAX_CLIP,   .as:12  (HL's is 8)
const float MAX_AMMO_ASSHOTGUN  = 125;    // MAX_CARRY,  .as:11

// Shell-at-a-time reload, which is why the model has start/middle/end rather
// than one animation.  One shell per middle beat.
const float ASSG_RELOAD_START_TIME  = 0.733;
const float ASSG_RELOAD_SHELL_TIME  = 0.467;
const float ASSG_RELOAD_END_TIME    = 0.833;

// --- Balance ---
// 9 pellets in a 15 degree cone, both the script's (.as:14-15).  HL's cone
// constants are the sine of the half angle per axis and this mod's spread scales
// v_right/v_up the same way, so the number carries across unchanged.
const float ASSG_PELLETS              = 9;
const float ASSG_BASE_SPREAD          = 0.13053;   // ~15 degrees
const float ASSG_MOVE_SPREAD          = 0.16;
const float ASSG_FULL_SPREAD_SPEED    = 320;
const float ASSG_CLOSE_DAMAGE         = 14;
const float ASSG_MIN_DAMAGE           = 4;
const float ASSG_DAMAGE_FALLOFF_RANGE = 1280;
// The -5.0 the script punches is a PUNCHANGLE, which GoldSrc decays back over
// several frames; feeding the same number in as this mod's sustained pitch kick
// AND pairing it with a 4.0 strength multiplier made this both the
// highest-pitch and second-highest-strength weapon in the mod — a sawn-off
// kicking harder than the Barrett.  These are now the mod's OWN translation of
// that same -5.0 Half-Life punch, which the HL shotgun already carries as
// 2.5 / 0.6 / 1.5 — so two weapons reading one source value finally agree.
// The variance mattered as much as the pitch: 0.3 was half what every other
// shotgun here uses, making the kick not merely hard but unnaturally
// repeatable — the same direction on every shell.
const float ASSG_KICK_PITCH    = 2.5;      // .as:186-228 punches -5.0 as a decaying punchangle
const float ASSG_KICK_VARIANCE = 0.6;
const float ASSG_KICK_STRENGTH = 1.5;

const float ASSG_MUZZLE_FORWARD = 34;
const float ASSG_MUZZLE_RIGHT   = 4.0;
const float ASSG_MUZZLE_DOWN    = 6.0;

// --- State durations, taken from the sequences themselves ---
const float ASSG_DRAW_DURATION   = 0.517;
const float ASSG_FIRE_DURATION   = 1.050;
// Kept only as the "one shell" reference figure; the live duration is
// SH_ASShotgunReloadDuration(shells), which scales with what is being loaded.
const float ASSG_RELOAD_DURATION = 2.033;   // start + one shell + end

const string ASSG_VIEWMODEL    = "models/pizza_ya_san/v_shotgun_shorty.mdl";
const string ASSG_WORLDMODEL   = "models/pizza_ya_san/w_shotgun_shorty.mdl";
const string ASSG_DEPLOY_SOUND = "weapons/357_cock1.wav";
const string ASSG_DISPLAY_NAME = "SHORTY";

// ============================================================
//  SHARED — state machine
// ============================================================

// Shells this reload will insert, latched at its start — the shorty is a
// shell-at-a-time loader and the reload used to be ONE fixed 2.033 s state
// (start + exactly one middle + end) no matter how many shells actually went
// in, while the magazine refilled completely.  That is the "reload is busted
// visually, but it does actually reload" report.
.float assg_reload_shells;

// Shells CREDITED so far in the reload in flight.  Walked forward one insert at
// a time rather than assigned outright, so a frame hitch longer than one cycle
// (0.467 s against a 0.05 s tick) still banks every round it skipped past —
// same reasoning as .hlsg_reload_stage in the HL shotgun.
.float assg_reload_stage;

// Side-channel outputs of SH_ASShotgunReloadSeq — QC has no multiple return.
// Same arrangement as the HL shotgun, which is the same kind of loader.
float assg_seq_local_time;    // elapsed WITHIN the returned sequence
float assg_seq_shell_index;   // 0-based insert cycle in flight; -1 outside the loop

float(float shells) SH_ASShotgunReloadDuration =
{
    // Never zero-length: a reload entered without prediction (the server-driven
    // path) arrives with shells == 0, and a loop total of 0 would jump straight
    // from start to end with no insert visible at all.
    if (shells < 1) shells = 1;
    return ASSG_RELOAD_START_TIME + shells * ASSG_RELOAD_SHELL_TIME + ASSG_RELOAD_END_TIME;
};

// Resolve "how far into the reload" into "which sequence, how far into IT, and
// which shell".  Driven off total elapsed rather than re-stamping wep_anim_start
// at each boundary, so server and client prediction share one expression and
// cannot drift apart mid-reload.
float(float elapsed, float shells) SH_ASShotgunReloadSeq =
{
    float loop_elapsed, loop_total, idx;

    if (shells < 1) shells = 1;
    assg_seq_shell_index = -1;

    if (elapsed < ASSG_RELOAD_START_TIME)
    {
        assg_seq_local_time = elapsed;
        return ASSG_SEQ_RELOAD_START;
    }

    loop_elapsed = elapsed - ASSG_RELOAD_START_TIME;
    loop_total   = shells * ASSG_RELOAD_SHELL_TIME;

    if (loop_elapsed < loop_total)
    {
        idx = floor(loop_elapsed / ASSG_RELOAD_SHELL_TIME);
        assg_seq_shell_index = idx;
        assg_seq_local_time  = loop_elapsed - idx * ASSG_RELOAD_SHELL_TIME;
        return ASSG_SEQ_RELOAD_MIDDLE;
    }

    // Clamped to the closing sequence's own length: reload_end does not loop, and
    // a resolver that can return a time past the end of its own sequence is a
    // trap for the next caller.
    assg_seq_local_time = min(loop_elapsed - loop_total, ASSG_RELOAD_END_TIME);
    return ASSG_SEQ_RELOAD_END;
};

float(float now) SH_ASShotgunTickState =
{
    // reload_apply_time is deliberately UNREACHABLE (the state retires at
    // reload_dur, so nothing ever reaches reload_dur + 1).  This is a
    // shell-at-a-time loader: the rounds are credited one per insert cycle in
    // W_ASShotgunFrame, and letting SH_StandardTickState ALSO top the magazine
    // up is what produced "the ammo count only goes up after he's done
    // reloading, not every shell" — the animation walked four inserts while the
    // whole magazine landed in one lump at the end.
    //
    // W_ReloadIsServerDriven lists this weapon so the client trusts the
    // server's climbing count for the duration instead of predicting it, the
    // same arrangement the M3 and the HL shotgun use.
    return SH_StandardTickState(now, mag_asshotgun, ammo_asshotgun, MAX_MAG_ASSHOTGUN,
        ASSG_DRAW_DURATION, ASSG_FIRE_DURATION,
        SH_ASShotgunReloadDuration(self.assg_reload_shells),
        SH_ASShotgunReloadDuration(self.assg_reload_shells) + 1);
};

// Which trigger fired the shot in flight.  Both sides set it from the same
// shared gates, so the viewmodel shows shoot_FullAUTO for a right-click on the
// client without the state machine needing a second weaponstate.
.float assg_alt_shot;

float(float now) SH_ASShotgunTryFire =
{
    float r = SH_StandardTryFire(now, mag_asshotgun, ASSG_FIRE_DELAY, ASSG_DRYFIRE_DELAY);
    if (r == 1)
        self.assg_alt_shot = FALSE;
    return r;
};

// Secondary gate — one shell, but a 1.7 s recovery instead of 0.65 (.as:236-246).
//
// SPELLED OUT RATHER THAN CALLING SH_StandardTryFire, for two reasons that both
// matter.  First, the delay: routing through the standard gate stamped
// attack_finished at 0.65 s and W_ASShotgunFire2 then overwrote it, which the
// client could not reproduce.  Second, and worse, SH_StandardTryFire's CSQC half
// emits `cmd cs` — the client-shot notification whose server handler
// unconditionally calls self.fire(), i.e. the PRIMARY.  A predicted alt-fire
// through that path would have made every right-click also fire a primary shell
// on the server.  Same shape as the HL shotgun's SH_ShotgunTryDoubleFire, and
// for the same reason.
float(float now) SH_ASShotgunTryFire2 =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_asshotgun <= 0)
    {
        self.attack_finished = now + ASSG_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + ASSG_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.mag_asshotgun   -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + ASSG_FIRE2_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + ASSG_FIRE2_DELAY;
#endif
    self.fire_spread_pending += FIRE_SPREAD_PENALTY_PER_SHOT;
    self.assg_alt_shot = TRUE;
    return 1;
};

float(float now) SH_ASShotgunTryReload =
{
    float shells = min(MAX_MAG_ASSHOTGUN - self.mag_asshotgun, self.ammo_asshotgun);
    float r = SH_StandardTryReload(now, mag_asshotgun, ammo_asshotgun, MAX_MAG_ASSHOTGUN,
                                  SH_ASShotgunReloadDuration(shells));
    if (r)
    {
        self.assg_reload_shells = shells;
        self.assg_reload_stage  = 0;   // no shells credited yet
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

.float assg_reload_snd_stage;

void(entity player) W_ASShotgunPickupCopy =
{
    player.mag_asshotgun  = self.mag_asshotgun;
    player.ammo_asshotgun = self.ammo_asshotgun;
};

void() W_ASShotgunShoot =
{
    float i;
    // ONE kick per trigger pull, not one per pellet — and the VARIANCE has to be
    // silenced along with the pitch and the strength.
    //
    // This used to pass ASSG_KICK_VARIANCE unconditionally while zeroing only the
    // other two, on the assumption that a 0 strength disables the kick.  It does
    // not: SH_ApplyViewKick coerces `weapon_strength <= 0` back to 1.0
    // (sh_weapon_logic.qc:104, so that callers may omit the argument), so pellets
    // 2..9 were each applying a FULL-strength yaw impulse
    //     SH_SpreadJitter(...) * kick_variance * 1.0
    // and only the pitch was actually suppressed.  Nine yaw kicks per shell is
    // most of why this weapon felt like it threw the view around.
    //
    // kick_variance 0 makes yaw_impulse identically zero regardless of the
    // strength coercion, which is what makes this correct rather than merely
    // smaller.
    //
    // AND EACH PELLET NEEDS ITS OWN SPREAD SEED.  W_PenetratingHitscanShoot is
    // the single-bullet path and jitters off wep_action_id alone, so without
    // the offset all nine of these traces resolved to the SAME sx/sy: not a
    // spread at all, but one slug sent up to 7.5 degrees off the crosshair in a
    // direction that changed every trigger pull.  That is the "super random when
    // firing, firing in a wild direction every shot" report.  Every other
    // shotgun here goes through W_*FirePellets / CSQC_PredictedShotgunImpact,
    // which have always spelt this as wep_action_id + i; this weapon wants wall
    // penetration, which those do not do, so it borrows the same seeding
    // instead.  See sh_spread_seed_offset in sh_weapon_logic.qc.
    for (i = 0; i < ASSG_PELLETS; i = i + 1)
    {
        sh_spread_seed_offset = i;
        W_PenetratingHitscanShoot(ASSG_BASE_SPREAD, ASSG_MOVE_SPREAD, ASSG_FULL_SPREAD_SPEED,
            ASSG_CLOSE_DAMAGE, ASSG_MIN_DAMAGE, ASSG_DAMAGE_FALLOFF_RANGE, 4, 0.9,
            (i == 0) ? ASSG_KICK_PITCH    : 0,
            (i == 0) ? ASSG_KICK_VARIANCE : 0,
            (i == 0) ? ASSG_KICK_STRENGTH : 0);
    }
};

void() W_ASShotgunFire =
{
    float r = SH_ASShotgunTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = ASSG_SEQ_SHOOT;
        self.wep_nextframe = time + ASSG_FRAME_INTERVAL;

        W_ASShotgunShoot();

        // A SINGLE barrel per shot — .as:186-228 plays one sbarrel1, not HL's
        // dbarrel.  All this weapon's audio is stock Half-Life.
        sound(self, CHAN_WEAPON, "weapons/sbarrel1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_SHOTGUN2, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

// Secondary — .as:236-246.  Same single shell, different animation, much longer
// recovery.  Written as the script has it rather than as HL's double barrel,
// because a map's weapon is whatever its script says it is.
void() W_ASShotgunFire2 =
{
    float r = SH_ASShotgunTryFire2(time);   // stretched recovery is inside the gate

    if (r == 1)
    {
        self.weaponframe     = ASSG_SEQ_SHOOT2;
        self.wep_nextframe   = time + ASSG_FRAME_INTERVAL;

        W_ASShotgunShoot();

        sound(self, CHAN_WEAPON, "weapons/sbarrel1.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_SHOTGUN2, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_ASShotgunReload =
{
    if (SH_ASShotgunTryReload(time))
    {
        self.weaponframe   = ASSG_SEQ_RELOAD_START;
        self.wep_nextframe = time + ASSG_FRAME_INTERVAL;
        self.assg_reload_snd_stage = 0;
    }
};

void() W_ASShotgunFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += ASSG_FRAME_INTERVAL;

    // The reload is three sequences back to back; the state machine only knows
    // the total, so the frame driver walks them.
    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float el = time - self.wep_anim_start;
        self.weaponframe = SH_ASShotgunReloadSeq(el, self.assg_reload_shells);

        // One shell sound per insert, keyed on the insert index rather than on
        // two fixed instants — the loader now runs as many cycles as there are
        // shells, so a fixed pair of instants could only ever voice the first.
        // assg_reload_snd_stage holds "how many inserts have been voiced".
        if (assg_seq_shell_index >= 0
            && self.assg_reload_snd_stage < assg_seq_shell_index + 1)
        {
            sound(self, CHAN_AUTO, "weapons/reload1.wav", 1, ATTN_NORM);
            self.assg_reload_snd_stage = assg_seq_shell_index + 1;
        }

        // ...and ONE ROUND per insert, on the same cue.  The magazine used to be
        // filled in a single lump by SH_StandardTickState at the end of the
        // whole drill, so the count sat still through every visible insert and
        // then jumped by four.  The latch walks forward one cycle at a time for
        // the same reason the HL shotgun's does: a hitch longer than one insert
        // (0.467 s against a 0.05 s tick) skips whole cycles, and assigning the
        // latch straight to the newest index would bank a single shell for all
        // of them and leave the player short.
        if (assg_seq_shell_index >= 0)
        {
            while (self.assg_reload_stage < assg_seq_shell_index + 1)
            {
                self.assg_reload_stage += 1;
                if (self.mag_asshotgun < MAX_MAG_ASSHOTGUN && self.ammo_asshotgun > 0)
                {
                    self.mag_asshotgun  += 1;
                    self.ammo_asshotgun -= 1;
                }
            }
        }
        // ...and the closing pump once, as the end sequence starts.
        else if (assg_seq_shell_index < 0 && el >= ASSG_RELOAD_START_TIME
                 && self.assg_reload_snd_stage < 90)
        {
            sound(self, CHAN_AUTO, "weapons/scock1.wav", 1, ATTN_NORM);
            self.assg_reload_snd_stage = 90;
        }
    }

    float result = SH_ASShotgunTickState(time);
    if (result & 1)
    {
        // sm_idle carries STUDIO_LOOPING, so the resting pose is safe to hold.
        self.weaponframe   = ASSG_SEQ_IDLE;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_ASShotgunEquip =
{
    W_StandardEquipSetup(ASSG_VIEWMODEL, ASSG_DISPLAY_NAME, ASSG_SEQ_DRAW,
        ASSG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_ASShotgunFire;
    self.altfire  = W_ASShotgunFire2;
    self.reload   = W_ASShotgunReload;
    self.wepframe = W_ASShotgunFrame;
    self.shoot    = W_ASShotgunShoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(ASSG_BASE_SPREAD, ASSG_MOVE_SPREAD, ASSG_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_ASShotgunDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_asshotgun  = self.mag_asshotgun;
    tgt.ammo_asshotgun = self.ammo_asshotgun;
    self.mag_asshotgun  = 0;
    self.ammo_asshotgun = 0;

    setmodel(tgt, ASSG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_as_shotgun";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_ASSHOTGUN;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_ASShotgunEquip;
    tgt.weap_drop_func = W_ASShotgunDrop;
    tgt.pickupcopy     = W_ASShotgunPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_as_shotgun =
{
    setmodel(self, ASSG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_as_shotgun";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_ASSHOTGUN;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_ASShotgunEquip;
    self.weap_drop_func = W_ASShotgunDrop;
    self.pickupcopy     = W_ASShotgunPickupCopy;
    self.touch          = weapon_touch;
    self.mag_asshotgun  = MAX_MAG_ASSHOTGUN;
    self.ammo_asshotgun = 12;    // DEFAULT_GIVE, .as:10 — not a full reserve
    W_RegisterMapWeapon(weapon_as_shotgun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_assg_reload_snd_stage;

// One blast's worth of predicted effects — shared by primary and secondary,
// because .as:236-246's secondary IS the primary shot with a heavier animation
// and a longer pause.  Factored out when the secondary got a predictor at all:
// right-click used to run ONLY on the server, so the shooter heard the shell and
// watched the counter drop while seeing no muzzle flash, no impacts, no decals
// and no casing.  That is the "rightclick causes a shot noise and ammo to go
// down, but nothing fires" report — it was firing the whole time; none of the
// evidence for it is server-side.
void() CSQC_ASShotgunFireEffects =
{
    localsound("weapons/sbarrel1.wav");
    CSQC_RecordPredictedWeaponSound();
    float i;
    for (i = 0; i < ASSG_PELLETS; i = i + 1)
    {
        // Per-pellet spread seed, matching W_ASShotgunShoot exactly — see the
        // note there.  Client and server must draw the SAME nine directions or
        // the decals land somewhere the damage did not.
        sh_spread_seed_offset = i;
        CSQC_PredictedPenetratingImpact(ASSG_BASE_SPREAD, ASSG_MOVE_SPREAD, ASSG_FULL_SPREAD_SPEED,
            ASSG_CLOSE_DAMAGE, ASSG_MIN_DAMAGE, ASSG_DAMAGE_FALLOFF_RANGE, 4, 0.9,
            // Variance zeroed for pellets 2..9 exactly as in
            // W_ASShotgunShoot — see the note there.  Prediction and
            // the server have to apply the SAME single kick or the
            // view fights itself on every shell.
            (i == 0) ? ASSG_KICK_PITCH    : 0,
            (i == 0) ? ASSG_KICK_VARIANCE : 0,
            (i == 0) ? ASSG_KICK_STRENGTH : 0);
    }
    CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl",
        '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
    CSQC_MuzzleFlashAtMuzzle(ASSG_MUZZLE_FORWARD, ASSG_MUZZLE_RIGHT,
        ASSG_MUZZLE_DOWN, self.wep_action_id);
    CSQC_MuzzleSmokeAtMuzzle(ASSG_MUZZLE_FORWARD, ASSG_MUZZLE_RIGHT,
        ASSG_MUZZLE_DOWN, self.wep_action_id, 1);
};

void() CSQC_PredictASShotgunCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_ASShotgunTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                CSQC_ASShotgunFireEffects();
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

    // +attack2 (bit 2).  SH_ASShotgunTryFire2 is used rather than the standard
    // gate so this does NOT emit the `cmd cs` client-shot notification — its
    // server handler calls self.fire(), which would add a primary shell to every
    // right-click.  The server runs W_ASShotgunFire2 off button1 on its own.
    if (input_buttons & 4)
    {
        r = SH_ASShotgunTryFire2(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                CSQC_ASShotgunFireEffects();
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
        SH_ASShotgunReloadSeq(el, self.assg_reload_shells);   // for the side-channel index
        if (assg_seq_shell_index >= 0
            && csqc_assg_reload_snd_stage < assg_seq_shell_index + 1)
        {
            localsound("weapons/reload1.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_assg_reload_snd_stage = assg_seq_shell_index + 1;
        }
        else if (assg_seq_shell_index < 0 && el >= ASSG_RELOAD_START_TIME
                 && csqc_assg_reload_snd_stage < 90)
        {
            localsound("weapons/scock1.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_assg_reload_snd_stage = 90;
        }
    }

    SH_ASShotgunTickState(csqc_pred_time);
};

void() CSQC_PredictASShotgunReload =
{
    if (SH_ASShotgunTryReload(csqc_pred_time))
    { csqc_assg_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_ASShotgunDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return ASSG_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return predicted_player.assg_alt_shot ? ASSG_SEQ_SHOOT2 : ASSG_SEQ_SHOOT;
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        // Feed the sub-sequence's LOCAL time through the override so the insert
        // replays from frame 0 for each shell, instead of one clock being
        // stretched across the whole reload.
        float el = cltime - predicted_player.wep_anim_start;
        float seq = SH_ASShotgunReloadSeq(el, predicted_player.assg_reload_shells);
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = assg_seq_local_time;
        return seq;
    }
    return ASSG_SEQ_IDLE;   // LOOPING — safe to hold
};

void() CSQC_ASShotgunDropClear =
{
    self.mag_asshotgun  = 0;
    self.ammo_asshotgun = 0;
};

void() CSQC_ASShotgunEquip =
{
    self.weapon_name         = ASSG_DISPLAY_NAME;
    self.weapon_viewmodel    = ASSG_VIEWMODEL;
    self.weapon_worldmodel   = ASSG_WORLDMODEL;
    self.weapon_deploy_sound = ASSG_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictASShotgunCommand;
    self.csqc_predict_reload = CSQC_PredictASShotgunReload;
    self.csqc_display_frame  = CSQC_ASShotgunDisplayFrame;
    self.csqc_drop_clear     = CSQC_ASShotgunDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
