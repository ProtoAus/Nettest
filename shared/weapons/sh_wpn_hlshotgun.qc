// ============================================================
//  shared/weapons/sh_wpn_hlshotgun.qc  -  HL Shotgun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell tube, 24 reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//  Alt   : Double-barrel (fires 2 shells, 16 pellets)
//  Reload: Shell-by-shell insertion (sequence-driven, three phases)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_shotgun;
.float ammo_shotgun;

// Server-side latches for the cues that used to be keyed off magic frame
// numbers.  CSQC keeps its own globals below (there is only ever one
// predicted player); the server needs one of each per player.
//   hlsg_pump_stage    — post-shot cock sound + shell eject, once per shot
//   hlsg_reload_shells — shells this reload will insert, latched at its start
//   hlsg_reload_stage  — inserts emitted so far; shells+1 once the closing
//                        pump cue has fired
.float hlsg_pump_stage;
.float hlsg_reload_shells;
.float hlsg_reload_stage;

// --- Sequence indices, read out of valve/models/v_shotgun.mdl (10 seqs) ---
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/
// wpn_hlshotgun/v_shotgun.mdl, a flat ~82-frame bake) by frame number.  It
// now drives Half-Life's own IDST model out of the `steam:Half-Life/valve`
// mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index —
// gl_hlmdl.c:780 sets mod->numframes = numseq — so every one of the old
// constants was meaningless against it: HLSG_RELOAD_END was 82 and this
// model has ten sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// Indices are the SDK's enum verbatim (shotgun.cpp:29-40), and which one
// plays when comes from the SDK too, not from the sequence names:
// :116 (draw), :171 (single fire), :245 (double), :277 (start_reload),
// :297 (per-shell reload), :333 (closing pump), :344-360 (idle pick).
// Durations below are (numframes-1)/fps — an N-frame sequence spans N-1
// intervals.  That is what the engine hands back from frameduration()
// (gl_hlmdl.c:1542 `*duration = (sequence->numframes-1)/sequence->timing;`)
// and what the SDK hardcodes for the same sequences: shotgun.cpp:348 uses
// (60.0/12.0) for the 61-frame @ 12 fps deepidle and :353/:358 use (20.0/9.0)
// for the 21-frame @ 9 fps sm_idle/idle4.
//
// FALLBACK INDICES AND FALLBACK DURATIONS ONLY, and that distinction is the
// whole of this section now.  Everything below was measured against
// `steam:Half-Life/valve`'s v_shotgun.mdl — 92 KB, 10 sequences — and that is
// NOT the file the engine opens: svencoop ships a 1.5 MB, 11-sequence
// v_shotgun.mdl and sits above valve in fs_addons.txt.  Ten of the eleven
// indices happen to still line up by ROLE, which is why nothing looked broken:
//
//   idx  valve            svencoop          what changed
//    0   sm_idle   2.222  sm_idle   2.317   longer
//    1   shoot     1.000  shoot1    1.050
//    2   shoot_big 1.538  shoot_FullAUTO    <- WRONG TAKE.  svencoop's double
//                                              barrel is index 10 shoot_double
//                                              (1.400 s); index 2 is a second
//                                              copy of the single-shot blast.
//    3   reload    0.562  reload_middle 0.467
//    4   pump      0.769  reload_end    0.833
//    5   start_rel 0.667  reload_start  0.733
//    6   draw      0.500  draw          0.517
//    7   reholster 0.333  reholster     0.517
//    8   idle4     2.222  idle4         2.206
//    9   deepidle  5.000  deepidle      4.633
//
// So every state ran short or long against whatever was actually on screen, and
// the alt-fire played the single-shot animation.  Each accessor below resolves
// by NAME through both spellings and takes its length from the live model; the
// constants stay as the answer for a model that is not precached yet.
const float HLSG_SEQ_SM_IDLE      = 0;   // sm_idle,       2.222 s, looping  (21f @  9)
const float HLSG_SEQ_SHOOT        = 1;   // shoot,         1.000 s           (21f @ 20)
const float HLSG_SEQ_SHOOT_BIG    = 2;   // shoot_big,     1.538 s           (21f @ 13)
const float HLSG_SEQ_RELOAD       = 3;   // reload,        0.5625 s (one shell, 10f @ 16)
const float HLSG_SEQ_PUMP         = 4;   // pump,          0.769 s  (closes reload, 11f @ 13)
const float HLSG_SEQ_START_RELOAD = 5;   // start_reload,  0.667 s  (gun to the side, 9f @ 12)
const float HLSG_SEQ_DRAW         = 6;   // draw,          0.500 s           (13f @ 24)
const float HLSG_SEQ_REHOLSTER    = 7;   // reholster,     0.333 s  (no holster path here)
const float HLSG_SEQ_IDLE4        = 8;   // idle4,         2.222 s, looping  (21f @  9)
const float HLSG_SEQ_DEEPIDLE     = 9;   // deepidle,      5.000 s, looping  (61f @ 12)

// wepframe scheduler tick, NOT an animation rate.  The engine owns the
// within-sequence advance now; this only paces how often W_ShotgunFrame
// gets to re-check its elapsed-time triggers (sv_weapons.qc:3820).
const float HLSG_FRAME_INTERVAL       = 0.05;

// Rate-of-fire gates — unchanged, these are balance, not animation.
const float HLSG_FIRE_DELAY           = 0.75;
const float HLSG_DBLFIRE_DELAY        = 0.9;

const float MAX_MAG_SHOTGUN           = 8;    // SHOTGUN_MAX_CLIP, shotgun.cpp:326
const float MAX_AMMO_SHOTGUN          = 24;

// --- Balance ---
const float HLSG_PELLETS              = 8;
const float HLSG_DBL_PELLETS          = 16;
const float HLSG_SPREAD               = 0.08;
const float HLSG_DBL_SPREAD           = 0.12;
const float HLSG_PELLET_CLOSE_DAMAGE  = 13;
const float HLSG_PELLET_MIN_DAMAGE    = 4;
const float HLSG_PELLET_FALLOFF_RANGE = 1024;
const float HLSG_DRYFIRE_DELAY        = 0.2;
// sv_gunkick — pump shotgun, big single-shot kick. Double-barrel
// alt-fire amplifies via DBL_KICK_STRENGTH for the harder kick.
const float HLSG_KICK_PITCH        = 2.5;
const float HLSG_KICK_VARIANCE     = 0.6;
const float HLSG_KICK_STRENGTH     = 1.5;
const float HLSG_DBL_KICK_STRENGTH = 2.5;   // both barrels — punishing kick.

// Muzzle offset — see cl_debug_muzzle for live-tune marker.
const float HLSG_MUZZLE_FORWARD = 42;
const float HLSG_MUZZLE_RIGHT   = 8.2;
const float HLSG_MUZZLE_DOWN    = 9.8;

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling and FTE's VFS is case-sensitive against real files on Linux.
const string HLSG_VIEWMODEL    = "models/v_shotgun.mdl";
const string HLSG_WORLDMODEL   = "models/w_shotgun.mdl";
const string HLSG_DEPLOY_SOUND = "";
const string HLSG_DISPLAY_NAME = "SHOTGUN";

// --- State durations, taken from the sequences themselves ---
// These replace the old (END - START) * FRAME_INTERVAL arithmetic, and each is
// (numframes-1)/fps so it agrees exactly with what SH_SeqDuration() reads back
// out of the engine (gl_hlmdl.c:1542).  A state that outlives its sequence is
// not free: shoot/shoot_big/reload/pump/start_reload/draw are all non-LOOP, so
// gl_hlmdl.c:1081/:1088 clamp frame1/frame2 to numframes-1 and the viewmodel
// sits frozen on the last frame for the whole overshoot.
//
// Single fire lands back on the local bake's 1.00 s exactly; draw is 0.45 ->
// 0.500.  The double-barrel is the outlier, because the real shoot_big spans
// 20 intervals at 13 fps where the local bake spanned 18 at 20.  See the note
// in SH_ShotgunTickState about what that does to the alt-fire cadence.
const float HLSG_DRAW_DURATION        = 0.500;   // draw
const float HLSG_FIRE_DURATION        = 1.000;   // shoot
const float HLSG_DBLFIRE_DURATION     = 1.538;   // shoot_big

// Reload is three sequences deep, so it has three lengths rather than one.
// A full 8-shell reload is therefore 0.667 + 8*0.5625 + 0.769 = 5.936 s where
// the local bake's was 0.35 + 8*0.50 + 0.55 = 4.90 s.  That +21% is the honest
// length of Half-Life's own animations and is not tunable from here without
// desyncing the viewmodel from the state machine; the SDK is in the same
// ballpark, pacing itself off m_flNextReload/m_flTimeWeaponIdle debounces of
// 0.5 s a shell (shotgun.cpp:299-300) on top of a 0.6 s start (:279-280).
const float HLSG_START_RELOAD_DUR     = 0.667;   // start_reload
const float HLSG_RELOAD_SHELL_DUR     = 0.5625;  // reload, once per shell
const float HLSG_RELOAD_PUMP_DUR      = 0.769;   // pump

// Post-shot cock sound + shell eject, elapsed from the start of the shot.
// Single fire matches the SDK exactly: shotgun.cpp:178 sets
// m_flPumpTime = time + 0.5 and ItemPostFrame (:367-372) emits scock1.wav
// when it expires.  The old frame-21-of-11..31 trigger worked out to the
// same 0.5 s, which is a good sign the mod's author took it from there.
// The double-barrel cue is a deliberate BEHAVIOUR CHANGE: it moves 0.6 -> 0.95
// to follow shotgun.cpp:251.  0.6 was as late as the 0.9 s local bake could put
// it; on the real 1.538 s shoot_big it would eject the shells before the breech
// is open.  Both cues still land inside their sequence (0.5 < 1.000,
// 0.95 < 1.538), so neither fires against a clamped final frame.
const float HLSG_FIRE_PUMP_TIME       = 0.5;
const float HLSG_DBLFIRE_PUMP_TIME    = 0.95;

// ============================================================
//  SHARED — sequence resolution
//
//  Every take is asked for by NAME, through BOTH spellings, with the SDK index
//  as the last resort.  valve and svencoop name the reload trio differently
//  (reload/pump/start_reload against reload_middle/reload_end/reload_start) and
//  disagree outright about index 2 — see the table in the index block above.
// ============================================================

float(string a, string b, float fallback) SH_HlsgSeq2 =
{
    float s = SH_SeqTryName(HLSG_VIEWMODEL, a);
    if (s >= 0) return s;
    return SH_SeqForName(HLSG_VIEWMODEL, b, fallback);
};

float() SH_HlsgSeqIdle    = { return SH_HlsgSeq2("sm_idle",      "sm_idle",      HLSG_SEQ_SM_IDLE); };
float() SH_HlsgSeqShoot   = { return SH_HlsgSeq2("shoot",        "shoot1",       HLSG_SEQ_SHOOT); };
// THE DOUBLE BARREL.  svencoop's index 2 is `shoot_FullAUTO`, a second copy of
// the single blast; its real double is `shoot_double` at index 10.  Asking for
// the name first is what stops the alt-fire playing a single-shot animation.
float() SH_HlsgSeqShootBig= { return SH_HlsgSeq2("shoot_double", "shoot_big",    HLSG_SEQ_SHOOT_BIG); };
float() SH_HlsgSeqReload  = { return SH_HlsgSeq2("reload_middle","reload",       HLSG_SEQ_RELOAD); };
float() SH_HlsgSeqPump    = { return SH_HlsgSeq2("reload_end",   "pump",         HLSG_SEQ_PUMP); };
float() SH_HlsgSeqStartRel= { return SH_HlsgSeq2("reload_start", "start_reload", HLSG_SEQ_START_RELOAD); };
float() SH_HlsgSeqDraw    = { return SH_HlsgSeq2("draw",         "draw",         HLSG_SEQ_DRAW); };

float() SH_HlsgDrawDuration   = { return SH_SeqDuration(HLSG_VIEWMODEL, SH_HlsgSeqDraw(),     HLSG_DRAW_DURATION); };
float() SH_HlsgFireDuration   = { return SH_SeqDuration(HLSG_VIEWMODEL, SH_HlsgSeqShoot(),    HLSG_FIRE_DURATION); };
float() SH_HlsgDblDuration    = { return SH_SeqDuration(HLSG_VIEWMODEL, SH_HlsgSeqShootBig(), HLSG_DBLFIRE_DURATION); };
float() SH_HlsgStartRelDur    = { return SH_SeqDuration(HLSG_VIEWMODEL, SH_HlsgSeqStartRel(), HLSG_START_RELOAD_DUR); };
float() SH_HlsgShellDur       = { return SH_SeqDuration(HLSG_VIEWMODEL, SH_HlsgSeqReload(),   HLSG_RELOAD_SHELL_DUR); };
float() SH_HlsgPumpDur        = { return SH_SeqDuration(HLSG_VIEWMODEL, SH_HlsgSeqPump(),     HLSG_RELOAD_PUMP_DUR); };

// ============================================================
//  SHARED — state machine
//  Handles draw/fire/special→idle. Reload is driven by the
//  three-phase resolver below, on both server and client.
// ============================================================

// Side-channel outputs of SH_ShotgunReloadSeq.  QC has no multiple return and
// the caller needs all three answers, so the two secondary ones land here.
// Both halves of the file read them immediately after the call, before
// anything else can run, so there is no lifetime to worry about.
float hlsg_seq_local_time;    // elapsed WITHIN the returned sequence
float hlsg_seq_shell_index;   // 0-based insert cycle in flight; -1 outside the loop

// Resolve "how far into the reload are we" into "which sequence, how far into
// IT, and which shell".  The shell-by-shell reload is start_reload, then one
// `reload` per shell, then `pump` — shotgun.cpp:277 / :297 / :333.  Driving it
// off total elapsed time (rather than re-stamping wep_anim_start at each
// boundary) keeps the server and the client's prediction on one arithmetic
// expression, so they cannot drift apart mid-reload.
float(float elapsed, float shells) SH_ShotgunReloadSeq =
{
    float loop_elapsed, loop_total, idx;
    float start_dur = SH_HlsgStartRelDur();
    float shell_dur = SH_HlsgShellDur();

    hlsg_seq_shell_index = -1;

    if (elapsed < start_dur)
    {
        hlsg_seq_local_time = elapsed;
        return SH_HlsgSeqStartRel();
    }

    loop_elapsed = elapsed - start_dur;
    loop_total   = shells * shell_dur;

    if (loop_elapsed < loop_total)
    {
        idx = floor(loop_elapsed / shell_dur);
        hlsg_seq_shell_index = idx;
        hlsg_seq_local_time  = loop_elapsed - idx * shell_dur;
        return SH_HlsgSeqReload();
    }

    // Clamped to the pump's own length.  Unclamped this grew without bound once
    // elapsed passed the end of the reload, and `pump` is a non-LOOP sequence —
    // the engine clamps frame1/frame2 to numframes-1 (gl_hlmdl.c:1076-1082), so
    // the viewmodel sat frozen on the last frame of the pump for as long as the
    // state lasted.  With the WS_RELOAD exit restored in SH_ShotgunTickState the
    // overshoot is now at most a tick, but a resolver that can return a time
    // outside its own sequence is a trap for the next caller.
    hlsg_seq_local_time = min(loop_elapsed - loop_total, SH_HlsgPumpDur());
    return SH_HlsgSeqPump();
};

// Can an attack interrupt the reload that is currently running?
//
// Half-Life lets it: CBasePlayerWeapon::ItemPostFrame tests IN_ATTACK2 and
// IN_ATTACK *before* IN_RELOAD (weapons.cpp), and both CShotgun attacks clear
// m_fInSpecialReload (shotgun.cpp:185, :257), which drops the loader out of its
// cycle and plays the closing pump.  Shells already seated stay seated, because
// they are credited one at a time as the reload runs.
//
// Two conditions, both from the SDK's shape rather than invented:
//   * past the START_RELOAD phase — HL's first Reload() step returns
//     immediately after setting a 1.0 s m_flNextPrimaryAttack, so the opening
//     move cannot be cancelled either;
//   * at least one shell actually seated, so cancelling can never be a way to
//     rewind a reload you have gained nothing from.
float(float now) SH_ShotgunReloadCancellable =
{
    if (self.weaponstate != WS_RELOAD) return FALSE;
    if (self.wep_anim_start <= 0)      return FALSE;
    if (self.mag_shotgun <= 0)         return FALSE;   // nothing seated yet
    return (now - self.wep_anim_start) >= SH_HlsgStartRelDur();
};

float(float shells) SH_ShotgunReloadDuration =
{
    return SH_HlsgStartRelDur() + shells * SH_HlsgShellDur() + SH_HlsgPumpDur();
};

// NOTE ON ALT-FIRE CADENCE: this state machine gates re-fire on WS_IDLE, so a
// state's effective cooldown is max(delay, duration) — and now that the duration
// side comes from the live model, the CADENCE FOLLOWS WHICHEVER v_shotgun.mdL IS
// MOUNTED.  Both fire states are duration-bound (1.00/1.05 s single against a
// 0.75 s delay, 1.400/1.538 s double against 0.9), so the numbers are:
//
//     single   valve 1.000   svencoop 1.050    (+5 %)
//     double   valve 1.538   svencoop 1.400    (-9 %)
//
// HLSG_FIRE_DELAY and HLSG_DBLFIRE_DELAY are deliberately left where they are —
// the animation length is what varies, not the balance number — and both doubles
// sit either side of the SDK's own m_flNextSecondaryAttack of 1.5 s for this
// weapon (shotgun.cpp:253-254), so it is Half-Life's cadence in both cases.
float(float now) SH_ShotgunTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    // WS_RELOAD used to be part of the early-out above, and that was a dead end:
    // this function is the ONLY per-tick weapon-state driver CSQC has for the
    // shotgun (the server runs its own machine in W_ShotgunFrame and never calls
    // this), and the reconcile deliberately no longer writes weaponstate back
    // from the server.  So once the client entered WS_RELOAD nothing could ever
    // take it out again: SH_ShotgunTryFire bails on `weaponstate != WS_IDLE`, so
    // the gun was dead on the client until CSQC_PredictSelectWeapon forced
    // WS_DRAW — i.e. until you switched weapons.  That is exactly the reported
    // "reload doesn't finish and the gun stays stuck".
    //
    // The shell CREDIT stays server-side; the client's magazine tracks it
    // through the confirmed-ammo path instead (see wep_reload_server_driven and
    // trust_server_ammo in cl_player.qc).  All this branch owes the client is
    // the state exit at the right moment.
    if (self.weaponstate == WS_RELOAD)
    {
        if (elapsed >= SH_ShotgunReloadDuration(self.hlsg_reload_shells))
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_HlsgDrawDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SH_HlsgFireDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= SH_HlsgDblDuration())
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_ShotgunTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    // `now`-based — see sh_weapon_standard.qc SH_StandardTryFire.
    if (now < self.csqc_fire_guard) return 0;
#endif
    // WS_IDLE, or a reload far enough along to be interrupted — see
    // SH_ShotgunReloadCancellable.  Both sides run this same test, so the client
    // and server break out of the reload on the same command.
    if (self.weaponstate != WS_IDLE && !SH_ShotgunReloadCancellable(now)) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_shotgun <= 0)
    {
        self.attack_finished = now + HLSG_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + HLSG_DRYFIRE_DELAY;
#endif
        return -1;
    }

    // Decrements before the caller sets weaponframe, the same way
    // SH_StandardTryFire does (sh_weapon_standard.qc:225).  Nothing here
    // branches on the post-decrement mag though: v_shotgun.mdl has no
    // shoot_empty counterpart to shoot, unlike v_9mmhandgun.mdl — the SDK
    // picks between shoot and shoot_big on which trigger was pulled
    // (shotgun.cpp:171 vs :245), which this mod already models as
    // WS_FIRE vs WS_SPECIAL.
    self.mag_shotgun     -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + HLSG_FIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + HLSG_FIRE_DELAY;
#endif
    return 1;
};

float(float now) SH_ShotgunTryDoubleFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    // Alt-fire cancels a reload too — shotgun.cpp:257 clears m_fInSpecialReload
    // in SecondaryAttack exactly as :185 does in PrimaryAttack.
    if (self.weaponstate != WS_IDLE && !SH_ShotgunReloadCancellable(now)) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_shotgun < 2)
    {
        self.attack_finished = now + HLSG_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard = now + HLSG_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.mag_shotgun     -= 2;
    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + HLSG_DBLFIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + HLSG_DBLFIRE_DELAY;
#endif
    return 1;
};

float(float now) SH_ShotgunTryReload =
{
    float shells;

    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_shotgun >= MAX_MAG_SHOTGUN || self.ammo_shotgun <= 0) return 0;

    // Latch the shell count up front.  The reload's total length is
    // start_reload + N*reload + pump, so both halves have to agree on N or
    // they land on different sequences at the same instant.  The SDK instead
    // re-tests m_iClip every cycle (shotgun.cpp:326) and can be cut short by a
    // mid-reload pickup; this mod grants no ammo mid-reload, so latching is
    // equivalent and keeps prediction in lockstep.
    shells = MAX_MAG_SHOTGUN - self.mag_shotgun;
    if (shells > self.ammo_shotgun) shells = self.ammo_shotgun;
    self.hlsg_reload_shells = shells;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_ShotgunPickupCopy =
{ player.mag_shotgun = self.mag_shotgun; player.ammo_shotgun = self.ammo_shotgun; };

void(float pellets, float spread_val, float kick_strength) W_ShotgunFirePellets =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    // sv_gunkick — one impulse per trigger pull. Caller passes a
    // strength multiplier (single-barrel uses HLSG_KICK_STRENGTH,
    // double-barrel HLSG_DBL_KICK_STRENGTH).
    SH_ApplyViewKick(HLSG_KICK_PITCH, HLSG_KICK_VARIANCE, kick_strength);

    vector saved_v_angle = self.v_angle;
    self.v_angle_x += self.view_kick_pitch;
    self.v_angle_y += self.view_kick_yaw;
    makevectors(self.v_angle);
    self.v_angle = saved_v_angle;

    src = self.origin + self.view_ofs;

    // Tag every impact this loop emits as one pellet of a single blast, so
    // remote viewers bypass their per-shot decal/effect caps (all pellets
    // share one wep_action_id).  See sv_impact_is_blast in sv_weapons.qc.
    sv_impact_is_blast = 1;
    for (i = 0; i < pellets; i++)
    {
        sx = SH_SpreadJitter(self.wep_action_id + i, 0) * spread_val;
        sy = SH_SpreadJitter(self.wep_action_id + i, 1) * spread_val;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            damage = W_LinearDamageFalloff(dist, HLSG_PELLET_CLOSE_DAMAGE, HLSG_PELLET_MIN_DAMAGE, HLSG_PELLET_FALLOFF_RANGE);
            if (W_CanDamageTarget(trace_ent))
            {
                W_ApplyDamage(self, trace_ent, damage);
            }
            else
            {
                PhysProp_TryPushFromTrace(dir, damage);
                W_ImpactEffect(trace_endpos);
            }

            W_DebugImpact(trace_endpos, damage, W_BoneToHitgroup(trace_bone_id));
        }
    }
    sv_impact_is_blast = 0;
};

void() W_ShotgunFire =
{
    float r = SH_ShotgunTryFire(time);
    if (r == 1)
    {
        self.weaponframe = SH_HlsgSeqShoot();
        self.wep_nextframe = time + HLSG_FRAME_INTERVAL;
        self.hlsg_pump_stage = 0;
        W_ShotgunFirePellets(HLSG_PELLETS, HLSG_SPREAD, HLSG_KICK_STRENGTH);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire1.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_ShotgunAltFire =
{
    float r = SH_ShotgunTryDoubleFire(time);
    if (r == 1)
    {
        self.weaponframe = SH_HlsgSeqShootBig();
        self.wep_nextframe = time + HLSG_FRAME_INTERVAL;
        self.hlsg_pump_stage = 0;
        W_ShotgunFirePellets(HLSG_DBL_PELLETS, HLSG_DBL_SPREAD, HLSG_DBL_KICK_STRENGTH);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire2.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_ShotgunReload =
{
    if (SH_ShotgunTryReload(time))
    {
        // start_reload is the first of the three; SH_ShotgunReloadSeq owns the
        // switch to `reload` and `pump` from here on (shotgun.cpp:277).
        self.weaponframe = SH_HlsgSeqStartRel();
        self.wep_nextframe = time + HLSG_FRAME_INTERVAL;
        self.hlsg_reload_stage = 0;
    }
};

void() W_ShotgunFrame =
{
    float elapsed, seq;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of a ten-sequence model in
    // half a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1696), so this function only decides WHICH
    // sequence is playing, when the state ends, and when the cues fire.
    self.wep_nextframe += HLSG_FRAME_INTERVAL;

    elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    // --- Draw ---
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SH_HlsgDrawDuration())
        {
            self.weaponframe = SH_HlsgSeqIdle();
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Single fire ---
    if (self.weaponstate == WS_FIRE)
    {
        // Was `weaponframe == HLSG_FIRE_PUMP_FRAME`.  Elapsed-time trigger with
        // a stage latch now, because at a 0.05 s tick an equality test against a
        // frame number is the only thing that kept this firing once, and there
        // are no frame numbers left to test.
        if (self.hlsg_pump_stage < 1 && elapsed >= HLSG_FIRE_PUMP_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/cock.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 46 36', '240 720 120');
            self.hlsg_pump_stage = 1;
        }

        if (elapsed >= SH_HlsgFireDuration())
        {
            self.weaponframe = SH_HlsgSeqIdle();
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Double fire ---
    if (self.weaponstate == WS_SPECIAL)
    {
        if (self.hlsg_pump_stage < 1 && elapsed >= HLSG_DBLFIRE_PUMP_TIME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/cock.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 46 36', '240 720 120');
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 52 42', '240 720 120');
            self.hlsg_pump_stage = 1;
        }

        if (elapsed >= SH_HlsgDblDuration())
        {
            self.weaponframe = SH_HlsgSeqIdle();
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Shell-by-shell reload (sequence-driven, three phases) ---
    if (self.weaponstate == WS_RELOAD)
    {
        float shells = self.hlsg_reload_shells;

        seq = SH_ShotgunReloadSeq(elapsed, shells);
        self.weaponframe = seq;

        // One shell per `reload` cycle, latched on the cycle index.  The credit
        // walks the latch forward one cycle at a time rather than assigning
        // hlsg_seq_shell_index + 1 outright: a hitch longer than one insert
        // (0.5625 s against a 0.05 s tick) skips whole cycles, and assigning
        // the latch straight to the newest index would bank one shell for all
        // of them and leave the player short a magazine.  The SOUND stays at
        // one per visit — the skipped cues are all in the past, and re-emitting
        // them would just retrigger CHAN_AUTO on the same instant.
        // shotgun.cpp:292-297 emits the shell sound in the same block that
        // calls SendWeaponAnim(SHOTGUN_RELOAD), so the cue and the round land
        // at local t=0 of each insert — not partway through it as the old
        // HLSG_RELOAD_INSERT_FRAME did.
        if (seq == SH_HlsgSeqReload() && self.hlsg_reload_stage <= hlsg_seq_shell_index)
        {
            while (self.hlsg_reload_stage <= hlsg_seq_shell_index)
            {
                self.hlsg_reload_stage += 1;

                if (self.mag_shotgun < MAX_MAG_SHOTGUN && self.ammo_shotgun > 0)
                {
                    self.mag_shotgun += 1;
                    self.ammo_shotgun -= 1;
                }
            }

            float snd_roll = random();
            if (snd_roll < 0.333)
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/reload1.wav", 1, ATTN_NORM);
            else if (snd_roll < 0.666)
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/reload2.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/reload3.wav", 1, ATTN_NORM);
        }

        // Closing pump.  shotgun.cpp:333-336 plays scock1.wav in the same block
        // as SendWeaponAnim(SHOTGUN_PUMP), so it too sits at local t=0.
        if (seq == SH_HlsgSeqPump() && self.hlsg_reload_stage <= shells)
        {
            self.hlsg_reload_stage = shells + 1;
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/cock.wav", 1, ATTN_NORM);
        }

        if (elapsed >= SH_ShotgunReloadDuration(shells))
        {
            self.weaponframe = SH_HlsgSeqIdle();
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // Fallback
    self.weaponframe = SH_HlsgSeqIdle();
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe = 0;
};

void() W_ShotgunEquip =
{
    W_StandardEquipSetup(HLSG_VIEWMODEL, HLSG_DISPLAY_NAME, SH_HlsgSeqDraw(),
        HLSG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire = W_ShotgunFire; self.reload = W_ShotgunReload; self.wepframe = W_ShotgunFrame;
    self.altfire = W_ShotgunAltFire;
    self.weapon_uses_sequences = TRUE;
    self.hlsg_pump_stage = 0; self.hlsg_reload_stage = 0; self.hlsg_reload_shells = 0;
    W_SetCrosshairProfile(HLSG_SPREAD, 0, 320, 3, TRUE);
};

void() W_ShotgunDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_shotgun = self.mag_shotgun; tgt.ammo_shotgun = self.ammo_shotgun;
    self.mag_shotgun = 0; self.ammo_shotgun = 0;
    setmodel(tgt, HLSG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_hlshotgun"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_HLSHOTGUN; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_ShotgunEquip; tgt.weap_drop_func = W_ShotgunDrop;
    tgt.pickupcopy = W_ShotgunPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_hlshotgun =
{
    setmodel(self, HLSG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_hlshotgun"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_HLSHOTGUN; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_ShotgunEquip; self.weap_drop_func = W_ShotgunDrop;
    self.pickupcopy = W_ShotgunPickupCopy; self.touch = weapon_touch;
    self.mag_shotgun = MAX_MAG_SHOTGUN; self.ammo_shotgun = MAX_AMMO_SHOTGUN;
    W_RegisterMapWeapon(weapon_hlshotgun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// HLSG_FIRE_PUMP_TIME / _DBLFIRE_PUMP_TIME are now declared once at the top of
// the file and shared with the server half — they used to be derived here from
// frame numbers that no longer exist, and the server tested frame equality for
// the same instants, so the two sides carried two representations of one cue.
//
// The shell count likewise moved to .hlsg_reload_shells, latched by
// SH_ShotgunTryReload, so client and server compute the reload's phase
// boundaries from the same N.

float csqc_hlsg_pump_played;
float csqc_hlsg_casing_spawned;
float csqc_hlsg_reload_stage;   // mirrors the server's .hlsg_reload_stage latch

void() CSQC_PredictShotgunCommand =
{
    float r;

    // Alt-fire: double barrel
    if (input_buttons & 4)
    {
        r = SH_ShotgunTryDoubleFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_hlsg_pump_played = FALSE;
            csqc_hlsg_casing_spawned = FALSE;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(HLSG_DBL_PELLETS, HLSG_DBL_SPREAD,
                    HLSG_PELLET_CLOSE_DAMAGE, HLSG_PELLET_MIN_DAMAGE, HLSG_PELLET_FALLOFF_RANGE,
                    HLSG_KICK_PITCH, HLSG_KICK_VARIANCE, HLSG_DBL_KICK_STRENGTH);
                // Shotgun muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(HLSG_MUZZLE_FORWARD, HLSG_MUZZLE_RIGHT,
                    HLSG_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(HLSG_MUZZLE_FORWARD, HLSG_MUZZLE_RIGHT,
                    HLSG_MUZZLE_DOWN, self.wep_action_id, HLSG_DBL_PELLETS);
                CSQC_EndFireActionEffects();
            }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_ShotgunTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_hlsg_pump_played = FALSE;
            csqc_hlsg_casing_spawned = FALSE;
            if (CSQC_BeginFireActionEffects())
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(HLSG_PELLETS, HLSG_SPREAD,
                    HLSG_PELLET_CLOSE_DAMAGE, HLSG_PELLET_MIN_DAMAGE, HLSG_PELLET_FALLOFF_RANGE,
                    HLSG_KICK_PITCH, HLSG_KICK_VARIANCE, HLSG_KICK_STRENGTH);
                // Shotgun muzzle flash — AK47_MUZZLE_* shared default.
                CSQC_MuzzleFlashAtMuzzle(HLSG_MUZZLE_FORWARD, HLSG_MUZZLE_RIGHT,
                    HLSG_MUZZLE_DOWN, self.wep_action_id);
                CSQC_MuzzleSmokeAtMuzzle(HLSG_MUZZLE_FORWARD, HLSG_MUZZLE_RIGHT,
                    HLSG_MUZZLE_DOWN, self.wep_action_id, HLSG_PELLETS);
                CSQC_EndFireActionEffects();
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted pump sound and shell casing, at the same elapsed offsets the
    // server latches on (HLSG_FIRE_PUMP_TIME / HLSG_DBLFIRE_PUMP_TIME).
    if ((!csqc_hlsg_pump_played || !csqc_hlsg_casing_spawned)
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_FIRE && elapsed >= HLSG_FIRE_PUMP_TIME)
        {
            if (!csqc_hlsg_pump_played)
            { localsound("sounds/weapons/wpn_hlshotgun/cock.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsg_pump_played = TRUE; }
            if (!csqc_hlsg_casing_spawned)
            {
                CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                csqc_hlsg_casing_spawned = TRUE;
            }
        }
        else if (self.weaponstate == WS_SPECIAL && elapsed >= HLSG_DBLFIRE_PUMP_TIME)
        {
            if (!csqc_hlsg_pump_played)
            { localsound("sounds/weapons/wpn_hlshotgun/cock.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsg_pump_played = TRUE; }
            if (!csqc_hlsg_casing_spawned)
            {
                CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 52 42', '8 14 14', '240 720 120', '120 240 180');
                csqc_hlsg_casing_spawned = TRUE;
            }
        }
    }

    // Predicted reload sounds — shell insertion + closing pump.  Same resolver
    // and same latch rule the server runs in W_ShotgunFrame, so the predicted
    // cue and the server's echo land on the same instant and the dedup window
    // in CSQC_Event_Sound can swallow the echo.
    //
    // This half deliberately does NOT walk the latch cycle-by-cycle the way the
    // server's credit loop does: there is no ammo to credit here, only a cue,
    // and the cues for cycles a hitch skipped over are already in the past.
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float shells = self.hlsg_reload_shells;
        float seq = SH_ShotgunReloadSeq(reload_elapsed, shells);

        if (seq == SH_HlsgSeqReload() && csqc_hlsg_reload_stage <= hlsg_seq_shell_index)
        {
            csqc_hlsg_reload_stage = hlsg_seq_shell_index + 1;

            float snd_roll = random();
            if (snd_roll < 0.333)
                localsound("sounds/weapons/wpn_hlshotgun/reload1.wav");
            else if (snd_roll < 0.666)
                localsound("sounds/weapons/wpn_hlshotgun/reload2.wav");
            else
                localsound("sounds/weapons/wpn_hlshotgun/reload3.wav");
            CSQC_RecordPredictedAutoSound();
        }
        else if (seq == SH_HlsgSeqPump() && csqc_hlsg_reload_stage <= shells)
        {
            csqc_hlsg_reload_stage = shells + 1;
            localsound("sounds/weapons/wpn_hlshotgun/cock.wav");
            CSQC_RecordPredictedAutoSound();
        }
    }

    SH_ShotgunTickState(csqc_pred_time);
};

void() CSQC_PredictShotgunReload =
{
    if (SH_ShotgunTryReload(csqc_pred_time))
    {
        // SH_ShotgunTryReload has already latched .hlsg_reload_shells; all
        // that is left here is the client's copy of the cue latch.
        csqc_hlsg_reload_stage = 0;
        CSQC_MarkPendingWeaponAck();
    }
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, so for every state
// except the reload the `elapsed` argument goes unused — it stays in the
// signature because csqc_display_frame is a shared function pointer type.
//
// The reload is the exception: it is three sequences played back to back off a
// single wep_anim_start, so the renderer's default frame1time (elapsed since
// the whole reload began) would run `reload` and `pump` far past their own
// ends.  csqc_viewmodel_sequence_time_override (cl_customdefs.qc:134-138,
// consumed at cl_weapons.qc:1690) exists for exactly this and gets the
// sub-sequence's local time instead.
float(float elapsed) CSQC_ShotgunDisplayFrame =
{
    float seq;

    if (predicted_player.weaponstate == WS_DRAW)
        return SH_HlsgSeqDraw();
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_HlsgSeqShoot();
    if (predicted_player.weaponstate == WS_SPECIAL)
        return SH_HlsgSeqShootBig();
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        seq = SH_ShotgunReloadSeq(elapsed, predicted_player.hlsg_reload_shells);
        csqc_viewmodel_sequence_time_override = TRUE;
        csqc_viewmodel_sequence_time = hlsg_seq_local_time;
        return seq;
    }
    // sm_idle is the loopable resting pose.  The SDK rolls between deepidle
    // (80%), sm_idle (15%) and idle4 (5%) in WeaponIdle (shotgun.cpp:344-360),
    // but that hangs off m_flTimeWeaponIdle, which this mod has no equivalent
    // of — there is no idle driver to hand the other two to, so they stay
    // declared and unused rather than being faked here.
    return SH_HlsgSeqIdle();
};

void() CSQC_ShotgunDropClear =
{
	self.mag_shotgun  = 0;
	self.ammo_shotgun = 0;
};

void() CSQC_ShotgunEquip =
{
	self.weapon_name         = HLSG_DISPLAY_NAME;
	self.weapon_viewmodel    = HLSG_VIEWMODEL;
	self.weapon_worldmodel   = HLSG_WORLDMODEL;
	self.weapon_deploy_sound = HLSG_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictShotgunCommand;
	self.csqc_predict_reload = CSQC_PredictShotgunReload;
	self.csqc_display_frame  = CSQC_ShotgunDisplayFrame;
	self.csqc_drop_clear     = CSQC_ShotgunDropClear;
	self.weapon_uses_sequences = TRUE;

	// DO NOT reset csqc_hlsg_reload_stage here.  CSQC_WeaponEquip() is called
	// unconditionally from CSQC_ResetToConfirmedState — i.e. once per render
	// frame, not once per weapon change — and it has no same-weapon guard.  A
	// latch cleared here is therefore cleared EVERY FRAME, so the predicted
	// reload re-fired reload1/2/3.wav and cock.wav on every tick for the whole
	// reload and only stopped when you switched weapons.  That was the reported
	// "both reload sounds loop constantly".
	//
	// CSQC_PredictShotgunReload already resets the latch at reload start, which
	// is the correct place and what the CS M3 (the working reference) does.
};

#endif // CSQC
