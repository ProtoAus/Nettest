// ============================================================
//  shared/weapons/sh_wpn_gravitygun.qc  -  Gravity Gun (HL2-style)
//
//  Slot   : SLOT_PRIMARY
//  Energy : infinite (no ammo, no reload).
//
//  Primary (+attack):  tap grabs the nearest ODE phys prop (filing
//      cabinet / dropped weapon / barrel / can) at long range and floats
//      it in front of you (reusing the +use carry system); tap again
//      throws it.  Grab plays "fire", throw plays "fire2".
//  Secondary (+attack2, HELD = input_buttons bit 4, the ADS bit):
//      spinup -> spin (looping) while held; pulls ALL phys props within a
//      radius toward a point in front of the player (black hole).  Release
//      blasts them outward (PhysProp_TryRadiusPush) and plays "fire2".
//
//  The grab/throw/pull/blast are SERVER-AUTHORITATIVE (ODE props live on
//  the server, not predicted).  The viewmodel sequence is driven off the
//  replicated weaponstate / wep_anim_start / pm_carrying, so the anim stays
//  in lockstep with the server-side physics (no new networking needed).
//
//  Held-tick + per-tick pull run from sv_player.qc PlayerPreThink, next to
//  the grapple/carry ticks (W_GravGun_HeldTick / W_GravGun_PullTick).
//
//  Sequence layout (v_gravitygun.mdl):
//     0 idle    1 idle2   2 fidget   3 spinup(loop)  4 spin(loop)
//     5 fire    6 fire2   7 holster  8 draw
//  No sounds yet.
// ============================================================

const float GRAVGUN_SEQ_IDLE    = 0;
const float GRAVGUN_SEQ_IDLE2   = 1;
const float GRAVGUN_SEQ_FIDGET  = 2;
const float GRAVGUN_SEQ_SPINUP  = 3;
const float GRAVGUN_SEQ_SPIN    = 4;
const float GRAVGUN_SEQ_FIRE    = 5;
const float GRAVGUN_SEQ_FIRE2   = 6;
const float GRAVGUN_SEQ_HOLSTER = 7;
const float GRAVGUN_SEQ_DRAW    = 8;

const string GRAVGUN_VIEWMODEL    = "models/weapons/wpn_gravitygun/v_gravitygun.mdl";
const string GRAVGUN_WORLDMODEL   = "models/weapons/wpn_gravitygun/w_gravitygun.mdl";
const string GRAVGUN_DISPLAY_NAME = "Gravity Gun";
const string GRAVGUN_DEPLOY_SOUND = "";

const float GRAVGUN_FRAME_INTERVAL = 0.05;
const float GRAVGUN_GRAB_COOLDOWN  = 0.25;   // min time between grab attempts

// Server-side state.
.float gravgun_spinning;        // 1 while the black-hole spin is active
.float pm_gravgun_held_last;    // +attack2 edge latch

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Carry helper lives in sv_physprop.qc, which compiles AFTER the weapon files —
// forward-declare the one the gravity gun drives.  (W_PhysDropWake is already
// forward-declared in sv_breakable.qc, earlier than here.  PhysProp_KickStream /
// PhysProp_Wake are forward-declared in sv_customdefs.qc, earlier still.)
float(entity player, entity prop) Carry_TryGrab;

// --- Primary: ranged grab.  The THROW reuses the generic carry path
//     (CSQC sends `cmd throwprop` while carrying -> Carry_Throw; the
//     throwprop handler sets the fire2 anim for the gravity gun). ---
void() W_GravGunFire =
{
    if (self.gravgun_spinning)        return;   // not while spinning
    if (self.carried_prop != world || self.carried_ragdoll != world) return;   // holding -> throw is the throwprop path
    if (Weapon_SprintBlocksFire())    return;
    if (time < self.attack_finished)  return;

    self.attack_finished = time + GRAVGUN_GRAB_COOLDOWN;

    // Ranged grab trace.  OR in PHYSDROP_DIM so it can hit weapon drops (which
    // live in the player-passthrough dimension), same as the +use grab.
    makevectors(self.v_angle);
    vector start = self.origin + self.view_ofs;
    vector end   = start + v_forward * cvar("sv_gravgun_grab_range");

    float saved_dim = self.dimension_hit;
    self.dimension_hit = self.dimension_hit | PHYSDROP_DIM;
    traceline(start, end, MOVE_NORMAL, self);
    self.dimension_hit = saved_dim;

    entity prop = trace_ent;
    float grabbed = FALSE;
    if (prop != world)
    {
        // Wake a sleeping weapon drop FIRST: while asleep it's MOVETYPE_NONE (but
        // still solid, so the trace hit it), and both the gate below AND
        // Carry_IsCarriable require MOVETYPE_PHYSICS.  This is exactly why cabinets
        // (never asleep) grabbed but resting dropped weapons didn't.
        if (prop.weapon && prop.weapon_physdrop_sleeping)
            W_PhysDropWake(prop);
        if (prop.movetype == MOVETYPE_PHYSICS)
        {
            // Widen carry eligibility for this grab only (the +use path stays
            // cabinet-only): carry_allow_any lets Carry_IsCarriable accept any ODE body.
            carry_allow_any = TRUE;
            grabbed = Carry_TryGrab(self, prop);
            carry_allow_any = FALSE;
        }
    }

    // nettest: no prop grabbed -> try a corpse RAGDOLL (they live on RAGDOLL_DIM, not the prop dims).
    if (!grabbed)
    {
        saved_dim = self.dimension_hit;
        self.dimension_hit = self.dimension_hit | RAGDOLL_DIM;
        traceline(start, end, MOVE_NORMAL, self);
        self.dimension_hit = saved_dim;
        if (trace_ent.classname == "corpse_ragdoll" && trace_ent.skeletonindex)
            grabbed = Ragdoll_TryGrab(self, trace_ent);
    }

    if (!grabbed)
        return;   // nothing grabbable in front — no animation

    // Grab succeeded -> play "fire".
    self.weaponstate    = WS_FIRE;
    self.weaponframe    = GRAVGUN_SEQ_FIRE;
    self.wep_anim_start = time;
    self.wep_action_id += 1;
    self.wep_nextframe  = time + GRAVGUN_FRAME_INTERVAL;
};

void() W_GravGunFrame =
{
    self.wep_nextframe += GRAVGUN_FRAME_INTERVAL;
    if (self.gravgun_spinning)
        return;   // the spin state is owned by W_GravGun_HeldTick

    float r = SH_SimpleTickState(time,
        SH_SeqDuration(GRAVGUN_VIEWMODEL, GRAVGUN_SEQ_DRAW, 0.5),
        SH_SeqDuration(GRAVGUN_VIEWMODEL, self.weaponframe, 0.4));
    if (r & 1)
    {
        self.weaponframe   = GRAVGUN_SEQ_IDLE;
        self.wep_nextframe = 0;
    }
};

// Weapon-special (impulse 7): TOGGLE the gravity shift on/off.  Server-authoritative --
// GravShift_UpdateActivation reads self.gravshift_toggle as the "want shift" state and, on the
// rising edge, latches the faced direction into the global gravshift_world_dir (broadcast to all
// clients via the "gravdir" serverinfo key).  Press once = gravity redirects toward where you
// look; press again = restore.  (Replaces the old +button5 hold trigger.)
void() W_GravGun_ToggleShift =
{
    self.gravshift_toggle = !self.gravshift_toggle;
};

void() W_GravGunEquip =
{
    W_StandardEquipSetup(GRAVGUN_VIEWMODEL, GRAVGUN_DISPLAY_NAME, GRAVGUN_SEQ_DRAW,
        GRAVGUN_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_GravGunFire;
    self.reload   = __NULL__;
    self.wepframe = W_GravGunFrame;
    self.special  = W_GravGun_ToggleShift;   // impulse 7 = toggle the gravity shift
    self.shoot    = __NULL__;
    self.gravgun_spinning = 0;
    // No spread — a manipulator, not a firearm.  Last arg TRUE = show crosshair.
    W_SetCrosshairProfile(0, 0, 0, 0, TRUE);
};

// ---- Black-hole helpers (server) ----

vector() GravGun_GatherPoint =
{
    makevectors(self.v_angle);
    return self.origin + self.view_ofs + v_forward * cvar("sv_gravgun_pull_dist");
};

// Pull every phys body within radius toward `center` by applying a FORCE through
// ODE (physics_addforce) — so props accelerate naturally and arc in, rather than
// gliding at the flat constant speed the velocity-servo gave (which read as
// robotic/linear).  The force is scaled by the body's MASS so every object gets
// the SAME acceleration regardless of weight — a heavy cabinet and a light can
// pull in identically (a real black hole accelerates everything equally).  ×iter
// keeps the per-tick impulse independent of physics_ode_iterationsperframe.
// Skips the player's own carried prop.
void(vector center, float radius, float accel) GravGun_PullTowards =
{
    if (radius <= 0 || accel <= 0)
        return;
    float iter = Phys_ForceIter();   // backend-aware (xN on ODE, 1 on Box3D — see sh_weapon_logic.qc)
    float rest_r = cvar("sv_gravgun_rest_radius");   // Patch 68 rest deadzone (read once, not per prop)
    float rest_v = cvar("sv_gravgun_rest_speed");

    entity e = findradius(center, radius);
    while (e)
    {
        if (e.weapon && e.weapon_physdrop_sleeping)
            W_PhysDropWake(e);
        if (e.movetype == MOVETYPE_PHYSICS && e != self.carried_prop)
        {
            vector to_c = center - e.origin;
            float  dist = vlen(to_c);
            // Rest deadzone (Patch 68): a prop already gathered at the centre AND nearly stopped gets
            // NO pull force this tick, so it isn't re-woken every frame (physics_addforce calls
            // dBodyEnable) and ODE can auto-disable it.  Then the engine's both-disabled prop-vs-prop
            // skip makes the settled pile cost ~0 even while the black hole is held still — the exact
            // "stop moving it and let them rest = 30 fps" case.  Self-correcting: when the centre moves
            // or the prop speeds up past rest_speed it leaves the deadzone and gets pulled again.
            float settled = (rest_r > 0 && dist < rest_r && vlen(e.velocity) < rest_v);
            if (dist > 1 && !settled)
            {
                float m = e.mass; if (m <= 0) m = 1;
                // F = m·a → uniform acceleration `accel` toward the point.
                vector f = (to_c / dist) * (accel * m * iter);
                physics_addforce(e, f, e.origin);
                // This is a per-frame force with NO PhysProp_KickStream (that only fires on
                // the release blast), so the pulled prop must be woken here or a settled prop
                // would keep its slow sleep tick while being dragged through the air — its
                // mirror would stream at sleep_hz and its landing FX would lag.
                // INSIDE the force branch on purpose: waking in the `settled` deadzone would
                // re-enable the body every frame and defeat the Patch 68 rest deadzone this
                // very block exists to preserve.
                PhysProp_Wake(e);
            }
        }
        e = e.chain;
    }
};

// Release blast — fling every phys body in radius OUTWARD from `center`.  Also
// velocity-set (mass-independent) with an upward bias so props lift off the
// floor.  Replaces the old PhysProp_TryRadiusPush call, whose force was scaled
// by sv_physprop_explosion_force×100×iter — catastrophically strong even at low
// cvar values (the "intense at 10" bug).
void(vector center, float radius, float blast_speed) GravGun_BlastFrom =
{
    if (radius <= 0 || blast_speed <= 0)
        return;

    entity e = findradius(center, radius);
    while (e)
    {
        if (e.weapon && e.weapon_physdrop_sleeping)
            W_PhysDropWake(e);
        if (e.movetype == MOVETYPE_PHYSICS && e != self.carried_prop)
        {
            vector dir  = e.origin - center;
            float  dist = vlen(dir);
            if (dist < 1) { dir = '0 0 1'; dist = 1; }   // dead-center → straight up
            dir = dir * (1 / dist);
            dir_z += 0.35;                                 // upward bias
            dir = normalize(dir);
            e.velocity = dir * blast_speed;                // mass-independent
            physics_enable(e, TRUE);
            PhysProp_KickStream(e);                        // snappy mirror update on the blast
        }
        e = e.chain;
    }
};

// While THIS player is gravity-shifting (+button5 with the gravgun), tilt the ODE
// phys props the same way.  The ODE world pulls every body straight -Z; add a
// per-body force so the NET acceleration points along self.gravitydir instead, and
// cabinets + weapon drops fall/slide toward the new "down".  QC-only (no engine
// change) — mass-scaled + iter-compensated exactly like GravGun_PullTowards above.
// Called from PlayerPreThink.  (Approximate cancellation — uses sv_gravity as the
// world magnitude; tune if props drift in Z.)
void() W_GravGun_ShiftPropTick =
{
    if (self != gravshift_owner || gravshift_world_dir == '0 0 0')   // run ONCE, by the shift owner only
        return;
    float g    = cvar("sv_gravity"); if (g <= 0) g = 800;
    float iter = Phys_ForceIter();   // backend-aware (xN on ODE, 1 on Box3D — see sh_weapon_logic.qc)
    vector da  = gravshift_world_dir - '0 0 -1';   // extra accel: redirect -Z -> the global gravity dir
    entity e = findradius('0 0 0', 1000000);    // whole map
    while (e)
    {
        if (e.weapon && e.weapon_physdrop_sleeping)
            W_PhysDropWake(e);
        if (e.movetype == MOVETYPE_PHYSICS)
        {
            float m = e.mass; if (m <= 0) m = 1;
            physics_addforce(e, da * (g * m * iter), e.origin);
        }
        e = e.chain;
    }
};

// Rising/falling edge of +attack2 (input bit 4).  Called from PlayerPreThink.
void() W_GravGun_HeldTick =
{
    if (self.weapon != WEP_GRAVITYGUN || self.is_dead || self.health <= 0)
    {
        self.pm_gravgun_held_last = 0;
        self.gravgun_spinning     = 0;
        return;
    }

    float held = (input_buttons & 4) ? 1 : 0;   // +attack2 (the ADS bit)
    // Can't spin while holding a grabbed prop OR a corpse ragdoll (mutual exclusion with primary).
    if (self.carried_prop != world || self.carried_ragdoll != world)
        held = 0;
    float was_held = self.pm_gravgun_held_last;

    if (held && !was_held && !self.gravgun_spinning)
    {
        // Rising edge -> spin up.  Display drives spinup->spin from elapsed,
        // so the per-frame wepframe stays off (wep_nextframe = 0).
        self.gravgun_spinning = 1;
        self.weaponstate      = WS_SPECIAL;
        self.weaponframe      = GRAVGUN_SEQ_SPINUP;
        self.wep_anim_start   = time;
        self.wep_action_id   += 1;
        self.wep_nextframe    = 0;
    }
    else if (!held && was_held && self.gravgun_spinning)
    {
        // Falling edge -> blast everything outward + play "fire2".
        vector gp = GravGun_GatherPoint();
        GravGun_BlastFrom(gp, cvar("sv_gravgun_radius"), cvar("sv_gravgun_blast_speed"));
        Ragdoll_BlastFrom(gp, cvar("sv_gravgun_radius"), cvar("sv_gravgun_blast_speed"));   // nettest: fling corpse ragdolls too
        self.gravgun_spinning = 0;
        self.weaponstate      = WS_FIRE;
        self.weaponframe      = GRAVGUN_SEQ_FIRE2;
        self.wep_anim_start   = time;
        self.wep_nextframe    = time + GRAVGUN_FRAME_INTERVAL;   // frame resumes -> fire2 falls to idle
    }

    self.pm_gravgun_held_last = held;
};

// Per-tick pull while spinning.  Called from PlayerPreThink after HeldTick.
void() W_GravGun_PullTick =
{
    if (!self.gravgun_spinning)
        return;
    vector gp = GravGun_GatherPoint();
    GravGun_PullTowards(gp, cvar("sv_gravgun_radius"), cvar("sv_gravgun_pull_accel"));
    Ragdoll_PullTick(gp, cvar("sv_gravgun_radius"));   // nettest: the black hole also sucks in corpse ragdolls
};

void(entity player) W_GravGunPickupCopy =
{
    // infinite energy — nothing to copy
};

void() W_GravGunDrop =
{
    entity tgt = weapon_drop_target;
    setmodel(tgt, GRAVGUN_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_gravitygun";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_GRAVITYGUN;
    tgt.weapon_slot    = SLOT_PRIMARY;
    tgt.weap_draw      = W_GravGunEquip;
    tgt.weap_drop_func = W_GravGunDrop;
    tgt.pickupcopy     = W_GravGunPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_gravitygun =
{
    setmodel(self, GRAVGUN_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_gravitygun";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_GRAVITYGUN;
    self.weapon_slot    = SLOT_PRIMARY;
    self.weap_draw      = W_GravGunEquip;
    self.weap_drop_func = W_GravGunDrop;
    self.pickupcopy     = W_GravGunPickupCopy;
    self.touch          = weapon_touch;
    W_RegisterMapWeapon(weapon_gravitygun);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// Which sequence the current WS_FIRE is showing: FIRE (grab) or FIRE2 (throw /
// blast).  A CSQC global (not a predicted_player field) so it survives the
// per-frame reconcile — the predict command + the throwprop path set it, the
// display frame reads it.
float csqc_gravgun_fire_seq;

float(float elapsed) CSQC_GravGunDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return GRAVGUN_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_SPECIAL)
    {
        // spinup once, then loop spin
        if (elapsed < SH_SeqDuration(GRAVGUN_VIEWMODEL, GRAVGUN_SEQ_SPINUP, 0.4))
            return GRAVGUN_SEQ_SPINUP;
        return GRAVGUN_SEQ_SPIN;
    }
    if (predicted_player.weaponstate == WS_FIRE)
        return csqc_gravgun_fire_seq;   // FIRE (grab) or FIRE2 (throw / blast)
    return GRAVGUN_SEQ_IDLE;
};

// The mod is CLIENT-AUTHORITATIVE for weaponstate (cl_player.qc — fire-decision
// state is OWNED by predicted_player and never reconciled back from the server),
// so the viewmodel animation MUST be driven here, not by the server's weaponstate.
// weaponstate is the state latch; the actual grab/pull/blast PHYSICS runs
// server-side in parallel (W_GravGunFire / W_GravGun_*Tick), keyed off the same
// buttons, so the two stay in step.
void() CSQC_PredictGravGunCommand =
{
    float now = csqc_pred_time;

    // +attack2 (bit 4, the ADS bit) HELD = black-hole spin.  Can't spin while
    // holding a prop (matches the server gate).  weaponstate is the latch.
    float held2 = (input_buttons & 4) ? 1 : 0;
    if (self.pm_carrying)
        held2 = 0;

    if (held2 && self.weaponstate == WS_IDLE)
    {
        self.weaponstate    = WS_SPECIAL;          // spinup -> spin (held)
        self.wep_anim_start = now;
    }
    else if (!held2 && self.weaponstate == WS_SPECIAL)
    {
        self.weaponstate      = WS_FIRE;           // release -> blast
        self.wep_anim_start   = now;
        self.attack_finished  = now + GRAVGUN_GRAB_COOLDOWN;
        csqc_gravgun_fire_seq = GRAVGUN_SEQ_FIRE2;
    }

    // +attack (bit 1) = grab fire.  The throw-while-carrying case is the throwprop
    // path (cl_player.qc), which suppresses the fire bit before we run here and
    // predicts its own fire2 — so this only ever fires the GRAB.
    // THE SERVER ALREADY REFUSES TO ANIMATE AN EMPTY GRAB and this did not.
    // W_GravGunFire returns at "nothing grabbable in front — no animation"
    // BEFORE setting WS_FIRE, but CSQC entered WS_FIRE on the button alone — and
    // reconcile never writes weaponstate back (client/cl_player.qc:1022), so the
    // server's correct refusal was invisible and the grab take played on every
    // press into thin air.  The mirror image of the medkit and the snark: there
    // the client copied a too-permissive shared gate, here it had no gate at all.
    //
    // The client cannot reproduce Carry_TryGrab (mass, ODE body state, the
    // carry_allow_any widening), but it does have the prop hulls — they are
    // relinked for prediction every frame (PhysProp_RelinkHullsForPrediction) —
    // so "did the ray hit ANY entity rather than the world" removes the common
    // case, which is aiming at a wall or open air.  Deliberately permissive:
    // hitting a prop the server then judges non-carriable still animates, and
    // that is the safe direction to be wrong in, because the alternative is
    // swallowing a grab the server performs.
    float gg_can_grab = FALSE;
    if ((input_buttons & 1) && !self.pm_carrying
        && self.weaponstate == WS_IDLE
        && now >= self.attack_finished)
    {
        // serverkeyfloat WITH A DEFAULT, not cvar(): sv_gravgun_grab_range is
        // declared CVAR_SIDE_SV (sh_cvar_table.qc:3733), so it is not registered
        // in the client VM and cvar() would read 0 — a zero-length trace, always
        // hitting nothing, silently swallowing EVERY grab animation.  That is
        // strictly worse than the bug being fixed, and it is the failure this
        // codebase's cvar audit exists to catch.  The default matches the table.
        makevectors(input_angles);
        vector gg_start = self.origin + self.view_ofs;
        float  gg_range = serverkeyfloat("sv_gravgun_grab_range", 600);
        traceline(gg_start, gg_start + v_forward * gg_range, MOVE_NORMAL, self);
        gg_can_grab = (trace_ent != world);
    }

    if (gg_can_grab)
    {
        self.weaponstate      = WS_FIRE;
        self.wep_anim_start    = now;
        self.attack_finished   = now + GRAVGUN_GRAB_COOLDOWN;
        csqc_gravgun_fire_seq  = GRAVGUN_SEQ_FIRE;
    }

    // Fall WS_DRAW / WS_FIRE back to idle when the sequence finishes (WS_SPECIAL
    // holds open while +attack2 is down).
    if (self.weaponstate == WS_DRAW || self.weaponstate == WS_FIRE)
    {
        float seq = (self.weaponstate == WS_DRAW) ? GRAVGUN_SEQ_DRAW : csqc_gravgun_fire_seq;
        if (now - self.wep_anim_start >= SH_SeqDuration(GRAVGUN_VIEWMODEL, seq, 0.4))
        {
            self.weaponstate    = WS_IDLE;
            self.wep_anim_start = now;
        }
    }
};

void() CSQC_GravGunDropClear =
{
    // infinite energy — no per-weapon ammo to clear
};

void() CSQC_GravGunEquip =
{
    self.weapon_name           = GRAVGUN_DISPLAY_NAME;
    self.weapon_viewmodel      = GRAVGUN_VIEWMODEL;
    self.weapon_worldmodel     = GRAVGUN_WORLDMODEL;
    self.weapon_deploy_sound   = GRAVGUN_DEPLOY_SOUND;
    self.csqc_predict_cmd      = CSQC_PredictGravGunCommand;
    self.csqc_predict_reload   = __NULL__;
    self.csqc_display_frame    = CSQC_GravGunDisplayFrame;
    self.csqc_drop_clear       = CSQC_GravGunDropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
