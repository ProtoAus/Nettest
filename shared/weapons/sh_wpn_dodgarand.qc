// ============================================================
//  shared/weapons/sh_wpn_dodgarand.qc  -  Day of Defeat M1 Garand
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-round en-bloc clip, 32 reserve, semi-automatic .30-06
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : ADS (iron sights)
//  Special: rifle-butt smash (impulse 7, WS_SPECIAL) — moved off +attack2, which
//           it used to share with the ADS envelope declared in the same Equip
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
// NO ASSET SHIPS WITH THIS WEAPON — models/v_garand.mdl, models/w_garand.mdl,
// models/p_garand.mdl come from the mounted dod gamedir.
//
// MEASURED FROM dod/models/v_garand.mdl:
//   [0]  idle          5fps    61f  12.000s
//   [1]  shoot1       50fps    51f   1.000s   f1 5001 (flash) f1 6002 (shell)
//   [2]  shoot2       50fps    51f   1.000s
//   [3]  shoot3       50fps    51f   1.000s
//   [4]  shoot_empty 100fps    66f   0.650s   f1 5001, f1 6001 -- the LAST round
//   [5]  reload       50fps    96f   1.900s
//         f48 5004 "weapons/garand_reload_clipin.wav"  frac 0.5053
//   [6]  draw         40fps    51f   1.250s   f1 5004 "weapons/rifleselect.wav"
//   [7]  empty_idle   30fps     2f   0.033s
//   [8]  draw_empty   40fps    51f   1.250s
//   [9]  smash        75fps    86f   1.133s
//   [10] smash_empty  75fps    86f   1.133s
//
// TWO THINGS EVERYONE KNOWS ABOUT THIS RIFLE, and both are implemented:
//
//  1. THE PING.  The en-bloc clip is ejected by the action on the last round,
//     and it rings.  weapons/garand_reload_clipding.wav is that sound; it is
//     NOT an event on any sequence -- Day of Defeat plays it from code -- so
//     this file plays it from the fire path, on the shot that empties the rifle.
//     It is deliberately on CHAN_AUTO at ATTN_NORM, i.e. audible to other
//     players, because being heard running dry is the entire point of it.
//
//  2. THE CLIP IS ALL-OR-NOTHING *HERE*, and the real rifle is slightly kinder
//     than that.  Pressing the clip latch on the left of the receiver throws a
//     partial clip with the rounds still in it, and you can — awkwardly, and not
//     under fire — press singles down onto a partly-full clip instead.  This mod
//     models only the dump: W_DodGarandReload zeroes the magazine at the START of
//     the reload and SH_StandardTickState then moves a full eight in from the
//     reserve.  Partial rounds are lost, which is the reason to think before
//     pressing R.
//
//     AND IT RINGS WHEN YOU DO IT.  The ping is the CLIP leaving the receiver, not
//     the last round leaving the barrel — the same ejector spring throws it either
//     way.  It is only associated with running dry because on the eighth round the
//     rifle does it for you.  So the sound is emitted from BOTH paths: the fire
//     path on the shot that empties the rifle, and the reload path when a clip with
//     live rounds still in it is dumped.  The second of those was silent until it
//     was reported.
//
// The draw and smash takes come in loaded/empty pairs so the clip is visibly
// absent when the rifle is dry; both are picked off the magazine.

// --- Ammo fields ---
.float mag_dodgarand;
.float ammo_dodgarand;

// --- Sequence indices (FALLBACKS ONLY — everything resolves by name) ---
const float DODGARAND_SEQ_IDLE      = 0;
const float DODGARAND_SEQ_SHOOT1    = 1;
const float DODGARAND_SEQ_SHOOT2    = 2;
const float DODGARAND_SEQ_SHOOT3    = 3;
const float DODGARAND_SEQ_SHOOTEMP  = 4;
const float DODGARAND_SEQ_RELOAD    = 5;
const float DODGARAND_SEQ_DRAW      = 6;
const float DODGARAND_SEQ_DRAWEMP   = 8;
const float DODGARAND_SEQ_SMASH     = 9;
const float DODGARAND_SEQ_SMASHEMP  = 10;

const float DODGARAND_FRAME_INTERVAL = 0.0333334;
const float DODGARAND_FIRE_DELAY     = 0.30;
const float DODGARAND_DRYFIRE_DELAY  = 0.20;

const float DODGARAND_DRAW_F_SELECT  = 0.0200;   // frame 1  / 50
const float DODGARAND_RELOAD_F_CLIP  = 0.5053;   // frame 48 / 95

const float DODGARAND_IDLE_REARM_MIN = 10;
const float DODGARAND_IDLE_REARM_MAX = 15;

// Rifle butt.  Slower and shorter than the 98K's bayonet (0.65s / 88 units /
// 70 damage) because it is a blunt swing rather than a thrust -- but it is the
// same idea and deliberately sits just under it.
const float DODGARAND_SMASH_DELAY  = 0.80;
const float DODGARAND_SMASH_DAMAGE = 55;
const float DODGARAND_SMASH_RANGE  = 80;
const float DODGARAND_SMASH_F_HIT  = 0.2500;   // the butt arrives a quarter in

const float MAX_MAG_DODGARAND  = 8;
const float MAX_AMMO_DODGARAND = 32;

// --- Balance ---
//
// Against the one Day of Defeat weapon that was already here: the K98 is 80/60
// over 4096, a bolt-action firing the same class of cartridge.  The Garand
// fires as fast as you can pull the trigger and holds eight, so it gives up a
// large slice of that -- 62/44 -- and keeps the long falloff, because .30-06 is
// .30-06 whatever is wrapped around it.  That still makes it the second-hardest
// hitting primary in this set and a two-shot kill on an unarmoured target,
// which is what it should be.
const float DODGARAND_BASE_SPREAD          = 0.006;
const float DODGARAND_MOVE_SPREAD          = 0.080;
const float DODGARAND_FULL_SPREAD_SPEED    = 320;
const float DODGARAND_CLOSE_DAMAGE         = 62;
const float DODGARAND_MIN_DAMAGE           = 44;
const float DODGARAND_DAMAGE_FALLOFF_RANGE = 4096;
const float DODGARAND_KICK_PITCH    = 2.20;   // full-power round, semi-auto:
const float DODGARAND_KICK_VARIANCE = 0.45;   // heavy, but it settles between
const float DODGARAND_KICK_STRENGTH = 1.30;   // shots the way a bolt gun cannot

const float DODGARAND_MUZZLE_FORWARD = 48;
const float DODGARAND_MUZZLE_RIGHT   = 3;
const float DODGARAND_MUZZLE_DOWN    = 2;

const string DODGARAND_VIEWMODEL    = "models/v_garand.mdl";
const string DODGARAND_WORLDMODEL   = "models/w_garand.mdl";
const string DODGARAND_DEPLOY_SOUND = "";
const string DODGARAND_DISPLAY_NAME = "M1 Garand";

.float dodgarand_snd_stage;

// ============================================================
//  SHARED - sequence resolution
// ============================================================

float() SH_DodGarandSeqIdle     = { return SH_SeqForName(DODGARAND_VIEWMODEL, "idle",        DODGARAND_SEQ_IDLE); };
// The clip-ejected rest pose.  This file already wires shoot_empty, draw_empty
// and smash_empty, so the gap was the IDLE only — the same one eight DoD weapons
// shared; see the note in sh_wpn_dodmp40.qc.
const float DODGARAND_SEQ_EMPTY_IDLE = 7;
float() SH_DodGarandSeqEmptyIdle = { return SH_SeqForName(DODGARAND_VIEWMODEL, "empty_idle", DODGARAND_SEQ_EMPTY_IDLE); };
float() SH_DodGarandSeqShoot1   = { return SH_SeqForName(DODGARAND_VIEWMODEL, "shoot1",      DODGARAND_SEQ_SHOOT1); };
float() SH_DodGarandSeqShoot2   = { return SH_SeqForName(DODGARAND_VIEWMODEL, "shoot2",      DODGARAND_SEQ_SHOOT2); };
float() SH_DodGarandSeqShoot3   = { return SH_SeqForName(DODGARAND_VIEWMODEL, "shoot3",      DODGARAND_SEQ_SHOOT3); };
float() SH_DodGarandSeqShootEmp = { return SH_SeqForName(DODGARAND_VIEWMODEL, "shoot_empty", DODGARAND_SEQ_SHOOTEMP); };
float() SH_DodGarandSeqReload   = { return SH_SeqForName(DODGARAND_VIEWMODEL, "reload",      DODGARAND_SEQ_RELOAD); };
float() SH_DodGarandSeqDraw     = { return SH_SeqForName(DODGARAND_VIEWMODEL, "draw",        DODGARAND_SEQ_DRAW); };
float() SH_DodGarandSeqDrawEmp  = { return SH_SeqForName(DODGARAND_VIEWMODEL, "draw_empty",  DODGARAND_SEQ_DRAWEMP); };
float() SH_DodGarandSeqSmash    = { return SH_SeqForName(DODGARAND_VIEWMODEL, "smash",       DODGARAND_SEQ_SMASH); };
float() SH_DodGarandSeqSmashEmp = { return SH_SeqForName(DODGARAND_VIEWMODEL, "smash_empty", DODGARAND_SEQ_SMASHEMP); };

float(float action_id, float mag) SH_DodGarandPickShootSeq =
{
    float r;
    if (mag <= 0)
        return SH_DodGarandSeqShootEmp();
    r = SH_SpreadHash(action_id);
    if (r < 0.3334) return SH_DodGarandSeqShoot1();
    if (r < 0.6667) return SH_DodGarandSeqShoot2();
    return SH_DodGarandSeqShoot3();
};

float(float mag) SH_DodGarandSeqSmashFor =
{ return (mag <= 0) ? SH_DodGarandSeqSmashEmp() : SH_DodGarandSeqSmash(); };

float() SH_DodGarandDrawDuration   = { return SH_SeqDuration(DODGARAND_VIEWMODEL, SH_DodGarandSeqDraw(),   1.250); };
float() SH_DodGarandReloadDuration = { return SH_SeqDuration(DODGARAND_VIEWMODEL, SH_DodGarandSeqReload(), 1.900); };
float() SH_DodGarandSmashDuration  = { return SH_SeqDuration(DODGARAND_VIEWMODEL, SH_DodGarandSeqSmash(),  1.133); };

// ============================================================
//  SHARED - state machine
// ============================================================

float(float now) SH_DodGarandTickState =
{
    float elapsed;
    float rel;

    // WS_SPECIAL (rifle butt) is handled here, not by the standard function --
    // same shape as the 98K's bayonet.
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (elapsed >= SH_DodGarandSmashDuration())
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    // The clip lands at the end, not mid-animation: the take is picked off the
    // magazine (draw_empty / smash_empty / shoot_empty all branch on it) and it
    // must not flip under the render.  See SH_DodColtTickState.
    rel = SH_DodGarandReloadDuration();
    return SH_StandardTickState(now, mag_dodgarand, ammo_dodgarand, MAX_MAG_DODGARAND,
        SH_DodGarandDrawDuration(),
        SH_SeqDuration(DODGARAND_VIEWMODEL, self.weaponframe, 0.5),
        rel, rel);
};

float(float now) SH_DodGarandTryFire =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFireSemiAuto(now, mag_dodgarand, DODGARAND_FIRE_DELAY, DODGARAND_DRYFIRE_DELAY);
};

float(float now) SH_DodGarandTryReload =
{
    if (self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryReload(now, mag_dodgarand, ammo_dodgarand, MAX_MAG_DODGARAND,
        SH_DodGarandReloadDuration());
};

float(float now) SH_DodGarandTrySmash =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
        || self.weaponstate == WS_SPECIAL)
        return 0;
    if (now < self.attack_finished) return 0;

    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + DODGARAND_SMASH_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodGarandPickupCopy =
{
    player.mag_dodgarand  = self.mag_dodgarand;
    player.ammo_dodgarand = self.ammo_dodgarand;
};

void() W_DodGarandShoot =
{
    // Penetration 80 / 0.98, the same pair the K98 uses: a full-power rifle
    // round goes through crates, doors and thin walls and keeps most of itself.
    W_PenetratingHitscanShoot(DODGARAND_BASE_SPREAD, DODGARAND_MOVE_SPREAD, DODGARAND_FULL_SPREAD_SPEED,
        DODGARAND_CLOSE_DAMAGE, DODGARAND_MIN_DAMAGE, DODGARAND_DAMAGE_FALLOFF_RANGE, 80, 0.98,
        DODGARAND_KICK_PITCH, DODGARAND_KICK_VARIANCE, DODGARAND_KICK_STRENGTH);
};

void() W_DodGarandSmash =
{
    vector src, end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * DODGARAND_SMASH_RANGE;

    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    if (trace_fraction < 1.0)
    {
        sound(self, CHAN_WEAPON, "weapons/butt_hit.wav", 1, ATTN_NORM);
        if (W_CanDamageTarget(trace_ent))
        {
            // Defer player damage to the attacker's hitclaim — see
            // sh_wpn_melee.qc for the rationale.
            float defer_player = (trace_ent.classname == "player")
                                 && W_ShouldDeferToClaim(self);
            if (!defer_player)
                W_ApplyDamage(self, trace_ent, DODGARAND_SMASH_DAMAGE);
        }
        else
            W_ImpactEffect(trace_endpos);
    }
};

void() W_DodGarandFire =
{
    float r = SH_DodGarandTryFire(time);

    if (r == 1)
    {
        self.weaponframe        = SH_DodGarandPickShootSeq(self.wep_action_id, self.mag_dodgarand);
        self.wep_nextframe      = time + DODGARAND_FRAME_INTERVAL;
        self.dodgarand_snd_stage = 0;

        W_DodGarandShoot();

        sound(self, CHAN_WEAPON, "weapons/garand_shoot.wav", 1, ATTN_NORM);
        // The ping.  Magazine already decremented, so 0 is the eighth round.
        if (self.mag_dodgarand <= 0)
            sound(self, CHAN_AUTO, "weapons/garand_reload_clipding.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE_BIG, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

// Weapon special (impulse 7) — the rifle butt, moved off +attack2 to sit beside
// the K43's, which is the same action on the same class of rifle.  +attack2 now
// belongs to the ADS envelope this weapon has always declared
// (W_SetADSProfile(TRUE, "cl_ads_dodgarand", ...) in the Equip): while the smash
// was bound to .altfire, every attempt to bring the rifle to the eye also swung
// it, and every swing also dragged the view into iron sights.
void() W_DodGarandSpecial =
{
    if (SH_DodGarandTrySmash(time))
    {
        self.weaponframe   = SH_DodGarandSeqSmashFor(self.mag_dodgarand);
        self.wep_nextframe = time + DODGARAND_FRAME_INTERVAL;
        self.dodgarand_snd_stage = 0;
    }
};

void() W_DodGarandReload =
{
    // Read BEFORE TryReload, which is also before the en-bloc discard below:
    // this is what decides whether the clip leaving the rifle is a live one.
    float had = self.mag_dodgarand;

    if (SH_DodGarandTryReload(time))
    {
        // En-bloc: whatever is still in the rifle goes out with the clip.  See
        // the note at the top of the file.  Zeroed AFTER TryReload, which needs
        // the real count to decide there is anything to do.
        self.mag_dodgarand       = 0;
        self.weaponframe         = SH_DodGarandSeqReload();
        self.wep_nextframe       = time + DODGARAND_FRAME_INTERVAL;
        self.dodgarand_snd_stage = 0;

        // THE PING ON AN EARLY RELOAD.  You can absolutely reload an M1 early:
        // the clip latch on the left of the receiver dumps the en-bloc clip with
        // whatever is still in it, and the clip leaving the receiver is what
        // makes the noise — the famous "ping" is the CLIP, not the last round.
        // On the last round the rifle does it for you, which is the only reason
        // the sound is associated with running dry.
        //
        // W_DodGarandFire already plays it on the shot that empties the rifle
        // (mag <= 0 there).  This is the other way it can happen, and it was
        // missing: a partial clip was thrown away in silence.  Guarded on `had`
        // so a reload from genuinely empty does NOT double the ping the last
        // shot already played a moment earlier.
        if (had > 0)
            sound(self, CHAN_AUTO, "weapons/garand_reload_clipding.wav", 1, ATTN_NORM);
    }
};

void() W_DodGarandFrame =
{
    float result;
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += DODGARAND_FRAME_INTERVAL;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_DodGarandDrawDuration() * DODGARAND_DRAW_F_SELECT
            && self.dodgarand_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/rifleselect.wav", 1, ATTN_NORM);
            self.dodgarand_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SH_DodGarandReloadDuration() * DODGARAND_RELOAD_F_CLIP
            && self.dodgarand_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, "weapons/garand_reload_clipin.wav", 1, ATTN_NORM);
            self.dodgarand_snd_stage = 1;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_DodGarandSmashDuration() * DODGARAND_SMASH_F_HIT
            && self.dodgarand_snd_stage < 1)
        {
            W_DodGarandSmash();
            self.dodgarand_snd_stage = 1;
        }
    }

    result = SH_DodGarandTickState(time);
    if (result & 1)
    {
        self.weaponframe         = SH_DodGarandSeqIdle();
        self.wep_nextframe       = 0;
        self.dodgarand_snd_stage = 0;
    }
};

void() W_DodGarandEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodgarand", SCOPE_CLASS_NONE);
    // draw_empty when the rifle is dry, so the missing clip is visible from the
    // moment it comes up rather than only once you look at the counter.
    W_StandardEquipSetup(DODGARAND_VIEWMODEL, DODGARAND_DISPLAY_NAME,
        (self.mag_dodgarand <= 0) ? SH_DodGarandSeqDrawEmp() : SH_DodGarandSeqDraw(),
        DODGARAND_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodGarandFire;
    self.altfire  = __NULL__;               // +attack2 belongs to ADS now
    self.special  = W_DodGarandSpecial;     // impulse 7 = rifle butt
    self.reload   = W_DodGarandReload;
    self.wepframe = W_DodGarandFrame;
    self.shoot    = W_DodGarandShoot;
    self.dodgarand_snd_stage = 0;
    W_SetCrosshairProfile(DODGARAND_BASE_SPREAD, DODGARAND_MOVE_SPREAD, DODGARAND_FULL_SPREAD_SPEED, 1.7, TRUE);
};

void() W_DodGarandDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_dodgarand  = self.mag_dodgarand;
    tgt.ammo_dodgarand = self.ammo_dodgarand;

    self.mag_dodgarand  = 0;
    self.ammo_dodgarand = 0;

    setmodel(tgt, DODGARAND_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_garand";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_DODGARAND;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_DodGarandEquip;
    tgt.weap_drop_func = W_DodGarandDrop;
    tgt.pickupcopy     = W_DodGarandPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_garand =
{
    setmodel(self, DODGARAND_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_garand";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_DODGARAND;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_DodGarandEquip;
    self.weap_drop_func = W_DodGarandDrop;
    self.pickupcopy     = W_DodGarandPickupCopy;
    self.touch          = weapon_touch;
    self.mag_dodgarand  = MAX_MAG_DODGARAND;
    self.ammo_dodgarand = MAX_AMMO_DODGARAND;
    W_RegisterMapWeapon(weapon_garand);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_dodgarand_snd_stage;
float csqc_dodgarand_snd_action;

void() CSQC_PredictDodGarandCommand =
{
    float r;
    float elapsed;

    if (predicted_player.wep_action_id != csqc_dodgarand_snd_action)
    {
        csqc_dodgarand_snd_action = predicted_player.wep_action_id;
        csqc_dodgarand_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        r = SH_DodGarandTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "weapons/garand_shoot.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                if (self.mag_dodgarand <= 0)
                {
                    localsound("weapons/garand_reload_clipding.wav");
                    CSQC_RecordPredictedAutoSound();
                }
                CSQC_PredictedPenetratingImpact(DODGARAND_BASE_SPREAD, DODGARAND_MOVE_SPREAD, DODGARAND_FULL_SPREAD_SPEED,
                    DODGARAND_CLOSE_DAMAGE, DODGARAND_MIN_DAMAGE, DODGARAND_DAMAGE_FALLOFF_RANGE, 80, 0.98,
                    DODGARAND_KICK_PITCH, DODGARAND_KICK_VARIANCE, DODGARAND_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasingbig.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(DODGARAND_MUZZLE_FORWARD, DODGARAND_MUZZLE_RIGHT,
                    DODGARAND_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(DODGARAND_MUZZLE_FORWARD, DODGARAND_MUZZLE_RIGHT,
                    DODGARAND_MUZZLE_DOWN, self.wep_action_id, 4);
                CSQC_EndFireActionEffects();
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

    if (!pm_suppress_sounds && self.wep_anim_start > 0)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_DRAW)
        {
            if (csqc_dodgarand_snd_stage < 1
                && elapsed >= SH_DodGarandDrawDuration() * DODGARAND_DRAW_F_SELECT)
            {
                localsound("weapons/rifleselect.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgarand_snd_stage = 1;
            }
        }
        else if (self.weaponstate == WS_RELOAD)
        {
            if (csqc_dodgarand_snd_stage < 1
                && elapsed >= SH_DodGarandReloadDuration() * DODGARAND_RELOAD_F_CLIP)
            {
                localsound("weapons/garand_reload_clipin.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_dodgarand_snd_stage = 1;
            }
        }
    }

    SH_DodGarandTickState(csqc_pred_time);
};

// Weapon special (impulse 7) — the rifle butt.  Was an `input_buttons & 4` arm
// inside CSQC_PredictDodGarandCommand; moved here so +attack2 is free for the ADS
// envelope, matching CSQC_PredictDodK43Special exactly.  Dispatched from
// CSQC_PredictWeaponImpulse's WEAPON_IMPULSE_SPECIAL chain in
// client/cl_weapons.qc — that chain is a hand-written else-if over self.weapon,
// so a predictor that is not added to it never runs and the swing lands with no
// viewmodel motion at all.
void() CSQC_PredictDodGarandSpecial =
{
    if (SH_DodGarandTrySmash(csqc_pred_time))
    {
        CSQC_MarkPendingWeaponAck();
        if (!pm_suppress_sounds)
        {
            CSQC_PredictedMeleeTrace(DODGARAND_SMASH_RANGE, DODGARAND_SMASH_DAMAGE,
                "weapons/butt_hit.wav", "", "");
            // Melee form — see the note at the same call in sh_wpn_dod98k.qc.
            CSQC_RecordPredictedMeleeSound();
        }
    }
};

void() CSQC_PredictDodGarandReload =
{
    // Read before the try, for the same reason the server's W_DodGarandReload
    // does: after it, the en-bloc discard below has already thrown the rounds away.
    float had = predicted_player.mag_dodgarand;

    if (SH_DodGarandTryReload(csqc_pred_time))
    {
        // Mirror the server's en-bloc discard exactly, or the predicted counter
        // shows the old rounds until the next snapshot corrects it.
        predicted_player.mag_dodgarand = 0;
        csqc_dodgarand_snd_stage  = 0;
        csqc_dodgarand_snd_action = predicted_player.wep_action_id;
        CSQC_MarkPendingWeaponAck();

        // The clip going out with live rounds still in it — see the long note in
        // W_DodGarandReload.  Predicted here so it lands on the button press
        // rather than a round trip later, and suppressed on replay passes so a
        // reconcile does not re-ping several times a second.
        if (had > 0 && !pm_suppress_sounds)
        {
            localsound("weapons/garand_reload_clipding.wav");
            CSQC_RecordPredictedAutoSound();
        }
    }
};

float(float elapsed) CSQC_DodGarandDisplayFrame =
{
    // Both takes are the SAME sequence on purpose: no DoD sequence loops, so a
    // held idle settles on its last frame and the fidget roll must not be able to
    // hand back the other half of the pair.
    float e = (predicted_player.mag_dodgarand <= 0)
              ? SH_DodGarandSeqEmptyIdle() : SH_DodGarandSeqIdle();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODGARAND, predicted_player.weaponstate,
                                   e, e,
                                   DODGARAND_IDLE_REARM_MIN, DODGARAND_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return (predicted_player.mag_dodgarand <= 0) ? SH_DodGarandSeqDrawEmp()
                                                     : SH_DodGarandSeqDraw();
    if (predicted_player.weaponstate == WS_RELOAD)
        return SH_DodGarandSeqReload();
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_DodGarandSeqSmashFor(predicted_player.mag_dodgarand);
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_DodGarandPickShootSeq(predicted_player.wep_action_id,
                                        predicted_player.mag_dodgarand);

    return e;
};

void() CSQC_DodGarandDropClear =
{
    self.mag_dodgarand  = 0;
    self.ammo_dodgarand = 0;
};

void() CSQC_DodGarandEquip =
{
    W_SetADSProfile(TRUE, "cl_ads_dodgarand", SCOPE_CLASS_NONE);
    self.weapon_name         = DODGARAND_DISPLAY_NAME;
    self.weapon_viewmodel    = DODGARAND_VIEWMODEL;
    self.weapon_worldmodel   = DODGARAND_WORLDMODEL;
    self.weapon_deploy_sound = DODGARAND_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodGarandCommand;
    self.csqc_predict_reload = CSQC_PredictDodGarandReload;
    self.csqc_display_frame  = CSQC_DodGarandDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodGarandDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
