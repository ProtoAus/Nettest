// ============================================================
//  shared/weapons/sh_wpn_svm16.qc  -  Sven Co-op M16
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 30-round magazine, 250 reserve, 3-round BURST, 5.56
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : M203 grenade launcher
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6949 (weapon_m16, "M16"), svencoop/models/
//  v_m16a2.mdl + p_m16.mdl + w_m16.mdl, and ammo_556clip (fgd:1460, "5.56mm M16
//  rifle magazine") which is already implemented and had nothing to feed.
//
//  Previously an alias onto WEP_HLSMG carrying w_m16.mdl
//  (sv_goldsrc_pickups.qc:326) — a 9mm MP5 wearing a 5.56 rifle's world model,
//  which also meant the ammo_556clip pickups on the same maps drained into a gun
//  that does not take that round.
//
//  NOTE THE VIEWMODEL NAME.  It is v_m16a2.mdl.  There is no v_m16.mdl on the
//  mount, so the obvious guess — matching w_m16/p_m16 — silently gives you an
//  invisible weapon.  This is also one of the pairs the map's globalmodellist
//  replaces (models/v_m16a2.mdl -> models/pizza_ya_san/v_m16a2.mdl), which only
//  lands because the name here is the one the list is keyed on.
//
//  THE M203 IS ON SECONDARY.  The model carries `launch` and `reload_m203`, and
//  Sven's weapon_m16 is an M16A2 with an M203 — the FGD entry is bare, so the
//  model is the authority.  Secondary used to be unbound entirely.
//
//  It reuses the MP5's contact grenade wholesale (W_HLSMGGrenadeTouch /
//  W_HLSMGGrenadeTick, sh_wpn_hlsmg.qc, which compiles BEFORE this file in both
//  progs) because in Half-Life and Sven they are literally the same launcher.
//  Grenades ride the slot AUX channel exactly as the MP5's do, so they reach the
//  client over plumbing that already exists — no proxy-wire change.

// --- Ammo fields ---
.float mag_svm16;
.float ammo_svm16;
.float ammo_svm16_grenades;

// --- Burst state (see the BURST note in the header) --------------------------
.float svm16_burst_count;   // rounds still queued in the current burst (0 = idle)
.float svm16_burst_next;    // time the next queued round goes off

// --- Sequence indices, read out of svencoop/models/v_m16a2.mdl (9 seqs) ------
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).
const float SVM16_SEQ_DRAW        = 0;   // draw,        0.833 s  (26f @ 30)
const float SVM16_SEQ_HOLSTER     = 1;   // holster,     0.233 s   (8f @ 30)
const float SVM16_SEQ_IDLE        = 2;   // idle,        3.333 s  (51f @ 15)  LOOPING
const float SVM16_SEQ_FIDGET      = 3;   // fidget,      2.833 s  (86f @ 30)
const float SVM16_SEQ_SHOOT1      = 4;   // shoot_1,     0.633 s  (20f @ 30)
const float SVM16_SEQ_SHOOT2      = 5;   // shoot_2,     0.633 s  (20f @ 30)
const float SVM16_SEQ_RELOAD      = 6;   // reload_m16,  3.333 s (101f @ 30)
const float SVM16_SEQ_LAUNCH      = 7;   // launch,      1.000 s  (31f @ 30)  M203 fire
const float SVM16_SEQ_RELOAD_M203 = 8;   // reload_m203, 1.806 s  (55f @ 30)  M203 reload

const float SVM16_FRAME_INTERVAL = 0.05;

const float SVM16_FIRE_DELAY     = 0.0857;   // ~700 rpm, the M16A2's cyclic rate
const float SVM16_DRYFIRE_DELAY  = 0.2;

// --- Burst ------------------------------------------------------------------
// The M16A2 has SAFE/SEMI/BURST and no full-auto position at all, and the mount
// agrees: svencoop/sound/weapons ships m16_3round.wav (a three-shot one-shot
// sample) alongside m16_single.wav, which is not audio you ship for a full-auto
// gun.  The model matches too — shoot_1 and shoot_2 are 0.633 s each, far too
// long to be one round of a 700 rpm stream.
//
// Driven full-auto at SVM16_FIRE_DELAY the display frame restarted a 0.633 s
// sequence every 86 ms and alternated between the two, so you saw the first 13%
// of each, flickering — the "very wrong firing animation".  One trigger pull is
// one burst is one whole sequence.
const float SVM16_BURST_GAP       = 0.0857;  // cyclic rate WITHIN a burst
const float SVM16_BURST_FIRST_GAP = 0.0857;
// Equal to the shoot sequence's own length so a held trigger can never restart
// the animation partway through — the defect this constant exists to prevent.
const float SVM16_BURST_COOLDOWN  = 0.633;

const float MAX_MAG_SVM16        = 30;
const float MAX_AMMO_SVM16       = 250;

// Reload sound instants across the 3.333 s animation.
//
// These used to borrow the SAW's belt-box handling on the stated grounds that
// "there are no M16-specific samples on the mount".  That was simply untrue and
// nobody rechecked it: svencoop/sound/weapons carries m16_magout_metallic.wav,
// m16_magin_metallic.wav, m16_charge.wav, m16_draw.wav, m16_single.wav and
// m16_3round.wav.  The gun was wearing a belt-fed machine gun's audio over a
// magazine-fed rifle's animation — a box coming out of a rifle that has no box.
const float SVM16_RELOAD_SND1_TIME = 0.60;
const float SVM16_RELOAD_SND2_TIME = 2.10;
const float SVM16_RELOAD_SND3_TIME = 2.90;

// --- Balance ---
// 5.56 out of a rifle-length barrel: harder-hitting and much more accurate than
// the 9mm SMG it used to impersonate, and it shares CAL_556 with the M249, so it
// takes numbers that sit consistently against that gun rather than beside it.
const float SVM16_BASE_SPREAD          = 0.01745;   // VECTOR_CONE_2DEGREES
const float SVM16_MOVE_SPREAD          = 0.075;
const float SVM16_FULL_SPREAD_SPEED    = 320;
const float SVM16_CLOSE_DAMAGE         = 18;
const float SVM16_MIN_DAMAGE           = 9;
const float SVM16_DAMAGE_FALLOFF_RANGE = 3072;
const float SVM16_KICK_PITCH    = 0.9;
const float SVM16_KICK_VARIANCE = 0.3;
const float SVM16_KICK_STRENGTH = 1.8;

const float SVM16_MUZZLE_FORWARD = 42;
const float SVM16_MUZZLE_RIGHT   = 4.5;
const float SVM16_MUZZLE_DOWN    = 6.0;

// --- State durations, taken from the sequences themselves ---
const float SVM16_DRAW_DURATION   = 0.833;
const float SVM16_FIRE_DURATION   = 0.633;
const float SVM16_RELOAD_DURATION = 3.333;

// --- M203 ---
// Two grenades carried, same as the MP5's launcher (MAX_AMMO_HLSMG_GRENADES).
// The duration is the `launch` sequence's own length, so the state retires when
// the animation does.
const float MAX_AMMO_SVM16_GRENADES = 2;
const float SVM16_GRENADE_DELAY     = 1.0;
const float SVM16_GRENADE_DURATION  = 1.000;

const string SVM16_VIEWMODEL    = "models/v_m16a2.mdl";
const string SVM16_WORLDMODEL   = "models/w_m16.mdl";
const string SVM16_DEPLOY_SOUND = "";
const string SVM16_DISPLAY_NAME = "M16";

// ============================================================
//  SHARED — sequence pick + state machine
// ============================================================

float(float shot_id) SH_SVM16PickShootSeq =
{
    float n = shot_id - floor(shot_id / 2) * 2;
    if (n == 0) return SVM16_SEQ_SHOOT1;
    return SVM16_SEQ_SHOOT2;
};

// Manual tick rather than SH_StandardTickState, because the M203 adds a
// WS_SPECIAL state the standard one does not know about.  Same shape as the
// MP5's tick (sh_wpn_hlsmg.qc), which carries the same launcher.
float(float now) SH_SVM16TickState =
{
    float elapsed, need, give;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SVM16_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SVM16_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SVM16_GRENADE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SVM16_RELOAD_DURATION)
        {
            need = MAX_MAG_SVM16 - self.mag_svm16;
            give = min(need, self.ammo_svm16);
            self.mag_svm16  = self.mag_svm16  + give;
            self.ammo_svm16 = self.ammo_svm16 - give;
            SH_WeaponEnterIdle();
            return 1 | 2;
        }
        return 0;
    }
    return 0;
};

float(float now) SH_SVM16TryFire =
{
    // Primary must not interrupt an M203 shot mid-animation.
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW
     || self.weaponstate == WS_SPECIAL)
        return 0;
    // A burst still cycling owns the trigger.
    if (self.svm16_burst_count > 0)
        return 0;
    // The FIRST round of the burst goes through the standard try-fire, which is
    // what keeps this weapon emitting `cmd cs` and therefore in the
    // client-notified population rather than W_FireIsServerAutonomous — only the
    // two QUEUED rounds are server-side, exactly as the They Hunger M16A1's burst
    // rounds are.  Hand-rolling this instead would silently move the gun between
    // those two populations and check_serverfire.py would fail.
    //
    // The delay handed over is the burst COOLDOWN, not the cyclic rate: that is
    // the whole fix.  SVM16_FIRE_DELAY is now only the gap between rounds inside
    // one burst (SVM16_BURST_GAP), never the trigger's own rate.
    return SH_StandardTryFire(now, mag_svm16, SVM16_BURST_COOLDOWN, SVM16_DRYFIRE_DELAY);
};

// Queue the rest of the burst after a successful first round.  Sven's
// m_iBurstCount is min(3, clip), so a magazine down to its last one or two
// rounds fires only what is there instead of dry-clicking the remainder.
void(float now) SH_SVM16QueueBurst =
{
    float queued = 2;
    if (self.mag_svm16 < queued)
        queued = self.mag_svm16;
    self.svm16_burst_count = queued;
    self.svm16_burst_next  = now + SVM16_BURST_FIRST_GAP;
};

// M203.  Mirrors SH_HLSMGTryGrenade exactly — the two weapons carry the same
// launcher, so keeping the shapes identical is what stops them drifting apart.
float(float now) SH_SVM16TryGrenade =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_svm16_grenades <= 0)
    { self.attack_finished = now + SVM16_DRYFIRE_DELAY; return -1; }

    self.ammo_svm16_grenades = self.ammo_svm16_grenades - 1;
    self.weaponstate         = WS_SPECIAL;
    self.wep_action_id       = self.wep_action_id + 1;
    self.wep_anim_start      = now;
    self.attack_finished     = now + SVM16_GRENADE_DELAY;
    return 1;
};

float(float now) SH_SVM16TryReload =
{
    // A reload cancels whatever the burst still had queued — otherwise the
    // queued rounds keep spending from the magazine the reload just refilled.
    if (self.svm16_burst_count > 0)
        self.svm16_burst_count = 0;
    return SH_StandardTryReload(now, mag_svm16, ammo_svm16, MAX_MAG_SVM16, SVM16_RELOAD_DURATION);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

.float svm16_reload_snd_stage;

void(entity player) W_SVM16PickupCopy =
{
    player.mag_svm16           = self.mag_svm16;
    player.ammo_svm16          = self.ammo_svm16;
    player.ammo_svm16_grenades = self.ammo_svm16_grenades;
};

// M203 secondary.  The projectile IS the MP5's contact grenade — same launcher
// in Half-Life and in Sven — so this reuses W_HLSMGGrenadeTouch /
// W_HLSMGGrenadeTick rather than growing a second copy that could drift.
// sh_wpn_hlsmg.qc compiles before this file in both progs.
void() W_SVM16AltFire =
{
    entity gren;
    float r = SH_SVM16TryGrenade(time);

    if (r == 1)
    {
        self.weaponframe   = SVM16_SEQ_LAUNCH;
        self.wep_nextframe = time + SVM16_FRAME_INTERVAL;

        makevectors(self.v_angle);
        gren = spawn();
        gren.owner     = self;
        gren.classname = "proj_smg_grenade";
        gren.movetype  = MOVETYPE_TOSS;
        gren.solid     = SOLID_BBOX;
        setmodel(gren, "models/grenade.mdl");
        setsize(gren, '-2 -2 -2', '2 2 2');
        setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
        gren.velocity  = self.velocity + v_forward * HLSMG_GRENADE_SPEED;
        gren.angles    = W_ModelAngles(gren.velocity, TRUE);   // grenade.mdl is IDST
        gren.avelocity = [-100 - random() * 400, 0, 0];
        gren.gravity   = 0.5;
        gren.touch     = W_HLSMGGrenadeTouch;
        gren.proj_fuse_end = time + 5;
        gren.think     = W_HLSMGGrenadeTick;
        gren.nextthink = time + Toss_NextThinkInterval();
        gren.proj_type  = PROJ_TYPE_SMG_GRENADE;
        gren.SendEntity = projectile_SendEntity;
        gren.SendFlags  = 1;

        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher1.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_SVM16Shoot =
{
    W_PenetratingHitscanShoot(SVM16_BASE_SPREAD, SVM16_MOVE_SPREAD, SVM16_FULL_SPREAD_SPEED,
        SVM16_CLOSE_DAMAGE, SVM16_MIN_DAMAGE, SVM16_DAMAGE_FALLOFF_RANGE, 12, 0.94,
        SVM16_KICK_PITCH, SVM16_KICK_VARIANCE, SVM16_KICK_STRENGTH);
};

void() W_SVM16Fire =
{
    float r = SH_SVM16TryFire(time);

    if (r == 1)
    {
        self.weaponframe   = SH_SVM16PickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + SVM16_FRAME_INTERVAL;

        SH_SVM16QueueBurst(time);
        W_SVM16Shoot();

        // One sample covers the whole burst, so it is played here on the first
        // round and NOT per queued round.  A magazine with only one round left
        // fires a single shot and gets the single-shot sample instead — the same
        // short-burst fallback the They Hunger M16A1 makes.
        if (self.svm16_burst_count >= 2)
            sound(self, CHAN_WEAPON, "weapons/m16_3round.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "weapons/m16_single.wav", 1, ATTN_NORM);
        W_ShellEffect(SHELL_RIFLE, '10 5 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_SVM16Reload =
{
    if (SH_SVM16TryReload(time))
    {
        self.weaponframe   = SVM16_SEQ_RELOAD;
        self.wep_nextframe = time + SVM16_FRAME_INTERVAL;
        self.svm16_reload_snd_stage = 0;
    }
};

void() W_SVM16Frame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += SVM16_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float el = time - self.wep_anim_start;
        if (self.svm16_reload_snd_stage < 1 && el >= SVM16_RELOAD_SND1_TIME)
        { sound(self, CHAN_AUTO, "weapons/m16_magout_metallic.wav", 1, ATTN_NORM); self.svm16_reload_snd_stage = 1; }
        if (self.svm16_reload_snd_stage < 2 && el >= SVM16_RELOAD_SND2_TIME)
        { sound(self, CHAN_AUTO, "weapons/m16_magin_metallic.wav", 1, ATTN_NORM); self.svm16_reload_snd_stage = 2; }
        if (self.svm16_reload_snd_stage < 3 && el >= SVM16_RELOAD_SND3_TIME)
        { sound(self, CHAN_AUTO, "weapons/m16_charge.wav", 1, ATTN_NORM); self.svm16_reload_snd_stage = 3; }
    }

    // Queued burst rounds.  Outside the weaponstate test on purpose: the burst
    // owns the trigger until it has spent what it queued, and must finish even
    // if the state machine has already dropped back toward idle.
    if (self.svm16_burst_count > 0 && time >= self.svm16_burst_next)
    {
        if (self.mag_svm16 > 0)
        {
            self.mag_svm16     -= 1;
            self.wep_action_id += 1;
            W_SVM16Shoot();
            W_ShellEffect(SHELL_RIFLE, '10 5 -4', '6 46 36', '240 720 120');
        }
        self.svm16_burst_count -= 1;
        self.svm16_burst_next   = time + SVM16_BURST_GAP;
    }

    result = SH_SVM16TickState(time);
    if (result & 1)
    {
        // idle carries STUDIO_LOOPING, so the resting pose is safe to hold.
        self.weaponframe   = SVM16_SEQ_IDLE;
        // Idle retire, held back while the burst still has rounds queued: a zero
        // here stops wepframe being called at all, and the block above is the
        // only thing that fires them.  With a 0.633 s state and a burst that
        // finishes 0.17 s in this should never be the deciding test — it is here
        // so shortening the sequence later cannot silently eat two rounds.
        if (self.svm16_burst_count <= 0)
            self.wep_nextframe = 0;
    }
};

void() W_SVM16Equip =
{
    W_StandardEquipSetup(SVM16_VIEWMODEL, SVM16_DISPLAY_NAME, SVM16_SEQ_DRAW,
        SVM16_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_SVM16Fire;
    self.altfire  = W_SVM16AltFire;
    self.reload   = W_SVM16Reload;
    self.wepframe = W_SVM16Frame;
    self.shoot    = W_SVM16Shoot;
    // A burst left queued by the previous draw would otherwise fire its rounds
    // into the new one.
    self.svm16_burst_count = 0;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(SVM16_BASE_SPREAD, SVM16_MOVE_SPREAD, SVM16_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_SVM16Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_svm16  = self.mag_svm16;
    tgt.ammo_svm16 = self.ammo_svm16;
    tgt.ammo_svm16_grenades = self.ammo_svm16_grenades;
    self.mag_svm16  = 0;
    self.ammo_svm16 = 0;
    self.ammo_svm16_grenades = 0;

    setmodel(tgt, SVM16_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_m16";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_SVM16;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_SVM16Equip;
    tgt.weap_drop_func = W_SVM16Drop;
    tgt.pickupcopy     = W_SVM16PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_m16 =
{
    setmodel(self, SVM16_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_m16";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_SVM16;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_SVM16Equip;
    self.weap_drop_func = W_SVM16Drop;
    self.pickupcopy     = W_SVM16PickupCopy;
    self.touch          = weapon_touch;
    self.mag_svm16      = MAX_MAG_SVM16;
    self.ammo_svm16     = MAX_AMMO_SVM16;
    self.ammo_svm16_grenades = MAX_AMMO_SVM16_GRENADES;
    W_RegisterMapWeapon(weapon_m16);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_svm16_reload_snd_stage;

void() CSQC_PredictSVM16Command =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_SVM16TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            SH_SVM16QueueBurst(csqc_pred_time);
            if (CSQC_BeginFireActionEffects())
            {
                // Mirrors W_SVM16Fire: one sample for the whole burst, with the
                // single-shot fallback when the magazine could not supply three.
                if (self.svm16_burst_count >= 2)
                    localsound("weapons/m16_3round.wav");
                else
                    localsound("weapons/m16_single.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(SVM16_BASE_SPREAD, SVM16_MOVE_SPREAD, SVM16_FULL_SPREAD_SPEED,
                    SVM16_CLOSE_DAMAGE, SVM16_MIN_DAMAGE, SVM16_DAMAGE_FALLOFF_RANGE, 12, 0.94,
                    SVM16_KICK_PITCH, SVM16_KICK_VARIANCE, SVM16_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '10 5 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(SVM16_MUZZLE_FORWARD, SVM16_MUZZLE_RIGHT,
                    SVM16_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(SVM16_MUZZLE_FORWARD, SVM16_MUZZLE_RIGHT,
                    SVM16_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Queued burst rounds — the mirror of the block in W_SVM16Frame.  No sound
    // here: the burst's one sample was played on the first round.
    if (self.svm16_burst_count > 0 && csqc_pred_time >= self.svm16_burst_next)
    {
        if (self.mag_svm16 > 0)
        {
            self.mag_svm16     -= 1;
            self.wep_action_id += 1;
            if (CSQC_BeginFireActionEffects())
            {
                CSQC_PredictedPenetratingImpact(SVM16_BASE_SPREAD, SVM16_MOVE_SPREAD, SVM16_FULL_SPREAD_SPEED,
                    SVM16_CLOSE_DAMAGE, SVM16_MIN_DAMAGE, SVM16_DAMAGE_FALLOFF_RANGE, 12, 0.94,
                    SVM16_KICK_PITCH, SVM16_KICK_VARIANCE, SVM16_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/riflecasing.mdl",
                    '10 5 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(SVM16_MUZZLE_FORWARD, SVM16_MUZZLE_RIGHT,
                    SVM16_MUZZLE_DOWN, self.wep_action_id);
                CSQC_EndFireActionEffects();
            }
        }
        self.svm16_burst_count -= 1;
        self.svm16_burst_next   = csqc_pred_time + SVM16_BURST_GAP;
    }

    // M203 on secondary.  The projectile itself is server-spawned and hidden
    // from its owner by projectile_SendEntity, so the shooter gets a local
    // stand-in with the same flight numbers — see the MP5, which carries the
    // same launcher and the same fake.
    if (input_buttons & 4)
    {
        r = SH_SVM16TryGrenade(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/wpn_hlsmg/glauncher1.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash(MUZZLE_TINT_DEFAULT);

                entity gren = spawn();
                makevectors(input_angles);
                setmodel(gren, "models/grenade.mdl");
                setsize(gren, '-2 -2 -2', '2 2 2');
                setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
                gren.owner     = self;
                gren.velocity  = self.velocity + v_forward * HLSMG_GRENADE_SPEED;
                gren.angles    = W_ModelAngles(gren.velocity, TRUE);
                gren.avelocity = [-100 - random() * 400, 0, 0];
                gren.movetype  = MOVETYPE_TOSS;
                gren.solid     = SOLID_BBOX;
                gren.gravity   = 0.5;
                gren.drawmask  = MASK_ENGINE;
                gren.classname            = "csqc_fake_projectile";
                gren.csqc_projectile_type = PROJ_TYPE_SMG_GRENADE;
                gren.touch     = CSQC_FakeHLSMGGrenadeTouch;
                gren.think     = CSQC_FakeHLSMGGrenadeExplode;
                gren.nextthink = time + 5;
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
        if (csqc_svm16_reload_snd_stage < 1 && el >= SVM16_RELOAD_SND1_TIME)
        { localsound("weapons/saw_boxout.wav"); CSQC_RecordPredictedAutoSound(); csqc_svm16_reload_snd_stage = 1; }
        if (csqc_svm16_reload_snd_stage < 2 && el >= SVM16_RELOAD_SND2_TIME)
        { localsound("weapons/saw_boxin.wav"); CSQC_RecordPredictedAutoSound(); csqc_svm16_reload_snd_stage = 2; }
        if (csqc_svm16_reload_snd_stage < 3 && el >= SVM16_RELOAD_SND3_TIME)
        { localsound("weapons/saw_bolt.wav"); CSQC_RecordPredictedAutoSound(); csqc_svm16_reload_snd_stage = 3; }
    }

    SH_SVM16TickState(csqc_pred_time);
};

void() CSQC_PredictSVM16Reload =
{
    if (SH_SVM16TryReload(csqc_pred_time))
    { csqc_svm16_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_SVM16DisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SVM16_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_SVM16PickShootSeq(predicted_player.wep_action_id);
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SVM16_SEQ_LAUNCH;
    if (predicted_player.weaponstate == WS_RELOAD)
        return SVM16_SEQ_RELOAD;
    return SVM16_SEQ_IDLE;   // LOOPING — safe to hold
};

void() CSQC_SVM16DropClear =
{
    self.mag_svm16  = 0;
    self.ammo_svm16 = 0;
    self.ammo_svm16_grenades = 0;
    self.svm16_burst_count = 0;
};

void() CSQC_SVM16Equip =
{
    self.weapon_name         = SVM16_DISPLAY_NAME;
    self.weapon_viewmodel    = SVM16_VIEWMODEL;
    self.weapon_worldmodel   = SVM16_WORLDMODEL;
    self.weapon_deploy_sound = SVM16_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSVM16Command;
    self.csqc_predict_reload = CSQC_PredictSVM16Reload;
    self.csqc_display_frame  = CSQC_SVM16DisplayFrame;
    self.csqc_drop_clear     = CSQC_SVM16DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
