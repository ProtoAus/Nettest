// ============================================================
//  shared/weapons/sh_wpn_thtesla.qc  -  They Hunger tesla gun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 100 uranium cells, no magazine
//  Fire  : short-range electric arc, 512 units
//  Alt   : hold to charge, release for a big arc + blast
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop/scripts/maps/hunger/weapons/weapon_teslagun.as and
//  hunger/weapons/tesla/v_tesla.mdl.  Previously a pickup alias onto
//  WEP_HLEGON, which got the ammo pool right and the weapon wrong: the script
//  is structurally the GAUSS, not the egon — a tapping primary plus a
//  hold-to-charge secondary that burns cells while it winds up — so this is
//  built on WEP_GAUSS's machinery instead, with the tesla's own numbers.

// --- Ammo fields ---
.float ammo_thtesla;

// Charge state, mirroring the gauss's three fields.  Player fields, not
// globals: the same shared code runs on the server and inside CSQC prediction.
.float thtesla_charge_state;       // 0 = none, 1 = winding up, 2 = looping
.float thtesla_charge_started;     // time the charge began
.float thtesla_charge_next_ammo;   // next time to burn a cell while charging

// --- Sequence indices, out of hunger/weapons/tesla/v_tesla.mdl (7 seqs) -----
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
//
// Indices match TESLAGUNAnimation_e (weapon_teslagun.as:18-27).  This is one of
// only two They Hunger viewmodels with STUDIO_LOOPING set on anything — 0 and
// 4 carry it, which is exactly the two that need it (the resting idle and the
// charge loop).
const float THTESLA_SEQ_IDLE       = 0;   // idle,        1.983 s  (120f @  60)  LOOPING
const float THTESLA_SEQ_ATTACK     = 1;   // attack,      0.992 s  (120f @ 120)
const float THTESLA_SEQ_BIG_ATTACK = 2;   // big_attack,  0.992 s  (120f @ 120)  see the note below
const float THTESLA_SEQ_SPINUP     = 3;   // spinup,      0.661 s  (120f @ 180)
const float THTESLA_SEQ_CHARGE     = 4;   // charge,      0.496 s  (120f @ 240)  LOOPING
const float THTESLA_SEQ_DRAW       = 5;   // draw,        0.992 s  (120f @ 120)
const float THTESLA_SEQ_SPINDOWN   = 6;   // spindown,    1.322 s  (120f @  90)  see the note below

// BIG_ATTACK and SPINDOWN are deliberately unreachable, for the same reason
// the Half-Life gauss plays fire2 for both of its shots: nothing tells the
// CLIENT which of the two fired.  .weaponframe is server state (declared at
// sh_customdefs.qc:423, read by no file under client/), and the viewmodel the
// player sees is the CSQC one, so a server-side pick would simply not arrive.
// Reaching them needs a replicated "that was the big one" flag, which is a
// cross-file change; until then both discharges play ATTACK and the beam
// itself is what tells them apart.  SPINDOWN needs a state of its own for the
// wind-down after a charge is dumped, which this state machine does not have.

const float THTESLA_FRAME_INTERVAL      = 0.05;   // wepframe tick rate, not an anim rate

const float MAX_AMMO_THTESLA            = 100;   // TESLA_MAX_CARRY, weapon_teslagun.as:13

// --- Balance ---
// weapon_teslagun.as:203 re-arms both triggers at 0.05 s and :215 re-arms the
// beam itself at 0.035 s, i.e. the primary is a continuous crackle rather than
// a shot.  0.1 s here instead: at 0.05 s the beam is re-sent faster than the
// server ticks, so the extra rate would cost bandwidth and buy nothing.
const float THTESLA_PRIMARY_DAMAGE      = 14;
const float THTESLA_PRIMARY_AMMO_COST   = 1;
const float THTESLA_PRIMARY_DELAY       = 0.1;
// :375/:441/:506 all trace 512 units and stop.  That short reach IS the
// weapon — it is a room-clearing arc, not a rifle — so it is kept exactly,
// against the egon's 2048 and the gauss's 8192.
const float THTESLA_BEAM_RANGE          = 512;
const float THTESLA_CHARGE_START_DELAY  = 0.1;
const float THTESLA_CHARGED_DELAY       = 0.5;
// :314 dumps the charge once m_flStartCharge is more than 4 seconds old.
const float THTESLA_MAX_CHARGE_TIME     = 4.0;
// :298 burns a cell every 0.1 s while winding up, and :311 stops the burn once
// m_flAmmoStartCharge (start + 3 s) passes — so a full charge costs about
// thirty cells, a third of the reserve.
const float THTESLA_CHARGE_AMMO_INTERVAL = 0.1;
const float THTESLA_CHARGE_AMMO_STOP     = 3.0;
const float THTESLA_MIN_CHARGE_DAMAGE   = 50;
const float THTESLA_MAX_CHARGE_DAMAGE   = 180;
const float THTESLA_DRYFIRE_DELAY       = 0.2;
// :306 fires the charge automatically the moment the reserve runs out, so
// unlike the gauss there is no hold-forever case and no self-damage rule in
// the script.  The overcharge dump is kept anyway, at the script's own 4 s
// ceiling rather than the gauss's 10 s, so a held trigger cannot park the
// weapon in WS_SPECIAL indefinitely.
const float THTESLA_CHARGE_BLAST_RADIUS = 140;
const float THTESLA_CHARGE_BLAST_PUSH   = 500;
const float THTESLA_CHARGE_BLAST_UPLIFT = 220;

// --- State durations, taken from the sequences themselves ---
const float THTESLA_DRAW_DURATION   = 0.992;   // draw
const float THTESLA_FIRE_DURATION   = 0.992;   // attack
const float THTESLA_SPINUP_DURATION = 0.661;   // spinup, before the charge loop takes over

const string THTESLA_VIEWMODEL    = "models/hunger/weapons/tesla/v_tesla.mdl";
const string THTESLA_WORLDMODEL   = "models/hunger/weapons/tesla/w_tesla.mdl";
const string THTESLA_DEPLOY_SOUND = "hunger/weapons/tesla/tesla_draw.ogg";
const string THTESLA_DISPLAY_NAME = "TESLA GUN";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_THTeslaTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= THTESLA_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= THTESLA_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    // WS_SPECIAL (charging) does not time out here — it ends on release, on
    // the reserve running dry, or on the 4 s ceiling.
    return 0;
};

float(float now) SH_THTeslaTryPrimaryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    // `now`-based — see sh_weapon_standard.qc SH_StandardTryFire.
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD)
        return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_thtesla < THTESLA_PRIMARY_AMMO_COST)
    {
        self.attack_finished = now + THTESLA_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + THTESLA_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.ammo_thtesla    -= THTESLA_PRIMARY_AMMO_COST;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + THTESLA_PRIMARY_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + THTESLA_PRIMARY_DELAY;
#endif
    return 1;
};

float(float now) SH_THTeslaTryAltFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL || self.weaponstate == WS_RELOAD)
        return 0;
    if (now < self.attack_finished) return 0;

    // .as:257 needs more than one cell to begin: the first is spent starting
    // the charge, and starting with exactly one would fire it back instantly.
    if (self.ammo_thtesla <= 1)
    { self.attack_finished = now + THTESLA_DRYFIRE_DELAY; return -1; }

    self.ammo_thtesla            -= 1;
    self.weaponstate              = WS_SPECIAL;
    self.wep_action_id           += 1;
    self.wep_anim_start           = now;
    self.attack_finished          = now + THTESLA_CHARGE_START_DELAY;
    self.thtesla_charge_state     = 1;
    self.thtesla_charge_started   = now;
    self.thtesla_charge_next_ammo = now + THTESLA_CHARGE_AMMO_INTERVAL;
    return 1;
};

// Damage for the charge held so far.  Clears the charge state and enters
// WS_FIRE, so the caller only has to draw the beam.
float(float now) SH_THTeslaCalcChargeDamage =
{
    float charge_elapsed, charge_ratio, damage;

    if (self.thtesla_charge_state <= 0)
        return 0;

    charge_elapsed = now - self.thtesla_charge_started;
    if (charge_elapsed < 0) charge_elapsed = 0;

    charge_ratio = bound(0, charge_elapsed / THTESLA_MAX_CHARGE_TIME, 1);
    damage = THTESLA_MIN_CHARGE_DAMAGE
           + (THTESLA_MAX_CHARGE_DAMAGE - THTESLA_MIN_CHARGE_DAMAGE) * charge_ratio;

    self.thtesla_charge_state     = 0;
    self.thtesla_charge_started   = 0;
    self.thtesla_charge_next_ammo = 0;
    self.weaponstate              = WS_FIRE;
    self.wep_action_id           += 1;
    self.wep_anim_start           = now;
    self.attack_finished          = now + THTESLA_CHARGED_DELAY;

    return damage;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_THTeslaPickupCopy =
{ player.ammo_thtesla = self.ammo_thtesla; };

void(float damage, float is_primary) W_THTeslaArcFire =
{
    vector src, dir, end, beam_end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    dir = v_forward;
    end = src + dir * THTESLA_BEAM_RANGE;

    W_WeaponTraceLine(src, end);

    beam_end = (trace_fraction < 1.0) ? trace_endpos : end;
    // HL_BEAM_ARC is the alien slave's crackling arc — dim, noisy and
    // multi-segment, which is what a tesla discharge should look like and what
    // the script draws three of (UpdateLightning / 2 / 3, .as:372/:438/:503).
    // ONE goes over the wire here: three continuous beams at 10 Hz is three
    // times the traffic for a difference nobody can pick out in a firefight.
    HLBeam_Multicast(HL_BEAM_ARC, self, src + v_right * 6 + v_up * -10, beam_end);

    if (trace_fraction < 1.0)
    {
        // sv_dmg_bits is deliberately left alone (0 == DMG_BULLET,
        // sh_weapon_standard.qc:567), so an arc does NOT tear a corpse apart.
        // That is the script's own choice and it is commented as such at
        // weapon_teslagun.as:400: "Switched out DMG_GIB_CORPSE with DMG_SHOCK |
        // DMG_ENERGYBEAM".  Neither of those bits is in Half-Life's
        // DMG_GIB_CORPSE mask (cbase.h:638 is CRUSH|FALL|BLAST|SONIC|CLUB), so
        // the port moved this weapon off gibbing on purpose and it stays off.
        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, damage);
        else
            W_ImpactEffect(trace_endpos);

        W_DebugImpact(trace_endpos, damage, W_BoneToHitgroup(trace_bone_id));

        if (!is_primary)
        {
            te_explosion(trace_endpos);
            W_RadiusExplode(trace_endpos, THTESLA_CHARGE_BLAST_RADIUS,
                            damage * 0.5, damage * 0.1,
                            THTESLA_CHARGE_BLAST_PUSH, THTESLA_CHARGE_BLAST_UPLIFT,
                            self);
        }
    }
};

void() W_THTeslaPrimaryFire =
{
    float r = SH_THTeslaTryPrimaryFire(time);
    if (r == 1)
    {
        self.weaponframe   = THTESLA_SEQ_ATTACK;
        self.wep_nextframe = time + THTESLA_FRAME_INTERVAL;
        W_THTeslaArcFire(THTESLA_PRIMARY_DAMAGE, TRUE);
        sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_fire.ogg", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_THTeslaAltFire =
{
    float r = SH_THTeslaTryAltFire(time);
    if (r == 1)
    {
        // spinup first; W_THTeslaFrame swaps to the charge loop once the
        // wind-up is done, the same hand-off the gauss makes.
        self.weaponframe   = THTESLA_SEQ_SPINUP;
        self.wep_nextframe = time + THTESLA_FRAME_INTERVAL;
        sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_spinup.ogg", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_THTeslaAltRelease =
{
    float damage;

    if (self.weaponstate != WS_SPECIAL) return;

    damage = SH_THTeslaCalcChargeDamage(time);
    if (damage > 0)
    {
        self.weaponframe   = THTESLA_SEQ_ATTACK;
        self.wep_nextframe = time + THTESLA_FRAME_INTERVAL;
        W_THTeslaArcFire(damage, FALSE);
        sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_bigrelease.ogg", 1, ATTN_NORM);
    }
};

void() W_THTeslaFrame =
{
    self.wep_nextframe = time + THTESLA_FRAME_INTERVAL;

    if (self.weaponstate == WS_IDLE)
    {
        self.weaponframe = THTESLA_SEQ_IDLE;
        return;
    }

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_FIRE)
    {
        self.weaponframe = (self.weaponstate == WS_DRAW) ? THTESLA_SEQ_DRAW
                                                         : THTESLA_SEQ_ATTACK;
        if (SH_THTeslaTickState(time))        // enters WS_IDLE, clears wep_anim_start
            self.weaponframe = THTESLA_SEQ_IDLE;
        return;
    }

    if (self.weaponstate == WS_SPECIAL)
    {
        if (self.thtesla_charge_state == 1 && elapsed >= THTESLA_SPINUP_DURATION)
        {
            self.thtesla_charge_state = 2;
            sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_chargehold.ogg", 1, ATTN_NORM);
        }

        // Re-pointing .frame mid-state is safe: charge LOOPS, so the engine
        // wraps whatever frame1time it is handed inside the 0.496 s.
        self.weaponframe = (self.thtesla_charge_state >= 2) ? THTESLA_SEQ_CHARGE
                                                            : THTESLA_SEQ_SPINUP;

        // Ceiling — .as:314 dumps the charge once it is more than 4 s old.
        // Unlike the gauss there is no self-damage: the script has no such
        // rule, it simply fires.
        if ((time - self.thtesla_charge_started) >= THTESLA_MAX_CHARGE_TIME)
        {
            float dumped = SH_THTeslaCalcChargeDamage(time);
            if (dumped > 0)
            {
                self.weaponframe = THTESLA_SEQ_ATTACK;
                W_THTeslaArcFire(dumped, FALSE);
                sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_bigrelease.ogg", 1, ATTN_NORM);
            }
            return;
        }

        // Reserve ran dry mid-charge — .as:306 fires it rather than dropping it.
        if (self.ammo_thtesla <= 0)
        {
            float damage = SH_THTeslaCalcChargeDamage(time);
            if (damage > 0)
            {
                self.weaponframe = THTESLA_SEQ_ATTACK;
                W_THTeslaArcFire(damage, FALSE);
                sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_bigrelease.ogg", 1, ATTN_NORM);
            }
            return;
        }

        // Burn a cell every 0.1 s, but only for the first 3 s (.as:311 sets
        // m_flNextAmmoBurn to a sentinel once m_flAmmoStartCharge passes) — so
        // the last second of charge is free.
        if (self.thtesla_charge_next_ammo > 0 && time >= self.thtesla_charge_next_ammo)
        {
            if ((time - self.thtesla_charge_started) < THTESLA_CHARGE_AMMO_STOP)
            {
                self.ammo_thtesla -= 1;
                if (self.ammo_thtesla < 0) self.ammo_thtesla = 0;
                self.thtesla_charge_next_ammo = time + THTESLA_CHARGE_AMMO_INTERVAL;
            }
            else
                self.thtesla_charge_next_ammo = 0;
        }
        return;
    }

    // Any state this weapon has no animation for (WS_RELOAD is reachable via
    // the generic reload key even though there is no magazine) falls back to
    // the looping idle rather than to a stale sequence index.
    self.weaponframe    = THTESLA_SEQ_IDLE;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
};

void() W_THTeslaEquip =
{
    // Inlined rather than routed through W_StandardEquipSetup for the same
    // reason the gauss is: the helper clears altfire/altrelease, which this
    // weapon needs.
    self.weaponmodel = THTESLA_VIEWMODEL;
    self.weapon_name = THTESLA_DISPLAY_NAME;
    self.weapon_draw_start_frame = THTESLA_SEQ_DRAW;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_THTeslaPrimaryFire; self.reload = __NULL__; self.wepframe = W_THTeslaFrame;
    self.altfire = W_THTeslaAltFire; self.altrelease = W_THTeslaAltRelease;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = THTESLA_SEQ_DRAW;
    self.wep_nextframe = time + THTESLA_FRAME_INTERVAL;
    self.weapon_uses_sequences = TRUE;
    self.thtesla_charge_state = 0;
    self.thtesla_charge_started = 0;
    self.thtesla_charge_next_ammo = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, TRUE);
};

void() W_THTeslaDrop =
{
    entity tgt = weapon_drop_target;
    tgt.ammo_thtesla = self.ammo_thtesla;
    self.ammo_thtesla = 0;
    self.thtesla_charge_state = 0;
    setmodel(tgt, THTESLA_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_teslagun"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_THTESLA; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_THTeslaEquip; tgt.weap_drop_func = W_THTeslaDrop;
    tgt.pickupcopy = W_THTeslaPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_thteslagun =
{
    setmodel(self, THTESLA_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_teslagun"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_THTESLA; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_THTeslaEquip; self.weap_drop_func = W_THTeslaDrop;
    self.pickupcopy = W_THTeslaPickupCopy; self.touch = weapon_touch;
    self.ammo_thtesla = MAX_AMMO_THTESLA;
    W_RegisterMapWeapon(weapon_thteslagun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void(float damage) CSQC_THTeslaArcDraw =
{
    makevectors(input_angles);
    vector tsrc = self.origin + self.view_ofs;
    vector tend = tsrc + v_forward * THTESLA_BEAM_RANGE;
    CSQC_WeaponTraceLine(tsrc, tend, MOVE_NORMAL, self);
    HLBeam_Draw(HL_BEAM_ARC, self, tsrc + v_right * 6 + v_up * -10,
                (trace_fraction < 1.0) ? trace_endpos : tend);
    if (trace_fraction < 1.0)
    {
        CSQC_BulletImpact(trace_endpos, trace_plane_normal, damage, 0);
        if (cvar("cl_debug_impacts"))
            CSQC_AddDebugImpact(trace_endpos, tsrc, '0 1 0', 0, 0);
    }
};

void() CSQC_PredictTHTeslaCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_THTeslaTryPrimaryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_fire.ogg", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
// White, not powder orange: They Hunger's own script fires
                // DynamicLight(pPlayer.pev.origin, 10, 255,255,255, 1, 10) on both the tap and
                // the charge dump (weapon_teslagun.as:214, :347).  An arc gun lighting the room
                // orange was one of the wrong colours reported.
                CSQC_MuzzleFlash('1 1 1');
                // Perfectly accurate — direct trace, no spread system.
                CSQC_THTeslaArcDraw(THTESLA_PRIMARY_DAMAGE);
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Alt-fire: start the charge.  The state change runs during replay too (it
    // costs a cell and cannot loop); only the sound is live-only.
    if (input_buttons & 4)
    {
        r = SH_THTeslaTryAltFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_spinup.ogg", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Ceiling reached while still held — dump it, the same way the server does.
    if (self.weaponstate == WS_SPECIAL && self.thtesla_charge_state > 0
        && (csqc_pred_time - self.thtesla_charge_started) >= THTESLA_MAX_CHARGE_TIME)
    {
        float dumped = SH_THTeslaCalcChargeDamage(csqc_pred_time);
        if (dumped > 0)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_bigrelease.ogg", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
// White, not powder orange: They Hunger's own script fires
                // DynamicLight(pPlayer.pev.origin, 10, 255,255,255, 1, 10) on both the tap and
                // the charge dump (weapon_teslagun.as:214, :347).  An arc gun lighting the room
                // orange was one of the wrong colours reported.
                CSQC_MuzzleFlash('1 1 1');
                CSQC_THTeslaArcDraw(dumped);
            }
        }
    }

    // Release: fire the charge.
    if (self.weaponstate == WS_SPECIAL
        && self.thtesla_charge_state > 0 && !(input_buttons & 4))
    {
        float damage = SH_THTeslaCalcChargeDamage(csqc_pred_time);
        if (damage > 0)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "hunger/weapons/tesla/tesla_bigrelease.ogg", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
// White, not powder orange: They Hunger's own script fires
                // DynamicLight(pPlayer.pev.origin, 10, 255,255,255, 1, 10) on both the tap and
                // the charge dump (weapon_teslagun.as:214, :347).  An arc gun lighting the room
                // orange was one of the wrong colours reported.
                CSQC_MuzzleFlash('1 1 1');
                CSQC_THTeslaArcDraw(damage);
            }
        }
    }

    SH_THTeslaTickState(csqc_pred_time);
};

// `elapsed` is genuinely used here, as it is on the gauss: the charge owns two
// sequences and the client cannot read which one the server picked
// (thtesla_charge_state only reaches 2 inside W_THTeslaFrame, which is server
// side).  Elapsed since wep_anim_start is the same clock the server latches
// on, so both land on the same sequence at the same instant.
float(float elapsed) CSQC_THTeslaDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return THTESLA_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return THTESLA_SEQ_ATTACK;       // both discharges — see the note on BIG_ATTACK
    if (predicted_player.weaponstate == WS_SPECIAL)
        return (elapsed >= THTESLA_SPINUP_DURATION) ? THTESLA_SEQ_CHARGE
                                                    : THTESLA_SEQ_SPINUP;
    return THTESLA_SEQ_IDLE;             // LOOPING, so no idle driver is needed
};

void() CSQC_THTeslaDropClear =
{
    self.ammo_thtesla = 0;
    self.thtesla_charge_state = 0;
};

void() CSQC_THTeslaEquip =
{
    self.weapon_name         = THTESLA_DISPLAY_NAME;
    self.weapon_viewmodel    = THTESLA_VIEWMODEL;
    self.weapon_worldmodel   = THTESLA_WORLDMODEL;
    self.weapon_deploy_sound = THTESLA_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTHTeslaCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_THTeslaDisplayFrame;
    self.csqc_drop_clear     = CSQC_THTeslaDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
