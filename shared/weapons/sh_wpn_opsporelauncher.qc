// ============================================================
//  shared/weapons/sh_wpn_opsporelauncher.qc  -  Opposing Force spore launcher
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-spore magazine, 20 reserve, lobbed organic grenade
//  Fire  : projectile — contact detonation, radius damage
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6971 (weapon_sporelauncher, "Spore Launcher"),
//  svencoop/models/{v,p,w}_spore_launcher.mdl, spore.mdl as the projectile, and
//  AUDIO COMES FROM THE GEARBOX MOUNT, NOT SVEN.  svencoop/sound/weapons ships
//  only spore_ammo.wav + spore_hit1-3.wav, and this file used to fire with
//  spore_ammo.wav -- an ammo-HANDLING sample played as the muzzle report, which
//  is why it "did not sound right".  Opposing Force is mounted too
//  (fs_addons.txt, steam:Half-Life/gearbox) and carries the real set:
//  splauncher_fire.wav, splauncher_reload.wav, splauncher_altfire.wav,
//  splauncher_bounce.wav, splauncher_impact.wav.  This is an OpFor weapon; take
//  its audio from OpFor.
//
//  Previously an alias onto WEP_GRENADELAUNCHER (sv_goldsrc_pickups.qc:208).
//  That one at least fired the right SHAPE of thing — which is why it shares
//  CAL_SPORE with the grenade launcher and needs nothing new on the ammo side —
//  but it fired a steel grenade out of a living weapon, with none of the spore
//  sounds and none of the spore model.

// --- Ammo fields ---
.float mag_spore;
// NOT `ammo_spore`: server/sv_goldsrc_ammo.qc:457 already owns that name as the
// void() spawn function for the ammo_spore PICKUP, and QC puts fields and
// functions in one namespace.  Same trap the .357 and crossbow ammo hit, which
// is why those two carry the spawnfunc_ prefix instead.
.float ammo_sporelauncher;

// --- Sequence indices, read out of svencoop/models/v_spore_launcher.mdl (10) -
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).
const float SPORE_SEQ_IDLE          = 0;   // idle,           2.000 s  (61f @ 30)  LOOPING
const float SPORE_SEQ_FIDGET        = 1;   // fidget,         4.000 s (121f @ 30)  LOOPING
const float SPORE_SEQ_RELOAD_REACH  = 2;   // reload_reach,   0.667 s  (21f @ 30)
const float SPORE_SEQ_RELOAD_LOAD   = 3;   // reload_load,    1.000 s  (31f @ 30)
const float SPORE_SEQ_RELOAD_AIM    = 4;   // reload_aim,     0.833 s  (26f @ 30)
const float SPORE_SEQ_FIRE          = 5;   // fire,           0.500 s  (16f @ 30)
const float SPORE_SEQ_HOLSTER       = 6;   // holster1 — no holster state here
const float SPORE_SEQ_DRAW          = 7;   // draw1,          1.000 s  (31f @ 30)
const float SPORE_SEQ_IDLE2         = 8;   // idle2,          4.000 s (121f @ 30)
const float SPORE_SEQ_RELOAD_FAST   = 9;   // reload_aimfast, 0.417 s  (26f @ 60)

const float SPORE_FRAME_INTERVAL = 0.05;

const float SPORE_FIRE_DELAY    = 1.0;
const float SPORE_DRYFIRE_DELAY = 0.3;

const float MAX_MAG_SPORE  = 5;
const float MAX_AMMO_SPORE = 20;

// The reload is three named beats in the model — reach, load, aim — and
// SPORE_RELOAD_DURATION is their sum, which is the number the state machine
// needs.  The two sound instants sit on the reach and the load.
const float SPORE_RELOAD_DURATION  = 2.500;
const float SPORE_RELOAD_SND1_TIME = 0.30;
const float SPORE_RELOAD_SND2_TIME = 1.10;

// SEQUENCE boundaries — deliberately NOT the sound instants above.
//
// The visuals used to switch on SND1/SND2, which is a different thing entirely:
// a sound cue lands where the foley belongs, not where a sequence ends.  Driving
// the animation off them cut reload_reach at 45% of its 0.667 s, cut reload_load
// at 80% of its 1.000 s, and then held reload_aim for 1.40 s though it is only
// 0.833 s long — which is the reported "reload animation is missing parts".
// These are the real cumulative ends: reach 0.667, then load 0.667 + 1.000.
// They sum to SPORE_RELOAD_DURATION, and that is the invariant to preserve.
const float SPORE_RELOAD_SEQ1_END  = 0.667;
const float SPORE_RELOAD_SEQ2_END  = 1.667;

// ONE SPORE PER CYCLE.  The three beats are not a single 2.5 s animation that
// happens to refill the tube — they are a magazine-tube loader's start, insert
// and finish, exactly like the shorty's reload_start / reload_middle / reload_end
// (sh_wpn_asshotgun.qc, which this mirrors).  reload_load is the insert, and it
// has to run once per spore.
//
// Driven as one fixed state it played reach, ONE load, aim, and refilled all
// five — "the reload only does 1 reload, when you need to reload it 5 times like
// a shotgun".  A full reload from empty is now 0.667 + 5x1.000 + 0.833 = 6.5 s,
// which is the length the model's own sequences add up to for five rounds.
const float SPORE_RELOAD_REACH_TIME = 0.667;   // reload_reach — once, at the start
const float SPORE_RELOAD_LOAD_TIME  = 1.000;   // reload_load  — ONCE PER SPORE
const float SPORE_RELOAD_AIM_TIME   = 0.833;   // reload_aim   — once, at the end

// --- Balance ---
// A lobbed organic grenade.  Smaller radius and less damage than the grenade
// launcher it used to impersonate, because it holds five and reloads faster.
const float SPORE_PROJECTILE_SPEED   = 900;
const float SPORE_PROJECTILE_UPSPEED = 150;
const float SPORE_FUSE               = 6;      // if it never touches anything
const float SPORE_EXPLOSION_RADIUS   = 140;
const float SPORE_EXPLOSION_DAMAGE   = 80;
const float SPORE_EXPLOSION_MIN      = 20;

// --- State durations, taken from the sequences themselves ---
const float SPORE_DRAW_DURATION = 1.000;
const float SPORE_FIRE_DURATION = 0.500;

const string SPORE_VIEWMODEL    = "models/v_spore_launcher.mdl";
const string SPORE_WORLDMODEL   = "models/w_spore_launcher.mdl";
const string SPORE_PROJMODEL    = "models/spore.mdl";
const string SPORE_DEPLOY_SOUND = "";
const string SPORE_DISPLAY_NAME = "SPORE LAUNCHER";

// ============================================================
//  SHARED — state machine
// ============================================================

// Spores this reload will insert, latched at its start.  See the ONE SPORE PER
// CYCLE note above.
.float spore_reload_rounds;

// Side-channel outputs of SH_SporeReloadSeq — QC has no multiple return.  Same
// arrangement as the shorty and the HL shotgun, which are the same kind of loader.
float spore_seq_local_time;    // elapsed WITHIN the returned sequence
float spore_seq_round_index;   // 0-based insert cycle in flight; -1 outside the loop

float(float rounds) SH_SporeReloadDuration =
{
    // Never zero-length: a reload entered without prediction (the server-driven
    // path) arrives with rounds == 0, and a loop total of 0 would jump straight
    // from reach to aim with no insert visible at all.
    if (rounds < 1) rounds = 1;
    return SPORE_RELOAD_REACH_TIME + rounds * SPORE_RELOAD_LOAD_TIME + SPORE_RELOAD_AIM_TIME;
};

// Resolve "how far into the reload" into "which sequence, how far into IT, and
// which spore".  Driven off total elapsed rather than re-stamping wep_anim_start
// at each boundary, so the server and the client's prediction share one
// expression and cannot drift apart mid-reload.
float(float elapsed, float rounds) SH_SporeReloadSeq =
{
    float loop_elapsed, loop_total, idx;

    if (rounds < 1) rounds = 1;
    spore_seq_round_index = -1;

    if (elapsed < SPORE_RELOAD_REACH_TIME)
    {
        spore_seq_local_time = elapsed;
        return SPORE_SEQ_RELOAD_REACH;
    }

    loop_elapsed = elapsed - SPORE_RELOAD_REACH_TIME;
    loop_total   = rounds * SPORE_RELOAD_LOAD_TIME;

    if (loop_elapsed < loop_total)
    {
        idx = floor(loop_elapsed / SPORE_RELOAD_LOAD_TIME);
        spore_seq_round_index = idx;
        spore_seq_local_time  = loop_elapsed - idx * SPORE_RELOAD_LOAD_TIME;
        return SPORE_SEQ_RELOAD_LOAD;
    }

    // Clamped to the closing sequence's own length: reload_aim does not loop, and
    // a resolver that can return a time past the end of its own sequence is a
    // trap for the next caller.
    spore_seq_local_time = min(loop_elapsed - loop_total, SPORE_RELOAD_AIM_TIME);
    return SPORE_SEQ_RELOAD_AIM;
};

// Inserts already CREDITED this reload.  Distinct from spore_reload_snd_stage,
// which counts the ones already heard — they advance on the same edge but a
// reload that runs out of reserve mid-cycle stops crediting while the animation
// keeps playing, so one cannot stand in for the other.
.float spore_reload_stage;

// ONE SPORE PER INSERT, ON BOTH SIDES.  The animation has always been per-spore;
// the AMMO was not.  SH_SporeTickState used to hand SH_StandardTickState the same
// value for reload_dur and reload_apply_time, so the whole magazine appeared in a
// single statement at t = 6.5 s while five insert animations played — you watched
// five spores go in and the counter jumped 0 to 5 at the very end.
//
// Both sides run this from the same `wep_anim_start`, so the client predicts each
// round as it seats and the server arrives at the identical number: the reload is
// a pure function of elapsed time and the latched count, exactly as the sequence
// resolver above already is.
//
// The `while` rather than an assignment is deliberate, and is the shotgun's
// (sh_wpn_hlshotgun.qc:561-572): a frame hitch longer than one insert must credit
// every cycle it skipped, or a laggy tick silently eats a spore.
float(float now) SH_SporeReloadCredit =
{
    if (self.weaponstate != WS_RELOAD) return 0;
    if (self.wep_anim_start <= 0)      return 0;

    float seq = SH_SporeReloadSeq(now - self.wep_anim_start, self.spore_reload_rounds);
    if (seq != SPORE_SEQ_RELOAD_LOAD)  return 0;
    if (self.spore_reload_stage > spore_seq_round_index) return 0;

    float credited = 0;
    while (self.spore_reload_stage <= spore_seq_round_index)
    {
        self.spore_reload_stage = self.spore_reload_stage + 1;
        if (self.mag_spore < MAX_MAG_SPORE && self.ammo_sporelauncher > 0)
        {
            self.mag_spore          = self.mag_spore + 1;
            self.ammo_sporelauncher = self.ammo_sporelauncher - 1;
            credited                = credited + 1;
        }
    }

#ifdef SSQC
    // SERVER SIDE ONLY, and not for tidiness: sv_debug_weapons is declared
    // CVAR_SIDE_SV, and reading it from a shared function makes CSQC execute a
    // cvar it never registers - which cvar_audit.py correctly reports as
    // UNDER-REGISTERED.  The client's own count is visible on the HUD anyway.
    if (credited && cvar("sv_debug_weapons"))
        dprint(sprintf("[spore] insert %g/%g -> mag=%g reserve=%g\n",
                       self.spore_reload_stage, self.spore_reload_rounds,
                       self.mag_spore, self.ammo_sporelauncher));
#endif
    return credited;
};

// Can a shot interrupt the reload in flight?  Half-Life's shotgun can, and this
// loader is the same machine — CBasePlayerWeapon::ItemPostFrame tests IN_ATTACK
// before IN_RELOAD and CShotgun::PrimaryAttack clears m_fInSpecialReload
// (shotgun.cpp:186).  Spores already seated stay seated, because they are now
// credited one at a time as the reload runs.  Two conditions, both the shotgun's
// (sh_wpn_hlshotgun.qc:209-215): past the opening reach, and at least one round
// actually in the tube so cancelling can never rewind a reload you gained nothing
// from.
float(float now) SH_SporeReloadCancellable =
{
    if (self.weaponstate != WS_RELOAD) return FALSE;
    if (self.wep_anim_start <= 0)      return FALSE;
    if (self.mag_spore <= 0)           return FALSE;
    return (now - self.wep_anim_start) >= SPORE_RELOAD_REACH_TIME;
};

float(float now) SH_SporeTickState =
{
    // WS_RELOAD is handled here rather than by SH_StandardTickState, whose reload
    // branch is a single all-at-once transfer.  Same short-circuit the cfspas12
    // family uses for the same reason.
    if (self.weaponstate == WS_RELOAD)
    {
        float result  = 0;
        float elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

        if (SH_SporeReloadCredit(now))
            result = result | 2;

        if (elapsed >= SH_SporeReloadDuration(self.spore_reload_rounds))
        {
            SH_WeaponEnterIdle();
            result = result | 1;
        }
        return result;
    }

    return SH_StandardTickState(now, mag_spore, ammo_sporelauncher, MAX_MAG_SPORE,
        SPORE_DRAW_DURATION, SPORE_FIRE_DURATION,
        SH_SporeReloadDuration(self.spore_reload_rounds),
        SH_SporeReloadDuration(self.spore_reload_rounds));
};

float(float now) SH_SporeTryFire =
{
    // Projectile weapons in this tree refuse to fire mid-anything, so the shot and
    // the animation cannot disagree about how many spores left the tube — but a
    // shotgun-style reload is the documented exception.
    if (self.weaponstate == WS_RELOAD)
    {
        if (!SH_SporeReloadCancellable(now))
            return 0;
        // Drop out of the loader first: SH_StandardTryFire rejects WS_RELOAD flat
        // (sh_weapon_standard.qc:211), and this IS CShotgun::PrimaryAttack's
        // `m_fInSpecialReload = 0` (shotgun.cpp:186).  Both sides run the same
        // cancellable test off the same wep_anim_start, so they break out on the
        // same command and cannot disagree about the magazine.
        SH_WeaponEnterIdle();
    }
    else if (self.weaponstate != WS_IDLE)
        return 0;

    return SH_StandardTryFire(now, mag_spore, SPORE_FIRE_DELAY, SPORE_DRYFIRE_DELAY);
};

float(float now) SH_SporeTryReload =
{
    // Latch the count BEFORE the call — the duration depends on it.  The ammo
    // itself now moves one round at a time in SH_SporeReloadCredit.
    float rounds = min(MAX_MAG_SPORE - self.mag_spore, self.ammo_sporelauncher);
    float r = SH_StandardTryReload(now, mag_spore, ammo_sporelauncher, MAX_MAG_SPORE,
                                   SH_SporeReloadDuration(rounds));
    if (r)
    {
        self.spore_reload_rounds = rounds;
        self.spore_reload_stage  = 0;
    }
    return r;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

.float spore_reload_snd_stage;

void(entity player) W_SporePickupCopy =
{
    player.mag_spore  = self.mag_spore;
    player.ammo_sporelauncher = self.ammo_sporelauncher;
};

void() W_SporeExplode =
{
    // An ORGANIC BURST, not ordnance.  This used to call te_explosion — the stock
    // Quake rocket fireball — on a projectile that is a living spore, which is
    // what read as "an explosion effect I don't think is correct".  It now goes
    // out as ALIENFX_SPORE_BURST, whose recipe sits in particles/aliens.cfg beside
    // alien_spit_impact (the family it belongs to) in the sprite's own measured
    // yellow-green, and which carries a matching dlight.
    //
    // AlienFX_Multicast is PVS-multicast to everyone including the shooter, and
    // that is correct here: unlike the grenade, the spore has no CSQC-predicted
    // detonation to collide with — CSQC_FakeSporeRetire only removes the local
    // stand-in.  So the dimension_send exclude that used to wrap te_explosion has
    // gone with it rather than being carried over; keeping it would have hidden
    // the burst from the one player most likely to be looking at it.
    AlienFX_Multicast(ALIENFX_SPORE_BURST, self.origin + '0 0 8', '0 0 1');

    // spore_hit1-3.wav are the projectile's BOUNCE samples, not its detonation —
    // they are byte-identical to gearbox's splauncher_bounce.wav.  The detonation
    // has its own sample and this is it.
    sound(self, CHAN_WEAPON, "weapons/splauncher_impact.wav", 1, ATTN_NORM);

    // Radius damage + player knockback + phys-drop blast — single call.
    W_RadiusExplode(self.origin, SPORE_EXPLOSION_RADIUS,
                    SPORE_EXPLOSION_DAMAGE, SPORE_EXPLOSION_MIN,
                    600, 250, self.owner);

    remove(self);
};

void() W_SporeTouch =
{
    if (other == self.owner)
        return;   // don't detonate on the shooter
    W_SporeExplode();
};

// Periodic tick wrapper — pulses CSQC SendFlags every sv_toss_tickrate tick and
// detonates when the absolute fuse time hits.  Same shape as the grenade
// launcher's; see W_GrenadeProjectileTick for the rationale.
void() W_SporeProjectileTick =
{
    self.SendFlags |= 1;
    if (time >= self.proj_fuse_end)
    {
        W_SporeExplode();   // removes self
        return;
    }
    self.nextthink = time + Toss_NextThinkInterval();
};

void() W_SporeFire =
{
    float r = SH_SporeTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SPORE_SEQ_FIRE;
        self.wep_nextframe = time + SPORE_FRAME_INTERVAL;

        makevectors(self.v_angle);
        entity sp = spawn();
        sp.owner     = self;
        sp.classname = "proj_spore";
        sp.movetype  = MOVETYPE_TOSS;
        sp.solid     = SOLID_BBOX;
        setmodel(sp, SPORE_PROJMODEL);
        setsize(sp, '-2 -2 -2', '2 2 2');
        setorigin(sp, self.origin + self.view_ofs + v_forward * 16);
        sp.velocity  = self.velocity + v_forward * SPORE_PROJECTILE_SPEED
                                     + v_up * SPORE_PROJECTILE_UPSPEED;
        sp.avelocity = '180 360 120';
        sp.gravity   = 1;
        sp.touch     = W_SporeTouch;
        // CSQC replication via projectile_SendEntity — owner-hide is handled by
        // the SendEntity FALSE-return for the shooter; others receive
        // origin+velocity+avelocity at sv_toss_tickrate for smooth flight.
        sp.proj_type     = PROJ_TYPE_SPORE;
        sp.SendEntity    = projectile_SendEntity;
        sp.SendFlags     = 1;
        sp.proj_fuse_end = time + SPORE_FUSE;
        sp.think         = W_SporeProjectileTick;
        sp.nextthink     = time + Toss_NextThinkInterval();

        sound(self, CHAN_WEAPON, "weapons/splauncher_fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_SporeReload =
{
    if (SH_SporeTryReload(time))
    {
        self.weaponframe   = SPORE_SEQ_RELOAD_REACH;
        self.wep_nextframe = time + SPORE_FRAME_INTERVAL;
        self.spore_reload_snd_stage = 0;
    }
};

void() W_SporeFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += SPORE_FRAME_INTERVAL;

    // The reload is three sequences played back to back, so the frame driver has
    // to walk them; the state machine only knows the total duration.
    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float el = time - self.wep_anim_start;

        // Resolve sequence + which spore is going in.  Recomputed from elapsed
        // each tick rather than latched, so this matches CSQC_SporeDisplayFrame
        // exactly — the predicted viewmodel and the replicated third-person copy
        // have to agree frame for frame.
        float seq = SH_SporeReloadSeq(el, self.spore_reload_rounds);
        self.weaponframe = seq;

        // Foley ONCE PER SPORE, keyed on the insert index rather than on a single
        // absolute instant.  A one-shot latch at SPORE_RELOAD_SND1_TIME played one
        // sound for a reload that now inserts up to five.
        if (seq == SPORE_SEQ_RELOAD_LOAD
            && self.spore_reload_snd_stage <= spore_seq_round_index)
        {
            self.spore_reload_snd_stage = spore_seq_round_index + 1;
            sound(self, CHAN_AUTO, "weapons/splauncher_reload.wav", 1, ATTN_NORM);
        }
    }

    float result = SH_SporeTickState(time);
    if (result & 1)
    {
        // idle carries STUDIO_LOOPING, so the resting pose is safe to hold.
        self.weaponframe   = SPORE_SEQ_IDLE;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_SporeEquip =
{
    W_StandardEquipSetup(SPORE_VIEWMODEL, SPORE_DISPLAY_NAME, SPORE_SEQ_DRAW,
        SPORE_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_SporeFire;
    self.reload   = W_SporeReload;
    self.wepframe = W_SporeFrame;
    self.shoot    = W_SporeFire;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 1, FALSE);
};

void() W_SporeDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_spore  = self.mag_spore;
    tgt.ammo_sporelauncher = self.ammo_sporelauncher;
    self.mag_spore  = 0;
    self.ammo_sporelauncher = 0;

    setmodel(tgt, SPORE_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_sporelauncher";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_SPORELAUNCHER;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_SporeEquip;
    tgt.weap_drop_func = W_SporeDrop;
    tgt.pickupcopy     = W_SporePickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_sporelauncher =
{
    setmodel(self, SPORE_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_sporelauncher";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_SPORELAUNCHER;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_SporeEquip;
    self.weap_drop_func = W_SporeDrop;
    self.pickupcopy     = W_SporePickupCopy;
    self.touch          = weapon_touch;
    self.mag_spore      = MAX_MAG_SPORE;
    self.ammo_sporelauncher     = MAX_AMMO_SPORE;
    W_RegisterMapWeapon(weapon_sporelauncher);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Retire the shooter's stand-in silently — on impact or on the fuse.  No
// explosion effect here: the SERVER's spore explosion is multicast to everyone
// including the shooter, so playing one locally too would double it.
void() CSQC_FakeSporeRetire =
{
    remove(self);
};

void() CSQC_PredictSporeCommand =
{
    // The projectile is server-spawned and replicated, but projectile_SendEntity
    // returns FALSE for the OWNER — so the shooter never receives the real spore
    // and needs a local stand-in, exactly as every other projectile weapon here
    // has.  Without it the person firing saw no projectile at all; the comment at
    // the server spawn site noting that "owner-hide is handled by the SendEntity
    // FALSE-return" was true and was precisely the problem.
    if (input_buttons & 1)
    {
        float r = SH_SporeTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("weapons/splauncher_fire.wav");
                CSQC_RecordPredictedWeaponSound();
            }

            // Mirrors the server spawn in W_SporeFire — same offset, speed,
            // up-kick, gravity and spin, so the shooter's copy flies the same
            // arc the replicated one does for everybody else.
            if (!pm_suppress_sounds)
            {
                entity sp = spawn();
                makevectors(input_angles);
                setmodel(sp, SPORE_PROJMODEL);
                setsize(sp, '-2 -2 -2', '2 2 2');
                setorigin(sp, self.origin + self.view_ofs + v_forward * 16);
                sp.owner     = self;
                sp.velocity  = self.velocity + v_forward * SPORE_PROJECTILE_SPEED
                                             + v_up * SPORE_PROJECTILE_UPSPEED;
                sp.angles    = W_ModelAngles(sp.velocity, TRUE);  // spore.mdl is IDST
                sp.avelocity = '180 360 120';
                sp.movetype  = MOVETYPE_TOSS;
                sp.solid     = SOLID_BBOX;
                sp.gravity   = 1;
                sp.drawmask  = MASK_ENGINE;
                sp.classname            = "csqc_fake_projectile";
                sp.csqc_projectile_type = PROJ_TYPE_SPORE;
                sp.touch     = CSQC_FakeSporeRetire;
                sp.think     = CSQC_FakeSporeRetire;
                sp.nextthink = time + SPORE_FUSE;
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

    SH_SporeTickState(csqc_pred_time);
};

void() CSQC_PredictSporeReload =
{
    if (SH_SporeTryReload(csqc_pred_time))
        CSQC_MarkPendingWeaponAck();
};

float(float elapsed) CSQC_SporeDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SPORE_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SPORE_SEQ_FIRE;
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        // Same resolver the server walks, so the predicted viewmodel and the
        // replicated one agree.  The per-spore insert restarts from frame 0 each
        // cycle, which is what the sequence-time override is for — without it the
        // five inserts would read as one long slide.
        float el  = cltime - predicted_player.wep_anim_start;
        float seq = SH_SporeReloadSeq(el, predicted_player.spore_reload_rounds);
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time          = spore_seq_local_time;
        return seq;
    }
    return SPORE_SEQ_IDLE;   // LOOPING — safe to hold
};

void() CSQC_SporeDropClear =
{
    self.mag_spore  = 0;
    self.ammo_sporelauncher = 0;
};

void() CSQC_SporeEquip =
{
    self.weapon_name         = SPORE_DISPLAY_NAME;
    self.weapon_viewmodel    = SPORE_VIEWMODEL;
    self.weapon_worldmodel   = SPORE_WORLDMODEL;
    self.weapon_deploy_sound = SPORE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSporeCommand;
    self.csqc_predict_reload = CSQC_PredictSporeReload;
    self.csqc_display_frame  = CSQC_SporeDisplayFrame;
    self.csqc_drop_clear     = CSQC_SporeDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
