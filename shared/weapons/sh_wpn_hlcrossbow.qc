// ============================================================
//  shared/weapons/sh_wpn_hlcrossbow.qc  -  HL Crossbow
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-bolt magazine, 10 reserve
//  Fire  : spawns bolt projectile (MOVETYPE_FLYMISSILE)
//         Scoped: hitscan; unscoped: projectile.  Both 90 damage.
//  Scope : toggle zoom via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_crossbow;
.float ammo_crossbow;
.float proj_damage;   // damage stored on projectile entity

// Server-side reload sound latch.  CSQC keeps its own single global (there is
// only ever one predicted player); the server needs one per player.
.float xbow_reload_snd_stage;

// --- Projectile model ---
// Still the local IDPO conversion.  valve/models/crossbow_bolt.mdl (the model
// ev_hldm.cpp:1289 sticks in walls) does exist on the mount, but the bolt is a
// static prop whose orientation this file compensates for by hand — the
// vectoangles() + 16-unit pullback at both stick sites — and that compensation
// has not been checked against the IDST original, so the bolt is deliberately
// left out of this migration.  See the notes on the migration ticket.
string XBOW_BOLT_MODEL = "models/weapons/wpn_hlcrossbow/bolt.mdl";

// --- Sequence indices, read out of valve/models/v_crossbow.mdl (12 seqs) ---
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/
// wpn_hlcrossbow/v_crossbow.mdl, a ~140-frame flat bake) by frame number.  It
// now drives Half-Life's own IDST model out of the `steam:Half-Life/valve`
// mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index -
// gl_hlmdl.c:780 sets mod->numframes = numseq - so every one of the old
// constants was meaningless against it: XBOW_LOADED_IDLE_FRAME was 140 and this
// model has twelve sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// Indices and the loaded/empty split are from the SDK, not guessed:
// crossbow.cpp:223-235 (the enum), :298-300 (deploy), :313-317 (holster),
// :475 (reload), :493-499 (idle).  The FIRE split is NOT in crossbow.cpp -
// FireBolt() never calls SendWeaponAnim, it only fires the event
// (crossbow.cpp:401), and the animation is chosen client-side in
// ev_hldm.cpp:1323-1326.
//
// Durations below are (numframes - 1) / fps, which is what the engine's
// frameduration() builtin returns (gl_hlmdl.c:1542) and therefore what
// SH_SeqDuration (sh_weapon_standard.qc:399) hands back for these sequences.
// An N-frame animation spans N-1 intervals; the SDK hardcodes the same
// convention, e.g. python.cpp:254 uses 70.0/30.0 for a 71-frame 30 fps
// sequence.  Anything here computed as numframes/fps would sit one frame
// period past the end of the animation.
const float XBOW_SEQ_IDLE1      = 0;   // idle1,     91f @ 30, 3.000 s, loops (loaded)
const float XBOW_SEQ_IDLE2      = 1;   // idle2,     31f @ 30, 1.000 s, loops (empty)
const float XBOW_SEQ_FIDGET1    = 2;   // fidget1,   81f @ 30, 2.667 s        (loaded)
const float XBOW_SEQ_FIDGET2    = 3;   // fidget2,   91f @ 30, 3.000 s        (empty)
const float XBOW_SEQ_FIRE1      = 4;   // fire1,    111f @ 60, 1.833 s  shot + recock
const float XBOW_SEQ_FIRE2      = 5;   // fire2,    166f @ 30, 5.500 s  (never played)
const float XBOW_SEQ_FIRE3      = 6;   // fire3,     16f @ 30, 0.500 s  shot that empties
const float XBOW_SEQ_RELOAD     = 7;   // reload,   136f @ 30, 4.500 s
const float XBOW_SEQ_DRAW1      = 8;   // draw1,     16f @ 30, 0.500 s        (loaded)
const float XBOW_SEQ_DRAW2      = 9;   // draw2,     16f @ 30, 0.500 s        (empty)
const float XBOW_SEQ_HOLSTER1   = 10;  // holster1,  16f @ 30, 0.500 s        (loaded)
const float XBOW_SEQ_HOLSTER2   = 11;  // holster2,  16f @ 30, 0.500 s        (empty)
// Four of those twelve are declared for completeness and never referenced:
// FIDGET1/2 need a random idle scheduler this mod does not have
// (crossbow.cpp:505-512 rolls for them on a WeaponIdle timer), HOLSTER1/2 need
// a holster state — a weapon switch here goes straight to WS_DRAW on the new
// weapon.  FIRE2 is dead in the SDK too: it is the only enum entry that
// appears in neither crossbow.cpp nor ev_hldm.cpp outside the enum itself.
//
// A model fact that contradicts its source, hence "read it, don't trust the
// comment": the SDK's WeaponIdle schedules FIDGET1 for 90/30 = 3.000 s and
// FIDGET2 for 80/30 = 2.667 s (crossbow.cpp:508, :513), but 3.000 s is exactly
// fidget2's length and 2.667 s is exactly fidget1's — the two are swapped in
// the .cpp.  That they land on the sequence lengths to the frame is also the
// check that (numframes - 1) / fps is the right formula.  Nothing here depends
// on the fidgets, but it is why these durations come out of the model.

const float XBOW_FRAME_INTERVAL       = 0.05;   // wepframe tick rate, not an anim rate
const float XBOW_FIRE_DELAY           = 0.75;   // crossbow.cpp:436 GetNextAttackDelay(0.75)

// Reload sound offset.  Held at the value the CSQC half already used (frame 108
// of the 71..139 bake @ 20 fps) instead of being re-derived from the new
// sequence: the sample and the mag-drop puff are this mod's own dressing, not a
// model fact.  The SDK plays its one xbow_reload1.wav at t=0 of the reload
// instead (crossbow.cpp:477); matching that would be a sound-design change, not
// a model migration.  Declared here rather than in the CSQC block because the
// server now keys off elapsed time too and the two must not drift apart.
const float XBOW_RELOAD_SND_TIME      = 1.85;

const float MAX_MAG_CROSSBOW          = 5;      // CROSSBOW_MAX_CLIP, crossbow.cpp
const float MAX_AMMO_CROSSBOW         = 10;

// --- Balance ---
// crossbow.cpp:27 BOLT_AIR_VELOCITY.  Was 3000, which is half again as fast as
// Half-Life's bolt and put the whole flight inside 3-9 frames at 60 fps in a
// normal-sized room — a bolt you cannot actually see travel.  (HL also has a
// 1000 BOLT_WATER_VELOCITY at :28; this mod does not model the water case.)
const float XBOW_PROJECTILE_SPEED     = 2000;
const float XBOW_PROJECTILE_DAMAGE    = 90;
const float XBOW_SCOPED_DAMAGE        = 90;
const float XBOW_DRYFIRE_DELAY        = 0.2;

// --- State durations, taken from the sequences themselves ---
// Same (numframes - 1) / fps as the sequence table above, so a state ends on
// the tick the engine finishes drawing its animation rather than one frame
// period later.  All four move:
//   draw        0.450 -> 0.500  (the bake's window was 9 ticks of 0.05;
//                                draw1/draw2 are both 16f @ 30 = 15/30, so one
//                                constant still covers both variants)
//   fire        1.850 -> 1.833  (the bake spanned XBOW_FIRE_START (22) to
//                                XBOW_FIRE_END (59), 37 ticks of 0.05; fire1 is
//                                111f @ 60 = 110/60, one 60 fps frame shorter)
//   fire empty  2.400 -> 0.500  the old value measured from XBOW_FIRE_START
//                               (22) all the way to XBOW_FIRE_EMPTY_END (70),
//                               i.e. across the bake's fire1 AND fire3 spans,
//                               so an emptying shot sat in WS_FIRE for 2.4 s.
//                               Visual only: the refire gate is attack_finished
//                               and SH_StandardTryReload does not block on
//                               WS_FIRE (sh_weapon_standard.qc:343).
//   reload      3.400 -> 4.500  a REAL timing change — the bake was ~1.1 s
//                               shorter than the animation it was cut from.
//                               4.500 s is what the sequence measures (136f
//                               @ 30 = 135/30) and it is to the millisecond
//                               what the SDK asks DefaultReload for at
//                               crossbow.cpp:475.
const float XBOW_DRAW_DURATION        = 0.500;  // draw1 / draw2
const float XBOW_FIRE_DURATION        = 1.833;  // fire1
const float XBOW_FIRE_EMPTY_DURATION  = 0.500;  // fire3
const float XBOW_RELOAD_DURATION      = 4.500;  // reload
const float XBOW_RELOAD_APPLY_TIME    = XBOW_RELOAD_DURATION;  // apply at end

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling — the SDK writes mixed case in places but the shipped files are all
// lowercase, and FTE's VFS is case-sensitive against real files on Linux.
const string CROSSBOW_VIEWMODEL    = "models/v_crossbow.mdl";
const string CROSSBOW_WORLDMODEL   = "models/w_crossbow.mdl";
const string CROSSBOW_DEPLOY_SOUND = "";
const string CROSSBOW_DISPLAY_NAME = "CROSSBOW";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CrossbowTickState =
{
    // Pick the sequence that W_CrossbowFire / CSQC_CrossbowDisplayFrame will
    // actually play, so WS_FIRE lasts as long as the animation on screen.  The
    // emptying shot is now the SHORTER of the two — fire3 is 0.500 s against
    // fire1's 1.833 s — the reverse of the frame-baked version this replaced.
    float fire_dur = (self.mag_crossbow <= 0) ? XBOW_FIRE_EMPTY_DURATION : XBOW_FIRE_DURATION;
    return SH_StandardTickState(now, mag_crossbow, ammo_crossbow, MAX_MAG_CROSSBOW,
        XBOW_DRAW_DURATION, fire_dur,
        XBOW_RELOAD_DURATION, XBOW_RELOAD_APPLY_TIME);
};

float(float now) SH_CrossbowTryFire =
{
    // Don't clear zoomstage here — Fire needs it to decide hitscan vs projectile.
    // Cleared in W_CrossbowFire / CSQC prediction AFTER the shot.
    return SH_StandardTryFire(now, mag_crossbow, XBOW_FIRE_DELAY, XBOW_DRYFIRE_DELAY);
};

float(float now) SH_CrossbowTryReload =
{
    float r = SH_StandardTryReload(now, mag_crossbow, ammo_crossbow, MAX_MAG_CROSSBOW, XBOW_RELOAD_DURATION);
    if (r == 1)
        self.zoomstage = 0;   // unscope on reload
    return r;
};

float(float now) SH_CrossbowTryAltFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.altfire_finished) return 0;

    if (self.zoomstage > 0)
        self.zoomstage = 0;
    else
        self.zoomstage = 2;   // single zoom stage (full zoom)

    self.altfire_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CrossbowPickupCopy =
{ player.mag_crossbow = self.mag_crossbow; player.ammo_crossbow = self.ammo_crossbow; };

// Bolt projectile touch
void() W_CrossbowBoltTouch =
{
    float damage;
    float saved_dim;

    if (other == self.owner)
        return;

    // Exclude shooter from impact sounds — they already heard it client-side
    saved_dim = dimension_send;
    if (self.owner)
        dimension_send = dimension_send & ~self.owner.dimension_seen;

    if (W_CanDamageTarget(other))
    {
        damage = self.proj_damage;
        W_ApplyDamage(self.owner, other, damage);
        if (random() < 0.5)
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hitbody1.wav");
        else
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hitbody2.wav");
    }
    else
    {
        if (random() < 0.5)
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hit1.wav");
        else
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hit2.wav");

        // Spawn stuck bolt visual — hidden from shooter (they see client-predicted one).
        // Pull back 16 units along the bolt's travel direction so the model doesn't
        // embed deep in geometry.
        vector travel_dir;
        makevectors(self.angles);
        travel_dir = v_forward;

        entity stuck = spawn();
        setmodel(stuck, XBOW_BOLT_MODEL);
        // Point-size like the flying bolt: without this the model AABB
        // (0..25 along X) becomes a world-axis-aligned box that never
        // rotates with the stuck bolt's angles.  See the flying-bolt spawn.
        setsize(stuck, '0 0 0', '0 0 0');
        setorigin(stuck, self.origin - travel_dir * 16);
        stuck.angles = self.angles;
        stuck.solid = SOLID_NOT;
        stuck.movetype = MOVETYPE_NONE;
        stuck.nodrawtoclient = self.owner;
        stuck.think = sub_remove;
        stuck.nextthink = time + 20;
    }

    dimension_send = saved_dim;
    remove(self);
};

void() W_CrossbowBoltThink =
{
    remove(self);
};

// Periodic tick wrapper — pulses CSQC SendFlags every sv_toss_tickrate
// tick so cl_tosssmooth.qc has fresh origin+velocity samples to extrap
// the bolt's flight smoothly. Removes the bolt at proj_fuse_end (5 s
// from spawn — same one-shot expire as the original W_CrossbowBoltThink).
void() W_CrossbowBoltProjectileTick =
{
    self.SendFlags |= 1;
    if (time >= self.proj_fuse_end)
    {
        remove(self);
        return;
    }
    self.nextthink = time + Toss_NextThinkInterval();
};

void() W_CrossbowFire =
{
    float r;
    entity bolt;

    r = SH_CrossbowTryFire(time);
    if (r == 1)
    {
        // SH_StandardTryFire has already decremented the magazine
        // (sh_weapon_standard.qc:225), so mag > 0 here means "there is another
        // bolt to recock with" — the same post-decrement test the SDK makes:
        // FireBolt passes m_iClip into the event as iparam1 (crossbow.cpp:401)
        // and ev_hldm.cpp:1323-1326 plays fire1 when that is non-zero, fire3
        // otherwise.  (The SDK's fire3 branch is additionally gated on reserve
        // ammo and plays NO animation when both are dry; weaponframe always has
        // to name some sequence, so fire3 covers that case here as well.)
        self.weaponframe = (self.mag_crossbow > 0) ? XBOW_SEQ_FIRE1 : XBOW_SEQ_FIRE3;
        self.wep_nextframe = time + XBOW_FRAME_INTERVAL;

        makevectors(self.v_angle);

        if (self.zoomstage > 0)
        {
            // Scoped: instant hitscan + stick rebar in wall
            vector src = self.origin + self.view_ofs;
            vector dir = v_forward;
            W_WeaponTraceLine(src, src + dir * 8192);

            if (trace_fraction < 1.0)
            {
                if (W_CanDamageTarget(trace_ent))
                    W_ApplyDamage(self, trace_ent, XBOW_SCOPED_DAMAGE);
                else
                {
                    W_ImpactEffect(trace_endpos);

                    entity stuck = spawn();
                    setmodel(stuck, XBOW_BOLT_MODEL);
                    // Point-size like the flying bolt: without this the model AABB
                    // (0..25 along X) becomes a world-axis-aligned box that never
                    // rotates with the stuck bolt's angles.  See the flying-bolt spawn.
                    setsize(stuck, '0 0 0', '0 0 0');
                    setorigin(stuck, trace_endpos - dir * 16);
                    stuck.angles = vectoangles(dir);
                    stuck.solid = SOLID_NOT;
                    stuck.movetype = MOVETYPE_NONE;
                    stuck.nodrawtoclient = self;
                    stuck.think = sub_remove;
                    stuck.nextthink = time + 20;
                }

                // Impact sound — exclude shooter
                {
                    float saved_dim = dimension_send;
                    dimension_send = dimension_send & ~self.dimension_seen;
                    if (random() < 0.5)
                        W_MulticastSound(trace_endpos, "sounds/weapons/wpn_hlcrossbow/hit1.wav");
                    else
                        W_MulticastSound(trace_endpos, "sounds/weapons/wpn_hlcrossbow/hit2.wav");

                    // Debug: send server hit to shooter only
                    dimension_send = self.dimension_seen;
                    W_DebugImpact(trace_endpos, XBOW_SCOPED_DAMAGE, W_BoneToHitgroup(trace_bone_id));

                    dimension_send = saved_dim;
                }
            }
        }
        else
        {
            // Unscoped: projectile bolt
            bolt = spawn();
            bolt.owner = self;
            bolt.classname = "proj_crossbow_bolt";
            bolt.movetype = MOVETYPE_FLYMISSILE;
            bolt.solid = SOLID_BBOX;
            setmodel(bolt, XBOW_BOLT_MODEL);
            setsize(bolt, '-1 -1 -1', '1 1 1');
            setorigin(bolt, self.origin + self.view_ofs + v_forward * 16);
            bolt.velocity = v_forward * XBOW_PROJECTILE_SPEED;
            bolt.angles = vectoangles(bolt.velocity);
            bolt.proj_damage = XBOW_PROJECTILE_DAMAGE;
            bolt.touch = W_CrossbowBoltTouch;
            // CSQC replication via projectile_SendEntity — owner-hidden,
            // others receive sample updates at sv_toss_tickrate routed
            // through cl_tosssmooth.qc for smooth flight.
            // Tracer.  A DELIBERATE deviation from Half-Life, which gives the
            // bolt no trail at all: HL's bolt is a chunky, sprite-lit prop, and
            // this one is a 25 x 3.8 x 1.5-unit IDPO sliver with no glow
            // crossing a room in about seven frames at 2000 u/s.  Everything
            // mechanical about it checks out -- correct IDPO model, precached
            // with a byte-identical string in both VMs, MASK_ENGINE, CSQC
            // physics live -- so what is left is that there is nearly nothing
            // to see.  The recipe (particles/trails.cfg) is short and dim on
            // purpose; this should read as a streak, not as a rocket.
            //
            // The trail is driven from CSQC (cl_throwtrail.qc, keyed off
            // proj_type) and NOT from .traileffectnum.  That field is an
            // entity_state_t member the client reads only for delta-replicated
            // packet entities (cl_ents.c:5601); this bolt is a SendEntity
            // projectile, i.e. a CSQC entity on both the networked and the fake
            // path, so setting it here drew precisely nothing.
            bolt.proj_type     = PROJ_TYPE_CROSSBOW_BOLT;
            bolt.SendEntity    = projectile_SendEntity;
            bolt.SendFlags     = 1;
            bolt.proj_fuse_end = time + 5;
            bolt.think         = W_CrossbowBoltProjectileTick;
            bolt.nextthink     = time + Toss_NextThinkInterval();
        }

        self.zoomstage = 0;
        self.sv_zoomstage = 0;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrossbow/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_CrossbowAltFire =
{
    if (SH_CrossbowTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_CrossbowReload =
{
    if (SH_CrossbowTryReload(time))
    {
        // crossbow.cpp:475 — DefaultReload( 5, CROSSBOW_RELOAD, 4.5 ).  Unlike
        // the glock there is no empty/not-empty pair to choose between: the
        // crossbow has exactly one reload sequence, and the enum comment calls
        // it "from empty" because a partial reload still re-cocks the same way.
        self.weaponframe = XBOW_SEQ_RELOAD;
        self.wep_nextframe = time + XBOW_FRAME_INTERVAL;
        self.xbow_reload_snd_stage = 0;
        self.sv_zoomstage = 0;
    }
};

void() W_CrossbowFrame =
{
    float result;

    // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
    // now, and incrementing it walked off the end of a twelve-sequence model
    // inside a second.  The engine advances the sub-frame itself from
    // .frame1time (cl_weapons.qc:1696), so this function only has to decide
    // WHICH sequence is playing and when the state ends.
    self.wep_nextframe += XBOW_FRAME_INTERVAL;

    // The reload sound moved from a frame-number compare to elapsed time, which
    // is what the CSQC half of this file already did — the two sides now share
    // XBOW_RELOAD_SND_TIME instead of holding two representations of the same
    // instant.  The stage latch is what replaces the `==`: an equality test on
    // a counter that stepped by exactly 1 per tick fired once by construction,
    // whereas `>=` on elapsed time is true on every tick after it too.
    if (self.weaponstate == WS_RELOAD && self.wep_anim_start > 0
        && self.xbow_reload_snd_stage < 1
        && (time - self.wep_anim_start) >= XBOW_RELOAD_SND_TIME)
    {
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlcrossbow/reload.wav", 1, ATTN_NORM);
        W_MagDropEffect(MAG_RIFLE, '4 -4 -6', '0 -30 -20');
        self.xbow_reload_snd_stage = 1;
    }

    result = SH_CrossbowTickState(time);
    if (result & 1)
    {
        // crossbow.cpp:493-499 — idle1 with a bolt loaded, idle2 when the
        // magazine is dry.  Both loop, so the pose holds by itself and the
        // frame function can retire until the next action.
        self.weaponframe = (self.mag_crossbow > 0) ? XBOW_SEQ_IDLE1 : XBOW_SEQ_IDLE2;
        // Idle-retire is the ONLY place this may go to zero: the server stops
        // calling wepframe entirely while wep_nextframe <= 0 — the gate is
        // sv_weapons.qc:3820, so a stray zero anywhere else freezes the
        // weapon for good.
        self.wep_nextframe = 0;
    }
};

void() W_CrossbowEquip =
{
    // crossbow.cpp:298-300 — Deploy() picks draw1 when m_iClip is non-zero and
    // draw2 when the magazine is empty; the two differ by whether a bolt is on
    // the rail, so picking the wrong one shows a bolt that is not there.
    float draw_seq = (self.mag_crossbow > 0) ? XBOW_SEQ_DRAW1 : XBOW_SEQ_DRAW2;
    W_StandardEquipSetup(CROSSBOW_VIEWMODEL, CROSSBOW_DISPLAY_NAME, draw_seq,
        XBOW_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CrossbowFire;
    self.reload   = W_CrossbowReload;
    self.wepframe = W_CrossbowFrame;
    self.altfire  = W_CrossbowAltFire;
    self.weapon_uses_sequences = TRUE;
    W_ClearZoom();
    W_SetCrosshairProfile(0, 0, 320, 1, FALSE);
};

void() W_CrossbowDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_crossbow = self.mag_crossbow; tgt.ammo_crossbow = self.ammo_crossbow;
    self.mag_crossbow = 0; self.ammo_crossbow = 0;
    setmodel(tgt, CROSSBOW_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_crossbow"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CROSSBOW; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_CrossbowEquip; tgt.weap_drop_func = W_CrossbowDrop;
    tgt.pickupcopy = W_CrossbowPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_crossbow =
{
    setmodel(self, CROSSBOW_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_crossbow"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CROSSBOW; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_CrossbowEquip; self.weap_drop_func = W_CrossbowDrop;
    self.pickupcopy = W_CrossbowPickupCopy; self.touch = weapon_touch;
    self.mag_crossbow = MAX_MAG_CROSSBOW; self.ammo_crossbow = MAX_AMMO_CROSSBOW;
    W_RegisterMapWeapon(weapon_crossbow);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_xbow_reload_snd_played;
// XBOW_RELOAD_SND_TIME is now declared once at the top of the file and shared
// with the server half — it used to be derived here from frame numbers that no
// longer exist.

// Dedicated stick think for crossbow bolts — matches the server stuck visual's
// 20s lifetime instead of the short ping-based expire used for bullet impacts.
void() CSQC_CrossbowBoltStick =
{
    self.velocity = '0 0 0';
    self.movetype = MOVETYPE_NONE;
    // Drop out of the trail walker's scan: a stuck bolt lives 20 s, and while it
    // carries the fake-projectile classname it counts as a live trailed
    // projectile, holding cl_throwtrail.qc's per-frame edict walk on for the
    // whole time (it would emit nothing -- it no longer moves -- but the scan
    // still costs).
    self.classname = "";
    setorigin(self, self.fake_proj_hitpos);
    if (self.fake_proj_hitsnd != "")
        pointsound(self.fake_proj_hitpos, self.fake_proj_hitsnd, 1, ATTN_NORM);
    self.think = CSQC_FakeProjectileExpire;
    self.nextthink = time + 20;
};

void() CSQC_PredictCrossbowCommand =
{
    float r;

    // Alt-fire: zoom toggle
    if (input_buttons & 4)
    {
        if (SH_CrossbowTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_CrossbowTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrossbow/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash(MUZZLE_TINT_DEFAULT);

                makevectors(input_angles);
                vector fire_org = self.origin + self.view_ofs + v_forward * 16;
                vector fire_dir = v_forward;

                if (self.zoomstage > 0)
                {
                    // Scoped: instant hitscan trace + stuck rebar
                    CSQC_WeaponTraceLine(fire_org, fire_org + fire_dir * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        vector hit_pos = trace_endpos;
                        vector hit_normal = trace_plane_normal;

                        CSQC_BulletImpact(hit_pos, hit_normal, XBOW_SCOPED_DAMAGE, 0);
                        if (cvar("cl_debug_impacts"))
                            CSQC_AddDebugImpact(hit_pos, fire_org, '0 1 0', 0, 0);
                        if (random() < 0.5)
                            localsound("sounds/weapons/wpn_hlcrossbow/hit1.wav");
                        else
                            localsound("sounds/weapons/wpn_hlcrossbow/hit2.wav");

                        entity stuck = spawn();
                        setmodel(stuck, XBOW_BOLT_MODEL);
                        // Point-size like the flying bolt: without this the model AABB
                        // (0..25 along X) becomes a world-axis-aligned box that never
                        // rotates with the stuck bolt's angles.  See the flying-bolt spawn.
                        setsize(stuck, '0 0 0', '0 0 0');
                        setorigin(stuck, hit_pos - fire_dir * 16);
                        stuck.angles = vectoangles(fire_dir);
                        stuck.movetype = MOVETYPE_NONE;
                        stuck.solid = SOLID_NOT;
                        stuck.drawmask = MASK_ENGINE;
                        stuck.think = CSQC_FakeProjectileExpire;
                        stuck.nextthink = time + 20;
                    }
                }
                else
                {
                    // Unscoped: fake flying bolt
                    entity bolt = spawn();
                    float hit_dist, travel_time;

                    setmodel(bolt, XBOW_BOLT_MODEL);
                    // POINT-SIZE, matching CCrossbowBolt::Spawn's
                    // UTIL_SetSize(pev, g_vecZero, g_vecZero).
                    //
                    // Without an explicit setsize, setmodel stamps the entity's
                    // bbox from the MODEL's own AABB, which for bolt.mdl runs
                    // from x=0 to x=+25 — a 25-unit box, off-centre from the
                    // origin and pointing along model +X.  Quake entity boxes
                    // never rotate with .angles, so it stayed pointing world-+X
                    // no matter which way the bolt flew: fire along Y and the
                    // box reads as exactly 90 degrees wrong, which is what was
                    // reported.  A point box has no orientation to get wrong.
                    setsize(bolt, '0 0 0', '0 0 0');
                    setorigin(bolt, fire_org);
                    bolt.velocity = fire_dir * XBOW_PROJECTILE_SPEED;
                    // bolt.mdl is IDPO (mod_alias), so pitch is NOT negated here
                    // — unlike the RPG rocket.  See W_ModelAngles.
                    bolt.angles = W_ModelAngles(bolt.velocity, FALSE);
                    bolt.movetype = MOVETYPE_NOCLIP;
                    bolt.solid = SOLID_NOT;
                    bolt.drawmask = MASK_ENGINE;
                    // Same tracer as the server bolt -- projectile_SendEntity
                    // hides the real one from its own shooter, so the person
                    // firing sees ONLY this fake.  The classname is what
                    // cl_throwtrail.qc's walker finds it by, and proj_type is
                    // what selects the recipe; a CSQC entity gets no trail from
                    // .traileffectnum, which is why the earlier attempt at this
                    // was invisible.
                    bolt.classname            = "csqc_fake_projectile";
                    bolt.csqc_projectile_type = PROJ_TYPE_CROSSBOW_BOLT;

                    CSQC_WeaponTraceLine(fire_org, fire_org + fire_dir * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        hit_dist = vlen(trace_endpos - fire_org);
                        travel_time = hit_dist / XBOW_PROJECTILE_SPEED;
                        bolt.fake_proj_hitpos = trace_endpos - fire_dir * 16;
                        bolt.fake_proj_hitsnd = (random() < 0.5) ? "sounds/weapons/wpn_hlcrossbow/hit1.wav" : "sounds/weapons/wpn_hlcrossbow/hit2.wav";
                        bolt.think = CSQC_CrossbowBoltStick;
                        bolt.nextthink = time + travel_time;
                    }
                    else
                    {
                        bolt.think = CSQC_FakeProjectileExpire;
                        bolt.nextthink = time + 3;
                    }
                }
            }
            self.zoomstage = 0;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted reload sound
    if (self.weaponstate == WS_RELOAD && !csqc_xbow_reload_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= XBOW_RELOAD_SND_TIME)
        {
            localsound("sounds/weapons/wpn_hlcrossbow/reload.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/crossbowclip.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_xbow_reload_snd_played = TRUE;
        }
    }

    SH_CrossbowTickState(csqc_pred_time);
};

void() CSQC_PredictCrossbowReload =
{
    if (SH_CrossbowTryReload(csqc_pred_time))
    { csqc_xbow_reload_snd_played = FALSE; CSQC_MarkPendingWeaponAck(); }
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, so the `elapsed`
// argument is no longer used here — it stays in the signature because
// csqc_display_frame is a shared function pointer type.
//
// Every branch re-derives loaded/empty from the predicted magazine, so this
// lands on the same sequence the server wrote into .weaponframe in
// W_CrossbowEquip / W_CrossbowFire / W_CrossbowFrame.
float(float elapsed) CSQC_CrossbowDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return (predicted_player.mag_crossbow > 0) ? XBOW_SEQ_DRAW1 : XBOW_SEQ_DRAW2;
    if (predicted_player.weaponstate == WS_FIRE)
        return (predicted_player.mag_crossbow > 0) ? XBOW_SEQ_FIRE1 : XBOW_SEQ_FIRE3;
    if (predicted_player.weaponstate == WS_RELOAD)
        return XBOW_SEQ_RELOAD;
    return (predicted_player.mag_crossbow > 0) ? XBOW_SEQ_IDLE1 : XBOW_SEQ_IDLE2;
};

void() CSQC_CrossbowDropClear =
{
	self.mag_crossbow = 0;
	self.ammo_crossbow = 0;
	self.zoomstage = 0;
};

void() CSQC_CrossbowEquip =
{
	self.weapon_name         = CROSSBOW_DISPLAY_NAME;
	self.weapon_viewmodel    = CROSSBOW_VIEWMODEL;
	self.weapon_worldmodel   = CROSSBOW_WORLDMODEL;
	self.weapon_deploy_sound = CROSSBOW_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictCrossbowCommand;
	self.csqc_predict_reload = CSQC_PredictCrossbowReload;
	self.csqc_display_frame  = CSQC_CrossbowDisplayFrame;
	self.csqc_drop_clear     = CSQC_CrossbowDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
