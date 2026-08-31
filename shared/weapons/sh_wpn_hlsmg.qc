// ============================================================
//  shared/weapons/sh_wpn_hlsmg.qc  -  HL MP5/SMG
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 50-round magazine, 250 reserve, full-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//  Alt   : Contact grenade launcher (WS_SPECIAL)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_hlsmg;
.float ammo_hlsmg;
.float ammo_hlsmg_grenades;

// Server-side reload sound latch.  CSQC keeps its own single global (there is
// only ever one predicted player); the server needs one per player.
.float hlsmg_reload_snd_stage;

// --- Sequence indices, read out of valve/models/v_9mmar.mdl (8 seqs) --------
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/wpn_hlsmg/
// v_smg.mdl, an 86-frame flat bake) by frame number.  It now drives Half-Life's
// own IDST model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index -
// gl_hlmdl.c:780 sets mod->numframes = numseq - so every one of the old
// constants was meaningless against it: HLSMG_IDLE_FRAME was 85 and this model
// has eight sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1697 already feeds for weapons that set
// .weapon_uses_sequences.
//
// The indices are the SDK's mp5_e enum verbatim (mp5.cpp:26-35) — it maps 1:1
// onto the model's sequence order, so MP5_LAUNCH == "grenade" == 2 and so on.
//
// Durations below are the sequences' own lengths as the ENGINE measures them:
// (numframes-1)/fps, NOT numframes/fps — an N-frame animation spans N-1
// intervals.  gl_hlmdl.c:1542 is the definition,
//     *duration = (sequence->numframes-1)/sequence->timing;
// and that is exactly what frameduration(), and therefore SH_SeqDuration
// (sh_weapon_standard.qc:399-408), hands back for these same sequences.  The
// SDK hardcodes the same convention — python.cpp:254 uses (70.0/30.0) for a
// 71-frame 30 fps sequence.  Getting this wrong by one frame period is not
// cosmetic: the constants below and SH_SeqDuration would then disagree about
// when the same animation ends.
//
// NB: none of the eight carry STUDIO_LOOPING (every seqdesc has flags=0x0), so
// a sequence left running holds its final pose (gl_hlmdl.c:1076-1081 clamps
// frame1 to numframes-1 when !loop).  HL lives with that because
// CBasePlayerWeapon::WeaponIdle re-sends an idle every 10-15 s
// (mp5.cpp:259-283); we have no m_flTimeWeaponIdle, so the equivalent re-arm is
// open-coded in CSQC_HLSMGDisplayFrame — see the idle driver at the bottom of
// this file.  Without it the viewmodel freezes on idle1's last frame forever.
const float HLSMG_SEQ_LONGIDLE           = 0;   // longidle, 5.000 s  (MP5_LONGIDLE)  41f @  8 fps
const float HLSMG_SEQ_IDLE1              = 1;   // idle1,    3.143 s  (MP5_IDLE1)    111f @ 35 fps
const float HLSMG_SEQ_GRENADE            = 2;   // grenade,  1.100 s  (MP5_LAUNCH)    34f @ 30 fps
const float HLSMG_SEQ_RELOAD             = 3;   // reload,   1.533 s  (MP5_RELOAD)    47f @ 30 fps
const float HLSMG_SEQ_DEPLOY             = 4;   // deploy,   0.917 s  (MP5_DEPLOY)    12f @ 12 fps
const float HLSMG_SEQ_SHOOT1             = 5;   // shoot,    0.600 s  (MP5_FIRE1)      7f @ 10 fps
const float HLSMG_SEQ_SHOOT2             = 6;   // shoot,    0.600 s  (MP5_FIRE2)      7f @ 10 fps
const float HLSMG_SEQ_SHOOT3             = 7;   // shoot,    0.600 s  (MP5_FIRE3)      7f @ 10 fps

const float HLSMG_FRAME_INTERVAL         = 0.05;   // wepframe tick rate, not an anim rate
const float HLSMG_FIRE_DELAY             = 0.1;
const float HLSMG_GRENADE_DELAY          = 1.0;

// Idle fidget cadence.  mp5.cpp:283 re-arms WeaponIdle at
// UTIL_SharedRandomFloat(seed, 10, 15) after each idle it sends, and mp5.cpp:193
// re-arms the same window after every shot.  Consumed by the CSQC idle driver.
const float HLSMG_IDLE_REARM_MIN         = 10;
const float HLSMG_IDLE_REARM_MAX         = 15;

// Reload sound instants, elapsed from wep_anim_start.  These are the reload
// sequence's OWN animation events (ev5004 = client sound), dumped straight out
// of the model rather than carried over from the old bake.  An event ON frame k
// fires k intervals in, so these are frame/fps — the (numframes-1) correction
// above applies to a sequence's LENGTH, not to an instant inside it:
//     frame  5 / 30 fps = 0.167 s  "items/cliprelease1.wav"  (clip drops out)
//     frame 24 / 30 fps = 0.800 s  "items/clipinsert1.wav"   (clip seats)
// The old frame-derived values (0.35 / 1.00) were tuned against the local
// bake's own clip motion; against the real animation they land late, so they
// move to the model's event times.  We keep the mod's own wavs — only the
// instants come from Valve.
// FRACTIONS of the reload take, not absolute times — the take is 1.533 s on
// valve's model and 1.600 s on svencoop's.  These are valve's own studio events
// (frames 5 and 24 of 47 @ 30 fps); svencoop puts them at 0.183 / 0.667, close
// enough that one pair of numbers reads correctly on both.  The old absolutes
// were 0.167 / 0.800, i.e. 0.109 / 0.522 of valve's take — the same instants,
// just expressed in a way that did not survive a longer animation.
const float HLSMG_RELOAD_F_SND1          = 0.109;  // reload1.wav (clip out)
const float HLSMG_RELOAD_F_SND2          = 0.522;  // reload2.wav (clip in)

const float MAX_MAG_HLSMG                = 50;     // MP5_MAX_CLIP, weapons.h:129
const float MAX_AMMO_HLSMG               = 250;
const float MAX_AMMO_HLSMG_GRENADES      = 2;

// --- Balance ---
const float HLSMG_BASE_SPREAD            = 0.01;
const float HLSMG_MOVE_SPREAD            = 0.08;
const float HLSMG_FULL_SPREAD_SPEED      = 320;
const float HLSMG_CLOSE_DAMAGE           = 10;
const float HLSMG_MIN_DAMAGE             = 5;
const float HLSMG_DAMAGE_FALLOFF_RANGE   = 2048;
const float HLSMG_DRYFIRE_DELAY          = 0.2;
const float HLSMG_KICK_PITCH    = 0.7;   // sv_gunkick — SMG, light per-shot kick that builds.
const float HLSMG_KICK_VARIANCE = 0.3;
const float HLSMG_KICK_STRENGTH = 1.5;  // SMG.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float HLSMG_MUZZLE_FORWARD = 42;
const float HLSMG_MUZZLE_RIGHT   = 4.5;
const float HLSMG_MUZZLE_DOWN    = 6.5;

// --- Grenade balance ---
const float HLSMG_GRENADE_SPEED          = 1000;
const float HLSMG_GRENADE_DAMAGE         = 100;
const float HLSMG_GRENADE_MIN_DAMAGE     = 10;
const float HLSMG_GRENADE_RADIUS         = 250;

// --- State durations, taken from the sequences themselves ---
// Each state lasts exactly as long as the sequence it plays, measured the way
// the engine measures it ((numframes-1)/fps, see the sequence table above).
// The state ending is what snaps the viewmodel back to idle: a state shorter
// than its sequence truncates the animation mid-motion, a longer one leaves the
// gun sitting on the final pose before the snap.  Deltas from the old local
// bake, for whoever is reading a bug report later:
//   draw     0.400 -> 0.917  the deploy sequence really is 12f @ 12 fps
//   fire     0.300 -> 0.600  the shoot sequences are 7f @ 10 fps
//   grenade  1.100 -> 1.100  unchanged — the bake happened to be cut to length
//   reload   1.550 -> 1.533  (SDK asks for 1.5, mp5.cpp:255)
// Nothing here gates the rate of fire — that is HLSMG_FIRE_DELAY, untouched at
// 0.1 s, and SH_HLSMGTryFire does not bail on WS_FIRE.  What the longer FIRE
// duration does change is that reload and the grenade launcher, which both
// require WS_IDLE, unblock 0.6 s after the last shot instead of 0.3 s.
//
// DRAW is the one place where matching the sequence costs more than it looks:
// SH_StandardTryFire bails on WS_DRAW (sh_weapon_standard.qc:211), so the whole
// 0.917 s deploy is a no-fire window, where the old bake's was 0.4 s.  The SDK
// is looser — DefaultDeploy plays the full MP5_DEPLOY sequence but frees the
// trigger half-way through, `m_flNextAttack = UTIL_WeaponTimeBase() + 0.5`
// (weapons.cpp:1016).  Reproducing that needs a per-weapon early-unlock the
// shared fire path does not offer, and shortening the state instead would cut
// the deploy animation off at 0.5 s, so the state stays sequence-length.
//
// FALLBACKS ONLY.  The sequence PICKS below already ask the model by name
// through both spellings; the LENGTHS did not, and svencoop's v_9mmar.mdl — the
// one that actually wins the mount — is a different length in every state:
// deploy 0.917 -> 0.667, shoot 0.600 -> 0.400, reload 1.533 -> 1.600.  Its
// `launch` take is authored at 0 fps, which reports a zero duration; SH_SeqDuration
// already treats that as "no answer" and hands back the fallback, so the grenade
// keeps valve's 1.100 s on either model.
const float HLSMG_DRAW_DURATION          = 0.917;   // deploy
const float HLSMG_FIRE_DURATION          = 0.600;   // shoot x3 (all three are the same length)
const float HLSMG_GRENADE_DURATION       = 1.100;   // grenade
const float HLSMG_RELOAD_DURATION        = 1.533;   // reload

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling — the SDK writes "v_9mmAR.mdl" (mp5.cpp:64-66) but the shipped files
// are all lowercase, and FTE's VFS is case-sensitive against real files on Linux.
const string HLSMG_VIEWMODEL    = "models/v_9mmar.mdl";
const string HLSMG_WORLDMODEL   = "models/w_9mmar.mdl";
const string HLSMG_DEPLOY_SOUND = "";
const string HLSMG_DISPLAY_NAME = "SMG";

// ============================================================
//  SHARED — sequence resolution
// ============================================================
//
// THE INDICES ABOVE ARE NOT SAFE ON THEIR OWN, because "models/v_9mmar.mdl" is a
// bare mount path and fs_addons.txt mounts valve, gearbox, bshift AND svencoop at
// once.  All four ship that filename with DIFFERENT layouts — dumped from the
// files, not recalled:
//
//   valve          0 longidle  1 idle1  2 grenade  3 reload  4 deploy
//                  5 shoot     6 shoot  7 shoot
//   gearbox/bshift 0 longidle  1 idle1  2 grenade  3 reload  4 deploy  5 deploy
//                  6 shoot     7 shoot  8 shoot          <- everything shifts by 1
//   svencoop       0 longidle  1 idle   2 launch   3 reload  4 deploy
//                  5 fire1     6 fire2  7 fire3          <- different NAMES
//
// So the hardcoded 5/6/7 was a live bug on a gearbox or Blue Shift install: index
// 5 there is the SECOND deploy, and the first third of all shots played the draw
// animation instead of a muzzle take.
//
// The shoot takes are resolved as a BASE plus two, not three separate lookups,
// because valve and gearbox label all three identically — frameforname returns the
// first match and could never distinguish 2 from 3.  Contiguity is verified on all
// four models above; it is the only assumption here, and it is what makes one
// lookup fix all three indices on every mount.
float() SH_HLSMGSeqShootBase =
{
    return SH_SeqForName2(HLSMG_VIEWMODEL, "shoot", "fire1", HLSMG_SEQ_SHOOT1);
};
float() SH_HLSMGSeqDeploy  = { return SH_SeqForName(HLSMG_VIEWMODEL, "deploy",   HLSMG_SEQ_DEPLOY); };
float() SH_HLSMGSeqReload  = { return SH_SeqForName(HLSMG_VIEWMODEL, "reload",   HLSMG_SEQ_RELOAD); };
// Sven renames the grenade take "launch"; valve/gearbox call it "grenade".
float() SH_HLSMGSeqGrenade = { return SH_SeqForName2(HLSMG_VIEWMODEL, "grenade", "launch", HLSMG_SEQ_GRENADE); };
float() SH_HLSMGSeqLongIdle= { return SH_SeqForName(HLSMG_VIEWMODEL, "longidle", HLSMG_SEQ_LONGIDLE); };
// ...and "idle1" "idle" for the same reason.
float() SH_HLSMGSeqIdle1   = { return SH_SeqForName2(HLSMG_VIEWMODEL, "idle1", "idle", HLSMG_SEQ_IDLE1); };

// ...and the LENGTHS come off the same live sequences, for the same reason the
// picks do — see the FALLBACKS ONLY note above the duration constants.
float() SH_HLSMGDrawDuration    = { return SH_SeqDuration(HLSMG_VIEWMODEL, SH_HLSMGSeqDeploy(),    HLSMG_DRAW_DURATION); };
float() SH_HLSMGFireDuration    = { return SH_SeqDuration(HLSMG_VIEWMODEL, SH_HLSMGSeqShootBase(), HLSMG_FIRE_DURATION); };
float() SH_HLSMGGrenadeDuration = { return SH_SeqDuration(HLSMG_VIEWMODEL, SH_HLSMGSeqGrenade(),   HLSMG_GRENADE_DURATION); };
float() SH_HLSMGReloadDuration  = { return SH_SeqDuration(HLSMG_VIEWMODEL, SH_HLSMGSeqReload(),    HLSMG_RELOAD_DURATION); };

// ============================================================
//  SHARED — sequence-pick + state machine
//  Manual tick (like M3) to handle WS_FIRE + WS_SPECIAL + WS_RELOAD
// ============================================================

// The model carries THREE identically-named "shoot" sequences (5/6/7) and the
// SDK picks one per shot: mp5.cpp's PrimaryAttack never calls SendWeaponAnim at
// all, it fires the m_usMP5 event, and ev_hldm.cpp:705 does
//     EV_WeaponAnimation( MP5_FIRE1 + RandomLong(0,2), 2 )
//
// The pick has to land on the same sequence in SSQC and CSQC or the predicted
// viewmodel visibly disagrees with the one the server thinks is playing, so it
// is hashed off wep_action_id (the same deterministic shared-random the spread
// uses) rather than random().  Takes the seed as an argument because the server
// reads it off `self` and the client off `predicted_player`.
float(float action_id) SH_HLSMGPickShootSeq =
{
    float r = SH_SpreadHash(action_id);
    float base = SH_HLSMGSeqShootBase();
    if (r < 0.34) return base;
    if (r < 0.67) return base + 1;
    return base + 2;
};

float(float now) SH_HLSMGTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_HLSMGDrawDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_HLSMGFireDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_HLSMGGrenadeDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SH_HLSMGReloadDuration())
        {
            // Apply reload ammo
            float need = MAX_MAG_HLSMG - self.mag_hlsmg;
            float give = min(need, self.ammo_hlsmg);
            self.mag_hlsmg  += give;
            self.ammo_hlsmg -= give;
            SH_WeaponEnterIdle();
            return 1 | 2;
        }
        return 0;
    }
    return 0;
};

float(float now) SH_HLSMGTryFire =
{
    if (self.weaponstate == WS_RELOAD || self.weaponstate == WS_DRAW || self.weaponstate == WS_SPECIAL)
        return 0;
    return SH_StandardTryFire(now, mag_hlsmg, HLSMG_FIRE_DELAY, HLSMG_DRYFIRE_DELAY);
};

float(float now) SH_HLSMGTryGrenade =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.ammo_hlsmg_grenades <= 0)
    { self.attack_finished = now + HLSMG_DRYFIRE_DELAY; return -1; }

    self.ammo_hlsmg_grenades -= 1;
    self.weaponstate          = WS_SPECIAL;
    self.wep_action_id       += 1;
    self.wep_anim_start       = now;
    self.attack_finished      = now + HLSMG_GRENADE_DELAY;
    return 1;
};

float(float now) SH_HLSMGTryReload =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_hlsmg >= MAX_MAG_HLSMG || self.ammo_hlsmg <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_HLSMGPickupCopy =
{
    player.mag_hlsmg           = self.mag_hlsmg;
    player.ammo_hlsmg          = self.ammo_hlsmg;
    player.ammo_hlsmg_grenades = self.ammo_hlsmg_grenades;
};

void() W_HLSMGShoot =
{
    W_PenetratingHitscanShoot(HLSMG_BASE_SPREAD, HLSMG_MOVE_SPREAD, HLSMG_FULL_SPREAD_SPEED,
        HLSMG_CLOSE_DAMAGE, HLSMG_MIN_DAMAGE, HLSMG_DAMAGE_FALLOFF_RANGE, 24, 0.95,
        HLSMG_KICK_PITCH, HLSMG_KICK_VARIANCE, HLSMG_KICK_STRENGTH);
};

// Grenade explosion — radius damage
void() W_HLSMGGrenadeExplode =
{
    // Exclude shooter from explosion effects — they see the client-predicted one
    float saved_dim = dimension_send;
    if (self.owner)
        dimension_send = dimension_send & ~self.owner.dimension_seen;

    te_explosion(self.origin + '0 0 8');

    dimension_send = saved_dim;

    // Radius damage + player knockback + phys-drop blast — single call.
    W_RadiusExplode(self.origin, HLSMG_GRENADE_RADIUS,
                    HLSMG_GRENADE_DAMAGE, HLSMG_GRENADE_MIN_DAMAGE,
                    800, 350, self.owner);

    remove(self);
};

void() W_HLSMGGrenadeTouch =
{
    if (other == self.owner)
        return;
    W_HLSMGGrenadeExplode();
};

// Periodic tick, the same shape as W_GrenadeProjectileTick.  Needed the moment
// this grenade became a CSQC projectile: SendFlags has to be pulsed for the
// client entity to receive a position update, and the grenade's only think used
// to be its 5 s fuse — so a fuse-only think meant ONE update in its whole life
// and no interpolation at all for anyone but the shooter.
void() W_HLSMGGrenadeTick =
{
    self.SendFlags |= 1;
    if (time >= self.proj_fuse_end)
    {
        W_HLSMGGrenadeExplode();   // removes self
        return;
    }
    self.nextthink = time + Toss_NextThinkInterval();
};

void() W_HLSMGFire =
{
    float r = SH_HLSMGTryFire(time);

    if (r == 1)
    {
        // One of the three "shoot" sequences — see SH_HLSMGPickShootSeq.
        // SH_StandardTryFire has already bumped wep_action_id
        // (sh_weapon_standard.qc:227), so this seeds off the new shot's id and
        // CSQC_HLSMGDisplayFrame reproduces the same pick from the same id.
        self.weaponframe   = SH_HLSMGPickShootSeq(self.wep_action_id);
        self.wep_nextframe = time + HLSMG_FRAME_INTERVAL;

        W_HLSMGShoot();

        float snd = random();
        if (snd < 0.333)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire1.wav", 1, ATTN_NORM);
        else if (snd < 0.666)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire2.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire3.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_HLSMGAltFire =
{
    float r;
    entity gren;

    r = SH_HLSMGTryGrenade(time);
    if (r == 1)
    {
        // SecondaryAttack likewise animates through its event, not directly:
        // ev_hldm.cpp:749 plays MP5_LAUNCH — the "grenade" sequence.
        self.weaponframe   = SH_HLSMGSeqGrenade();
        self.wep_nextframe = time + HLSMG_FRAME_INTERVAL;

        // Spawn grenade projectile
        makevectors(self.v_angle);
        gren = spawn();
        gren.owner     = self;
        gren.classname = "proj_smg_grenade";
        gren.movetype  = MOVETYPE_TOSS;
        gren.solid     = SOLID_BBOX;
        // Half-Life's own mesh (ggrenade.cpp:351), out of the mounted valve tree,
        // rather than the local grenade-launcher conversion this used to borrow.
        setmodel(gren, "models/grenade.mdl");
        setsize(gren, '-2 -2 -2', '2 2 2');
        setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
        // mp5.cpp:230 is `gpGlobals->v_forward * 800` with NO up component, and
        // ggrenade.cpp:364 sets gravity 0.5.  This fired at 1000 u/s with a
        // +120 up-kick and gravity 1 — a flat, fast, short arc that was barely
        // on screen, which is the "smg nade is still invisible" report.
        gren.velocity  = self.velocity + v_forward * HLSMG_GRENADE_SPEED;
        // ggrenade.cpp:367 — CGrenade::ShootContact points the grenade along its
        // velocity before adding spin.  This was never set, so the grenade
        // launched at angles '0 0 0' and only drifted from there under avelocity;
        // whatever it looked like, it was never pointing where it was going.
        // models/grenade.mdl is IDST, so the pitch IS negated — see W_ModelAngles.
        gren.angles    = W_ModelAngles(gren.velocity, TRUE);
        // ggrenade.cpp:375 spins on PITCH ONLY (avelocity.x, -100..-500) — a
        // grenade tumbling end over end, not spinning on all three axes at once.
        gren.avelocity = [-100 - random() * 400, 0, 0];
        gren.gravity   = 0.5;
        gren.touch     = W_HLSMGGrenadeTouch;
        gren.proj_fuse_end = time + 5;
        gren.think     = W_HLSMGGrenadeTick;
        gren.nextthink = time + Toss_NextThinkInterval();

        // Route through the CSQC projectile system like EVERY other projectile
        // in the mod (GL, RPG, crossbow bolt, displacer orb).  This was the only
        // one that did not, and the consequence was severe for observers: with
        // no SendEntity it reached them through plain delta replication at the
        // server's think rate for this entity — and its only think is the 5 s
        // fuse, so it was effectively replicated once in its whole life and
        // never interpolated.  proj_type also gives it CSQC_TossPredraw
        // smoothing and owner-hiding, which is what nodrawtoclient was doing by
        // hand.
        gren.proj_type  = PROJ_TYPE_SMG_GRENADE;
        gren.SendEntity = projectile_SendEntity;
        gren.SendFlags  = 1;

        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher2.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_HLSMGReload =
{
    if (SH_HLSMGTryReload(time))
    {
        // mp5.cpp:255 — DefaultReload( MP5_MAX_CLIP, MP5_RELOAD, 1.5 ).  Only
        // one reload sequence exists on this model, so unlike the glock there
        // is no empty/not-empty variant to choose between here.
        self.weaponframe   = SH_HLSMGSeqReload();
        self.wep_nextframe = time + HLSMG_FRAME_INTERVAL;
        self.hlsmg_reload_snd_stage = 0;
    }
};

void() W_HLSMGFrame =
{
    float result;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of an eight-sequence model
    // within half a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1697), so this function only has to decide
    // WHICH sequence is playing and when the state ends.
    self.wep_nextframe += HLSMG_FRAME_INTERVAL;

    // Reload sounds moved from frame numbers to elapsed time, which is what the
    // CSQC half of this file already did (it had no frame counter to key off) —
    // so the two sides now share one set of constants instead of two
    // representations of the same instants.
    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        float rel_dur = SH_HLSMGReloadDuration();
        if (self.hlsmg_reload_snd_stage < 1
            && reload_elapsed >= rel_dur * HLSMG_RELOAD_F_SND1)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlsmg/reload1.wav", 1, ATTN_NORM);
            self.hlsmg_reload_snd_stage = 1;
        }
        if (self.hlsmg_reload_snd_stage < 2
            && reload_elapsed >= rel_dur * HLSMG_RELOAD_F_SND2)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlsmg/reload2.wav", 1, ATTN_NORM);
            self.hlsmg_reload_snd_stage = 2;
        }
    }

    result = SH_HLSMGTickState(time);
    if (result & 1)
    {
        // Idle retire: park .weaponframe on the resting sequence and stop
        // ticking until the next action re-arms wep_nextframe.  The
        // longidle/idle1 fidget cycle mp5.cpp:259-283 runs lives in
        // CSQC_HLSMGDisplayFrame, not here — the viewmodel the player sees is
        // the CSQC one, and this function is retired for the whole idle anyway,
        // so it could not drive a cycle even if it wanted to.
        self.weaponframe   = SH_HLSMGSeqIdle1();
        self.wep_nextframe = 0;
    }
};

void() W_HLSMGEquip =
{
    W_StandardEquipSetup(HLSMG_VIEWMODEL, HLSMG_DISPLAY_NAME, SH_HLSMGSeqDeploy(),
        HLSMG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_HLSMGFire;
    self.reload   = W_HLSMGReload;
    self.wepframe = W_HLSMGFrame;
    self.shoot    = W_HLSMGShoot;
    self.altfire  = W_HLSMGAltFire;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(HLSMG_BASE_SPREAD, HLSMG_MOVE_SPREAD, HLSMG_FULL_SPREAD_SPEED, 1.85, TRUE);
};

void() W_HLSMGDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_hlsmg           = self.mag_hlsmg;
    tgt.ammo_hlsmg          = self.ammo_hlsmg;
    tgt.ammo_hlsmg_grenades = self.ammo_hlsmg_grenades;

    self.mag_hlsmg           = 0;
    self.ammo_hlsmg          = 0;
    self.ammo_hlsmg_grenades = 0;

    setmodel(tgt, HLSMG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_hlsmg";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_HLSMG;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_HLSMGEquip;
    tgt.weap_drop_func = W_HLSMGDrop;
    tgt.pickupcopy   = W_HLSMGPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_hlsmg =
{
    setmodel(self, HLSMG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_hlsmg";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_HLSMG;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_HLSMGEquip;
    self.weap_drop_func = W_HLSMGDrop;
    self.pickupcopy    = W_HLSMGPickupCopy;
    self.touch         = weapon_touch;
    self.mag_hlsmg           = MAX_MAG_HLSMG;
    self.ammo_hlsmg          = MAX_AMMO_HLSMG;
    self.ammo_hlsmg_grenades = MAX_AMMO_HLSMG_GRENADES;
    W_RegisterMapWeapon(weapon_hlsmg);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_hlsmg_reload_snd_stage;

void() CSQC_FakeHLSMGGrenadeExplode =
{
    pointsound(self.origin, "sounds/weapons/explode1.wav", 1, ATTN_NORM);
    te_explosion(self.origin + '0 0 8');
    remove(self);
};

void() CSQC_FakeHLSMGGrenadeTouch =
{
    if (other == self.owner)
        return;
    CSQC_FakeHLSMGGrenadeExplode();
};

void() CSQC_PredictHLSMGCommand =
{
    float r;

    // Alt-fire: grenade launcher
    if (input_buttons & 4)
    {
        r = SH_HLSMGTryGrenade(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                if (random() < 0.5)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher1.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/glauncher2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash(MUZZLE_TINT_DEFAULT);

                // Spawn fake grenade projectile for instant visual
                {
                    entity gren = spawn();
                    makevectors(input_angles);
                    setmodel(gren, "models/grenade.mdl");
                    setsize(gren, '-2 -2 -2', '2 2 2');
                    setorigin(gren, self.origin + self.view_ofs + v_forward * 16);
                    gren.owner     = self;
                    // Mirrors the server spawn above — HL's 800 u/s with no
                    // up-kick and gravity 0.5.  These MUST match or the
                    // shooter's fake and everyone else's networked twin fly
                    // different arcs.
                    gren.velocity  = self.velocity + v_forward * HLSMG_GRENADE_SPEED;
                    gren.angles    = W_ModelAngles(gren.velocity, TRUE);
                    gren.avelocity = [-100 - random() * 400, 0, 0];
                    gren.movetype  = MOVETYPE_TOSS;
                    gren.solid     = SOLID_BBOX;
                    gren.gravity   = 0.5;
                    gren.drawmask  = MASK_ENGINE;
                    // Trail, as the networked twin already gets: the server
                    // grenade is PROJ_TYPE_GRENADE, which cl_throwtrail.qc
                    // already trails for everyone EXCEPT the shooter, since
                    // projectile_SendEntity hides it from its owner.  This fake
                    // is the shooter's only copy, and untagged it was a bare
                    // 16-unit model crossing a room at 1000 u/s -- the reported
                    // "smg nade is invisible when flying through the air".
                    gren.classname            = "csqc_fake_projectile";
                    gren.csqc_projectile_type = PROJ_TYPE_SMG_GRENADE;
                    gren.touch     = CSQC_FakeHLSMGGrenadeTouch;
                    gren.think     = CSQC_FakeHLSMGGrenadeExplode;
                    gren.nextthink = time + 5;
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

    // Primary fire: auto hitscan
    if (input_buttons & 1)
    {
        r = SH_HLSMGTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                float snd = random();
                if (snd < 0.333)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire1.wav", 1, ATTN_NONE);
                else if (snd < 0.666)
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire2.wav", 1, ATTN_NONE);
                else
                    sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlsmg/fire3.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(HLSMG_BASE_SPREAD, HLSMG_MOVE_SPREAD, HLSMG_FULL_SPREAD_SPEED,
                    HLSMG_CLOSE_DAMAGE, HLSMG_MIN_DAMAGE, HLSMG_DAMAGE_FALLOFF_RANGE, 24, 0.95,
                    HLSMG_KICK_PITCH, HLSMG_KICK_VARIANCE, HLSMG_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                // SMG muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(HLSMG_MUZZLE_FORWARD, HLSMG_MUZZLE_RIGHT,
                    HLSMG_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(HLSMG_MUZZLE_FORWARD, HLSMG_MUZZLE_RIGHT,
                    HLSMG_MUZZLE_DOWN, self.wep_action_id, 1);
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

    // Predicted reload sounds, at the reload sequence's own event times.
    // HLSMG_RELOAD_SND1_TIME / _SND2_TIME are declared once at the top of the
    // file and shared with the server half — they used to be derived here from
    // frame numbers that no longer exist.
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float rel_dur = SH_HLSMGReloadDuration();

        if (csqc_hlsmg_reload_snd_stage < 1 && reload_elapsed >= rel_dur * HLSMG_RELOAD_F_SND1)
        { localsound("sounds/weapons/wpn_hlsmg/reload1.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsmg_reload_snd_stage = 1; }
        if (csqc_hlsmg_reload_snd_stage < 2 && reload_elapsed >= rel_dur * HLSMG_RELOAD_F_SND2)
        { localsound("sounds/weapons/wpn_hlsmg/reload2.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsmg_reload_snd_stage = 2; }
    }

    SH_HLSMGTickState(csqc_pred_time);
};

void() CSQC_PredictHLSMGReload =
{
    if (SH_HLSMGTryReload(csqc_pred_time))
    { csqc_hlsmg_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, so the `elapsed`
// argument is no longer used here — it stays in the signature because
// csqc_display_frame is a shared function pointer type.
//
// Idle needs more than a returned index, because none of this model's
// sequences is flagged loop.  SH_WeaponEnterIdle zeroes wep_anim_start
// (sh_weapon_logic.qc:410-413), which sends the dispatcher down its
// `elapsed = cltime` branch (cl_weapons.qc:1694-1695) — absolute level time,
// hundreds of seconds — and gl_hlmdl.c:1076-1081 clamps a non-looping sequence
// to numframes-1.  The glock gets away with returning a bare idle index only
// because v_9mmhandgun.mdl's idles carry STUDIO_LOOPING; v_9mmar.mdl's do not,
// so copying it verbatim would pin the SMG on idle1's final frame for the rest
// of the round and the fidget would never play once.
//
// So drive it: anchor a local sequence time at the idle edge and hand it to the
// renderer through csqc_viewmodel_sequence_time_override (cl_customdefs.qc:137-138,
// consumed at cl_weapons.qc:1690-1691), then roll a fresh idle every 10-15 s the
// way CMP5::WeaponIdle does (mp5.cpp:259-283, RANDOM_LONG(0,1) over
// MP5_LONGIDLE / MP5_IDLE1).  Between rolls the sequence runs out and the engine
// holds its last frame — that hold is HL's look too, it is only the never-being
// re-armed that was wrong.  We differ from the SDK on one point: HL waits out
// m_flTimeWeaponIdle before the FIRST idle after an action, holding the previous
// animation's end pose, whereas this starts idle1 as soon as the state goes idle
// — the previous sequence is already gone by then, so waiting would just
// reinstate the frozen pose this exists to fix.
//
// Cosmetic and CSQC-local: nothing here feeds prediction, so the random() picks
// need not agree with the server (which has no fidget — see W_HLSMGFrame).
float csqc_hlsmg_idle_anchor;       // cltime the current idle sequence started at
float csqc_hlsmg_idle_seq;          // which of the two idles is playing
float csqc_hlsmg_idle_next;         // cltime to roll the next one
float csqc_hlsmg_prev_seen_state;

void(float now) CSQC_HLSMGRollIdle =
{
    csqc_hlsmg_idle_seq    = (random() < 0.5) ? SH_HLSMGSeqLongIdle() : SH_HLSMGSeqIdle1();
    csqc_hlsmg_idle_anchor = now;
    csqc_hlsmg_idle_next   = now + HLSMG_IDLE_REARM_MIN
                           + random() * (HLSMG_IDLE_REARM_MAX - HLSMG_IDLE_REARM_MIN);
};

float(float elapsed) CSQC_HLSMGDisplayFrame =
{
    float ws = predicted_player.weaponstate;

    // Capture the (non-idle -> idle) edge so the idle below always starts from
    // frame 0.  Display runs once per render frame, so prev_seen_state tracks
    // the previous frame's state.  WS_IDLE is 0 and so is the initial value of
    // prev_seen_state, so the very first idle frame after a level load misses
    // this edge — harmless, csqc_hlsmg_idle_next is 0 then and the roll below
    // fires immediately instead.
    if (ws == WS_IDLE && csqc_hlsmg_prev_seen_state != WS_IDLE)
    {
        CSQC_HLSMGRollIdle(cltime);
        csqc_hlsmg_idle_seq = SH_HLSMGSeqIdle1();   // first one is always the subtler of the two
    }
    csqc_hlsmg_prev_seen_state = ws;

    if (ws == WS_DRAW)
        return SH_HLSMGSeqDeploy();
    if (ws == WS_FIRE)
        return SH_HLSMGPickShootSeq(predicted_player.wep_action_id);
    if (ws == WS_SPECIAL)
        return SH_HLSMGSeqGrenade();
    if (ws == WS_RELOAD)
        return SH_HLSMGSeqReload();

    if (cltime >= csqc_hlsmg_idle_next)
        CSQC_HLSMGRollIdle(cltime);

    csqc_viewmodel_sequence_time_override = TRUE;
    csqc_viewmodel_sequence_time = max(0, cltime - csqc_hlsmg_idle_anchor);
    return csqc_hlsmg_idle_seq;
};

void() CSQC_HLSMGDropClear =
{
	self.mag_hlsmg = 0;
	self.ammo_hlsmg = 0;
	self.ammo_hlsmg_grenades = 0;
};

void() CSQC_HLSMGEquip =
{
	self.weapon_name         = HLSMG_DISPLAY_NAME;
	self.weapon_viewmodel    = HLSMG_VIEWMODEL;
	self.weapon_worldmodel   = HLSMG_WORLDMODEL;
	self.weapon_deploy_sound = HLSMG_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictHLSMGCommand;
	self.csqc_predict_reload = CSQC_PredictHLSMGReload;
	self.csqc_display_frame  = CSQC_HLSMGDisplayFrame;
	self.csqc_drop_clear     = CSQC_HLSMGDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
