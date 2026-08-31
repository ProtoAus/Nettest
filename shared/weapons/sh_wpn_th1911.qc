// ============================================================
//  shared/weapons/sh_wpn_th1911.qc  -  They Hunger Colt M1911A1
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 7-round magazine, 250 reserve, fires while held
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE.  Everything below traces to one of two sources on disk, and
//  where the two disagree the deviation is called out rather than smoothed
//  over:
//    - Sven Co-op's They Hunger script, which is what the campaign actually
//      runs:  svencoop/scripts/maps/hunger/weapons/weapon_colt1911.as
//    - the model itself, hunger/weapons/colt/v_1911.mdl, dumped for sequence
//      indices, frame counts and frame rates
//
//  This weapon used to exist only as a PICKUP ALIAS: weapon_colt1911 in
//  server/sv_goldsrc_pickups.qc dressed a WEP_HLGLOCK in the 1911's world
//  model, so picking one up handed you a Half-Life Glock wearing a Colt.  The
//  v_ and p_ models shipped in the mount and went unused.  That alias is now
//  a thin wrapper around this weapon.

// --- Ammo fields ---
.float mag_th1911;
.float ammo_th1911;

// Server-side reload sound latch.  CSQC keeps its own single global (there is
// only ever one predicted player); the server needs one per player.
.float th1911_reload_snd_stage;

// --- Sequence indices, read out of hunger/weapons/colt/v_1911.mdl (10 seqs) --
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index —
// gl_hlmdl.c:780 sets mod->numframes = numseq.  The engine animates WITHIN the
// sequence from .frame1time, which cl_weapons.qc:1697 feeds for every weapon
// that sets .weapon_uses_sequences.
//
// The model's $sequence labels and the script's TheyHungerM1911A1Animation_e
// enum (weapon_colt1911.as:19-31) agree index for index, so both names below
// are the same name.
//
// Durations are (numframes-1)/fps, which is what the ENGINE reports through
// frameduration() — gl_hlmdl.c:1542,
//     *duration = (sequence->numframes-1)/sequence->timing;
// — because an N-frame animation spans N-1 intervals.  The obvious
// numframes/fps overstates every one of them by a frame period AND puts these
// constants at odds with SH_SeqDuration, which asks the engine.
//
// NOT ONE of the ten carries STUDIO_LOOPING (every seqdesc has flags=0).  See
// the idle note on TH1911_IDLE_REARM_MIN below.
const float TH1911_SEQ_IDLE          = 0;   // idle,          5.967 s  (180f @ 30)
const float TH1911_SEQ_SHOOT         = 1;   // shoot,         0.967 s  ( 30f @ 30)
const float TH1911_SEQ_SHOOT_EMPTY   = 2;   // shoot_empty,   0.967 s  ( 30f @ 30)
const float TH1911_SEQ_RELOAD        = 3;   // reload,        2.633 s  ( 80f @ 30)
const float TH1911_SEQ_RELOAD_EMPTY  = 4;   // reload_empty,  3.133 s  ( 95f @ 30)
const float TH1911_SEQ_DRAW          = 5;   // draw,          0.967 s  ( 30f @ 30)
const float TH1911_SEQ_HOLSTER       = 6;   // holster,       0.467 s  ( 15f @ 30)  (no holster state exists here)
const float TH1911_SEQ_FIDGET1       = 7;   // fidget1,       0.967 s  ( 30f @ 30)
const float TH1911_SEQ_FIDGET2       = 8;   // fidget2,       0.967 s  ( 30f @ 30)
const float TH1911_SEQ_FIDGET3       = 9;   // fidget3,       0.967 s  ( 30f @ 30)

const float TH1911_FRAME_INTERVAL    = 0.05;   // wepframe tick rate, not an anim rate

// weapon_colt1911.as:171.  DELIBERATELY NOT the mod's handgun convention:
// every other pistol here (M9, USP, Deagle, .357) goes through
// SH_StandardTryFireSemiAuto, which needs a fresh trigger press per shot.
// CBasePlayerWeapon::ItemPostFrame calls PrimaryAttack for as long as
// IN_ATTACK is held, and this script sets m_flNextPrimaryAttack to 0.135 s,
// so the campaign's 1911 really does empty its seven rounds in under a second
// on a held trigger.  Promoting the weapon means bringing that with it.
// (:170 gives 0.2 s underwater instead; this mod has no per-weapon waterlevel
// hook, so the surface figure is used throughout.)
const float TH1911_FIRE_DELAY        = 0.135;

// Idle re-send cadence.  weapon_colt1911.as:199 re-arms m_flTimeWeaponIdle at
// RandomFloat(10, 15) after every shot and :288 at SharedRandomFloat(5, 7)
// after every idle.  The wider window is the one that matters — with no
// looping sequence in the model, something has to re-send an idle or the
// viewmodel clamps to its final frame and never moves again
// (gl_hlmdl.c:1076-1082).  SH_SeqIdleDisplay does the re-sending.
const float TH1911_IDLE_REARM_MIN    = 10;
const float TH1911_IDLE_REARM_MAX    = 15;

// Reload sound instants, elapsed from wep_anim_start.  The script fires these
// from animation events rather than fixed offsets; these are the points in the
// 2.633 s / 3.133 s sequences where the magazine visibly leaves, seats, and
// (empty variant only) the slide runs forward.
const float TH1911_RELOAD_MAGOUT_TIME = 0.500;
const float TH1911_RELOAD_MAGIN_TIME  = 1.500;
const float TH1911_RELOAD_SLIDE_TIME  = 2.600;   // reload_empty only

const float MAX_MAG_TH1911           = 7;     // COLT_MAX_CLIP,    weapon_colt1911.as:15
const float MAX_AMMO_TH1911          = 250;   // COLT_MAX_CARRY,   weapon_colt1911.as:13

// --- Balance ---
// SPREAD UNITS.  Half-Life's VECTOR_CONE_n_DEGREES constants are literally the
// sine of the half-angle in each axis (util.h), and this mod's spread argument
// scales v_right/v_up the same way — so a cone constant transfers across
// unchanged.  weapon_colt1911.as:185 fires VECTOR_CONE_2DEGREES = 0.01745.
const float TH1911_BASE_SPREAD          = 0.01745;   // VECTOR_CONE_2DEGREES
const float TH1911_MOVE_SPREAD          = 0.07;      // this mod's own; ~4x base, as the other pistols run
const float TH1911_FULL_SPREAD_SPEED    = 320;
// weapon_colt1911.as:183 rolls a flat RandomLong(10, 13) per bullet.  This mod
// has no flat-damage path — every hitscan runs through W_LinearDamageFalloff —
// so the roll becomes a falloff that starts at the top of the script's range
// and ends at the bottom of it.  Point-blank and long-range shots bracket what
// the campaign does rather than averaging it away.
const float TH1911_CLOSE_DAMAGE         = 13;
const float TH1911_MIN_DAMAGE           = 10;
const float TH1911_DAMAGE_FALLOFF_RANGE = 2048;
const float TH1911_DRYFIRE_DELAY        = 0.2;
const float TH1911_KICK_PITCH    = 0.6;   // sv_gunkick — .as:193 punches -1.5..-1.9 deg
const float TH1911_KICK_VARIANCE = 0.25;
const float TH1911_KICK_STRENGTH = 1.6;

// Muzzle offset — see cl_debug_muzzle for the live-tune marker.
const float TH1911_MUZZLE_FORWARD = 38;
const float TH1911_MUZZLE_RIGHT   = 6.4;
const float TH1911_MUZZLE_DOWN    = 7.6;

// --- State durations, taken from the sequences themselves ---
const float TH1911_DRAW_DURATION         = 0.967;   // draw
const float TH1911_FIRE_DURATION         = 0.967;   // shoot / shoot_empty
const float TH1911_RELOAD_DURATION       = 2.633;   // reload       (round still chambered)
const float TH1911_RELOAD_EMPTY_DURATION = 3.133;   // reload_empty (slide locked back)

// The mounted They Hunger originals, out of the `steam:Sven Co-op/svencoop`
// mount.  Basenames are the on-disk spelling — FTE's VFS is case-sensitive
// against real files on Linux.
const string TH1911_VIEWMODEL    = "models/hunger/weapons/colt/v_1911.mdl";
const string TH1911_WORLDMODEL   = "models/hunger/weapons/colt/w_1911.mdl";
const string TH1911_DEPLOY_SOUND = "";
const string TH1911_DISPLAY_NAME = "COLT 1911";

// ============================================================
//  SHARED — state machine
// ============================================================

// Which reload is playing, and therefore how long WS_RELOAD lasts.  The two
// variants are half a second apart, so a single duration would either cut the
// empty reload off before the slide runs forward or leave the loaded one
// sitting on its last pose.
//
// Keyed off the magazine, NOT off .weaponframe: no file under client/ reads
// .weaponframe (it is server state), while mag_th1911 is replicated and reads
// the same on both sides.  It cannot flip mid-reload either — the transfer
// happens at reload_apply_time, and that is the same instant the state ends.
float() SH_TH1911ReloadDuration =
{
    if (self.mag_th1911 > 0)
        return TH1911_RELOAD_DURATION;
    return TH1911_RELOAD_EMPTY_DURATION;
};

float(float now) SH_TH1911TickState =
{
    float rel = SH_TH1911ReloadDuration();
    return SH_StandardTickState(now, mag_th1911, ammo_th1911, MAX_MAG_TH1911,
        TH1911_DRAW_DURATION, TH1911_FIRE_DURATION, rel, rel);
};

float(float now) SH_TH1911TryFire =
{
    return SH_StandardTryFire(now, mag_th1911, TH1911_FIRE_DELAY, TH1911_DRYFIRE_DELAY);
};

float(float now) SH_TH1911TryReload =
{
    return SH_StandardTryReload(now, mag_th1911, ammo_th1911, MAX_MAG_TH1911,
                                SH_TH1911ReloadDuration());
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_TH1911PickupCopy =
{
    player.mag_th1911  = self.mag_th1911;
    player.ammo_th1911 = self.ammo_th1911;
};

void() W_TH1911Shoot =
{
    W_PenetratingHitscanShoot(TH1911_BASE_SPREAD, TH1911_MOVE_SPREAD, TH1911_FULL_SPREAD_SPEED,
        TH1911_CLOSE_DAMAGE, TH1911_MIN_DAMAGE, TH1911_DAMAGE_FALLOFF_RANGE, 10, 0.94,
        TH1911_KICK_PITCH, TH1911_KICK_VARIANCE, TH1911_KICK_STRENGTH);
};

void() W_TH1911Fire =
{
    float r = SH_TH1911TryFire(time);

    if (r == 1)
    {
        // SH_StandardTryFire has already decremented (sh_weapon_standard.qc:225),
        // so mag > 0 here means "a round is still chambered" — the same
        // post-decrement test weapon_colt1911.as:161 makes.
        self.weaponframe   = (self.mag_th1911 > 0) ? TH1911_SEQ_SHOOT
                                                   : TH1911_SEQ_SHOOT_EMPTY;
        self.wep_nextframe = time + TH1911_FRAME_INTERVAL;

        W_TH1911Shoot();

        // .as:175-178 alternates the two fire wavs at random.
        if (random() < 0.5)
            sound(self, CHAN_WEAPON, "hunger/weapons/colt/colt_fire1.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "hunger/weapons/colt/colt_fire2.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 4 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "hunger/weapons/colt/colt_empty.wav", 1, ATTN_NORM);
    }
};

void() W_TH1911Reload =
{
    if (SH_TH1911TryReload(time))
    {
        // Slide is only locked back when the magazine ran dry, so a reload
        // with a round left plays the shorter variant — the same split the
        // Half-Life Glock makes (glock.cpp:231).
        self.weaponframe   = (self.mag_th1911 > 0) ? TH1911_SEQ_RELOAD
                                                   : TH1911_SEQ_RELOAD_EMPTY;
        self.wep_nextframe = time + TH1911_FRAME_INTERVAL;
        self.th1911_reload_snd_stage = 0;
    }
};

void() W_TH1911Frame =
{
    float result;

    // NO `self.weaponframe += 1`.  weaponframe is a sequence index; the engine
    // advances the sub-frame itself from .frame1time (cl_weapons.qc:1697), so
    // this function only decides WHICH sequence plays and when the state ends.
    self.wep_nextframe += TH1911_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0)
    {
        float reload_elapsed = time - self.wep_anim_start;
        if (self.th1911_reload_snd_stage < 1 && reload_elapsed >= TH1911_RELOAD_MAGOUT_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/colt/1911_magout.wav", 1, ATTN_NORM);
            self.th1911_reload_snd_stage = 1;
        }
        if (self.th1911_reload_snd_stage < 2 && reload_elapsed >= TH1911_RELOAD_MAGIN_TIME)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/colt/1911_magin.wav", 1, ATTN_NORM);
            self.th1911_reload_snd_stage = 2;
        }
        // Slide release only exists on the empty reload — on the loaded one
        // the slide never went back.
        if (self.th1911_reload_snd_stage < 3 && reload_elapsed >= TH1911_RELOAD_SLIDE_TIME
            && self.weaponframe == TH1911_SEQ_RELOAD_EMPTY)
        {
            sound(self, CHAN_AUTO, "hunger/weapons/colt/1911_slideforward.wav", 1, ATTN_NORM);
            self.th1911_reload_snd_stage = 3;
        }
    }

    result = SH_TH1911TickState(time);
    if (result & 1)
    {
        self.weaponframe = TH1911_SEQ_IDLE;
        // Idle retire — the ONLY place a zero here is legal.  sv_weapons.qc:3820
        // only ticks wepframe while wep_nextframe > 0, so a stray zero anywhere
        // else freezes the weapon permanently.  The idle CYCLE is driven from
        // CSQC_TH1911DisplayFrame, which is the viewmodel the player sees.
        self.wep_nextframe = 0;
    }
};

void() W_TH1911Equip =
{
    // Iron-sight ADS on +attack2.  The 1911 had no ADS profile at all, which is
    // what "can't ADS with the colt1911" was: weapon_ads_eligible defaults to 0
    // and the shared ADS path in cl_viewfx.qc/sh_pmove.qc reads that field rather
    // than any weapon list, so the gun was simply never a candidate.  SCOPE_CLASS_NONE
    // = pose-only ADS (no CoD scope overlay), same as every other sidearm here.
    // Pose starts on the untuned baseline registered in sh_cvar_table.qc; the six
    // cl_ads_th1911_* cvars are live, so alignment is a tuning pass, not a rebuild.
    W_SetADSProfile(TRUE, "cl_ads_th1911", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(TH1911_VIEWMODEL, TH1911_DISPLAY_NAME, TH1911_SEQ_DRAW,
        TH1911_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_TH1911Fire;
    self.reload   = W_TH1911Reload;
    self.wepframe = W_TH1911Frame;
    self.shoot    = W_TH1911Shoot;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(TH1911_BASE_SPREAD, TH1911_MOVE_SPREAD, TH1911_FULL_SPREAD_SPEED, 1, TRUE);
};

void() W_TH1911Drop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_th1911  = self.mag_th1911;
    tgt.ammo_th1911 = self.ammo_th1911;

    self.mag_th1911  = 0;
    self.ammo_th1911 = 0;

    setmodel(tgt, TH1911_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 40');
    tgt.classname      = "weapon_colt1911";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_TH1911;
    tgt.weapon_slot    = SLOT_SECONDARY;
    tgt.weap_draw      = W_TH1911Equip;
    tgt.weap_drop_func = W_TH1911Drop;
    tgt.pickupcopy     = W_TH1911PickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_th1911 =
{
    setmodel(self, TH1911_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 40');
    self.classname      = "weapon_colt1911";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_TH1911;
    self.weapon_slot    = SLOT_SECONDARY;
    self.weap_draw      = W_TH1911Equip;
    self.weap_drop_func = W_TH1911Drop;
    self.pickupcopy     = W_TH1911PickupCopy;
    self.touch          = weapon_touch;
    self.mag_th1911     = MAX_MAG_TH1911;
    self.ammo_th1911    = MAX_AMMO_TH1911;
    W_RegisterMapWeapon(weapon_th1911);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_th1911_reload_snd_stage;

void() CSQC_PredictTH1911Command =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_TH1911TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (CSQC_BeginFireActionEffects())
            {
                if (random() < 0.5)
                    localsound("hunger/weapons/colt/colt_fire1.wav");
                else
                    localsound("hunger/weapons/colt/colt_fire2.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedPenetratingImpact(TH1911_BASE_SPREAD, TH1911_MOVE_SPREAD, TH1911_FULL_SPREAD_SPEED,
                    TH1911_CLOSE_DAMAGE, TH1911_MIN_DAMAGE, TH1911_DAMAGE_FALLOFF_RANGE, 10, 0.94,
                    TH1911_KICK_PITCH, TH1911_KICK_VARIANCE, TH1911_KICK_STRENGTH);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 4 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_MuzzleFlashAtMuzzle(TH1911_MUZZLE_FORWARD, TH1911_MUZZLE_RIGHT,
                    TH1911_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(TH1911_MUZZLE_FORWARD, TH1911_MUZZLE_RIGHT,
                    TH1911_MUZZLE_DOWN, self.wep_action_id, 1);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("hunger/weapons/colt/colt_empty.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_th1911_reload_snd_stage < 1 && reload_elapsed >= TH1911_RELOAD_MAGOUT_TIME)
        {
            localsound("hunger/weapons/colt/1911_magout.wav"); CSQC_RecordPredictedAutoSound();
            csqc_th1911_reload_snd_stage = 1;
        }
        if (csqc_th1911_reload_snd_stage < 2 && reload_elapsed >= TH1911_RELOAD_MAGIN_TIME)
        {
            localsound("hunger/weapons/colt/1911_magin.wav"); CSQC_RecordPredictedAutoSound();
            csqc_th1911_reload_snd_stage = 2;
        }
        // Mirrors the server's variant test — SH_TH1911ReloadDuration keys the
        // same way, off the magazine, so both sides agree on which reload this
        // is without needing .weaponframe (which the client cannot read).
        if (csqc_th1911_reload_snd_stage < 3 && reload_elapsed >= TH1911_RELOAD_SLIDE_TIME
            && self.mag_th1911 <= 0)
        {
            localsound("hunger/weapons/colt/1911_slideforward.wav"); CSQC_RecordPredictedAutoSound();
            csqc_th1911_reload_snd_stage = 3;
        }
    }

    SH_TH1911TickState(csqc_pred_time);
};

void() CSQC_PredictTH1911Reload =
{
    if (SH_TH1911TryReload(csqc_pred_time))
    { csqc_th1911_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

// Returns a SEQUENCE index.  The engine does the within-sequence advance
// itself from .frame1time, so the `elapsed` argument is unused here — it stays
// in the signature because csqc_display_frame is a shared function-pointer type.
float(float elapsed) CSQC_TH1911DisplayFrame =
{
    // FIRST, for every state — SH_SeqIdleDisplay has to see the non-idle
    // frames to catch the return-to-idle edge.  v_1911.mdl has no looping
    // sequence at all, so without this the gun clamps to idle's last frame and
    // never moves again; see sh_weapon_standard.qc.
    float idle = SH_SeqIdleDisplay(cltime, WEP_TH1911, predicted_player.weaponstate,
                                   TH1911_SEQ_IDLE, TH1911_SEQ_FIDGET1,
                                   TH1911_IDLE_REARM_MIN, TH1911_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    if (predicted_player.weaponstate == WS_DRAW)
        return TH1911_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_th1911 > 0) ? TH1911_SEQ_SHOOT
                                                 : TH1911_SEQ_SHOOT_EMPTY;
    if (predicted_player.weaponstate == WS_RELOAD)
        return (predicted_player.mag_th1911 > 0) ? TH1911_SEQ_RELOAD
                                                 : TH1911_SEQ_RELOAD_EMPTY;
    return TH1911_SEQ_IDLE;
};

void() CSQC_TH1911DropClear =
{
    self.mag_th1911  = 0;
    self.ammo_th1911 = 0;
};

void() CSQC_TH1911Equip =
{
    // Must match W_TH1911Equip exactly: the ADS pose + FOV envelope is driven from
    // the PREDICTED player entity, so a profile set only on the server would leave
    // the local viewmodel refusing to aim while the server thought it was aiming.
    W_SetADSProfile(TRUE, "cl_ads_th1911", SCOPE_CLASS_NONE);
    self.weapon_name         = TH1911_DISPLAY_NAME;
    self.weapon_viewmodel    = TH1911_VIEWMODEL;
    self.weapon_worldmodel   = TH1911_WORLDMODEL;
    self.weapon_deploy_sound = TH1911_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictTH1911Command;
    self.csqc_predict_reload = CSQC_PredictTH1911Reload;
    self.csqc_display_frame  = CSQC_TH1911DisplayFrame;
    self.csqc_drop_clear     = CSQC_TH1911DropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
