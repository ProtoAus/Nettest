// ============================================================
//  shared/weapons/sh_wpn_hlegon.qc  -  HL Egon Gun
//
//  Slot  : SLOT_PRIMARY
//  Stats : ammo_hlegon (no magazine, direct ammo pool)
//  Fire  : Hold +attack for continuous beam weapon
//          Press → windup sound, damage + drain start immediately
//          After 3s → run sound replaces windup
//          Release → off sound, return to idle
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float ammo_hlegon;
.float egon_fire_state;       // 0=off, 1=winding up, 2=firing (run sound)
.float egon_next_drain;       // next time to drain 1 ammo
.float egon_next_damage;      // next time to deal damage pulse
.float egon_next_shake;       // HL's m_shakeTime — the egon shakes the view at
                              // the BEAM ENDPOINT while firing, but only every
                              // 1.5 s (egon.cpp:377-381), not once per pulse
.float egon_windup_end;       // time when windup ends and run sound should play

// --- Sequence indices, read out of valve/models/v_egon.mdl (11 seqs) ---
// This weapon used to drive a LOCAL IDPO conversion (models/weapons/
// wpn_hlegon/v_egon.mdl, a flat frame bake) by frame number.  It now drives
// Half-Life's own IDST model out of the `steam:Half-Life/valve` mount.
//
// For a GoldSrc model .frame is a SEQUENCE INDEX, not a frame index -
// gl_hlmdl.c:780 sets mod->numframes = numseq - so every one of the old
// constants was meaningless against it: EGON_IDLE_FRAME was 52 and this model
// has eleven sequences.  The engine animates WITHIN the sequence from
// .frame1time, which cl_weapons.qc:1696 already feeds for weapons that set
// .weapon_uses_sequences.
//
// Indices are the SDK's egon_e enum (egon.cpp:42-54); durations are the
// model's own, not the old bake's.  Which one plays when: egon.cpp:97 (draw),
// :118 (holster), :522 / :527 (idle1 / fidget1), and ev_hldm.cpp:1391+1438
// for the fire set.
//
// Every duration below is (numframes-1)/fps, because an N-frame sequence spans
// N-1 intervals — gl_hlmdl.c:1542 `*duration = (sequence->numframes-1)/
// sequence->timing`, which is what frameduration() and therefore SH_SeqDuration
// return.  Anything computed as numframes/fps is one frame period long and
// disagrees with the engine about when the animation ends.  All eleven here are
// 30 fps.
const float EGON_SEQ_IDLE1        = 0;   // idle1,        61f -> 2.000 s, looping
const float EGON_SEQ_FIDGET1      = 1;   // fidget1,      81f -> 2.667 s
const float EGON_SEQ_ALTFIREON    = 2;   // altfireon,    46f -> 1.500 s
const float EGON_SEQ_ALTFIRECYCLE = 3;   // altfirecycle, 16f -> 0.500 s, looping
const float EGON_SEQ_ALTFIREOFF   = 4;   // altfireoff,   21f -> 0.667 s
const float EGON_SEQ_FIRE1        = 5;   // fire1,         1f -> 0.000 s, looping (a hold pose)
const float EGON_SEQ_FIRE2        = 6;   // fire2,         1f -> 0.000 s, looping (a hold pose)
const float EGON_SEQ_FIRE3        = 7;   // fire3,        16f -> 0.500 s, looping
const float EGON_SEQ_FIRE4        = 8;   // fire4,        16f -> 0.500 s, looping
const float EGON_SEQ_DRAW         = 9;   // draw,         16f -> 0.500 s
const float EGON_SEQ_HOLSTER      = 10;  // holster,      16f -> 0.500 s

// The altfire trio (2..4) is dead weight here and in the retail SDK alike:
// this weapon has no altfire (self.altfire stays __NULL__), and ev_hldm.cpp:1392
// declares `g_fireAnims2[] = { EGON_ALTFIRECYCLE }` and then never reads it —
// the narrow/wide mode-switch path was cut before release, which is also why
// egon.cpp has no SecondaryAttack.  Named anyway so the next reader does not
// have to re-derive the numbering from the model.

const float EGON_FRAME_INTERVAL       = 0.05;   // wepframe tick rate, not an anim rate

const float MAX_AMMO_HLEGON           = 100;

// --- Balance ---
const float EGON_DAMAGE_PER_PULSE     = 20;
const float EGON_DAMAGE_PULSE_RATE    = 0.1;
const float EGON_AMMO_DRAIN_RATE      = 0.2;
const float EGON_BEAM_RANGE           = 2048;
const float EGON_WINDUP_TIME          = 3.0;
const float EGON_DRYFIRE_DELAY        = 0.2;

// --- State durations, taken from the sequences themselves ---
const float EGON_DRAW_DURATION        = 0.500;  // draw, (16-1)/30 — see above

// The mounted Half-Life originals.  Lowercase basenames are the on-disk
// spelling — FTE's VFS is case-sensitive against real files on Linux, and
// these resolve through the `steam:Half-Life/valve` mount rather than the
// mod's own pak.
const string EGON_VIEWMODEL    = "models/v_egon.mdl";
const string EGON_WORLDMODEL   = "models/w_egon.mdl";
const string EGON_DEPLOY_SOUND = "";
const string EGON_DISPLAY_NAME = "EGON";

const string EGON_SND_WINDUP   = "sounds/weapons/wpn_hlegon/windup.wav";
const string EGON_SND_RUN      = "sounds/weapons/wpn_hlegon/run.wav";
const string EGON_SND_OFF      = "sounds/weapons/wpn_hlegon/off.wav";

// egon.cpp:20-21 EGON_BEAM_SPRITE / EGON_FLARE_SPRITE.  Lowercase because that
// is the on-disk spelling — the SDK writes "sprites/XSpark1.spr" but the shipped
// file is xspark1.spr, and FTE's VFS is case-sensitive against real files.
// Precached with the rest of the HL equipment in sh_customdefs.qc.
const string EGON_BEAM_SPRITE  = "sprites/xbeam1.spr";
const string EGON_FLARE_SPRITE = "sprites/xspark1.spr";
// The muzzle offset in CAMERA-LOCAL form (forward, right, up).  Must stay in
// step with W_EgonMuzzle below, which is the same point in world terms; this
// form is what lets the shooter's local beam re-resolve it every render frame.
// Declared out here rather than in the SSQC block because BOTH halves use it.
const vector EGON_MUZZLE_VIEW_OFS = '0 4 -8';
// Frame count of the flare sprite, read off the file (IDSP v2, 32x32, 11 frames).
// Hardcoded rather than modelframecount()'d because this runs on the SERVER,
// which has no sprite frame data -- SV_ModelIndex only records the name.
const float EGON_FLARE_FRAMES  = 11;

// ============================================================
//  SHARED — state machine
// ============================================================

// Which of fire1..fire4 the beam is holding.
//
// ev_hldm.cpp:1391 declares `g_fireAnims1[] = { FIRE1, FIRE2, FIRE3, FIRE4 }`
// and :1438 plays `g_fireAnims1[RandomLong(0,3)]` every time the egon_fire
// event fires — once at the start of the attack and once more when pev->fuser1
// expires (egon.cpp:222 sets it to start+2, :234-237 re-plays there).  So HL
// re-rolls the hold pose twice per beam.
//
// A raw random() cannot be used for that here: this file is compiled into BOTH
// progs and the viewmodel is chosen client-side, so server and client would
// roll different sequences and the gun would sit in a different pose than the
// server thinks.  The roll is derived from state both halves already track and
// increment at the same predicted instants instead.
//
// It must be state that REACHES AN OBSERVER too, which rules out
// egon_fire_state: that field is private to this file and is never networked.
// A spectated / killcam viewmodel is rebuilt from a scratch entity carrying
// only weaponstate, wep_action_id and wep_anim_start (cl_weapons.qc:1780-1782),
// so keying on egon_fire_state made every observer read 0 and hold a pose the
// shooter was never in — and never move off it at the windup->run handoff.
// So the second input is elapsed time since wep_anim_start, which BOTH display
// paths already compute and hand to the callback (cl_weapons.qc:1611-1613 local,
// :1803 remote, and sv_player.qc:1964 ships wep_anim_start for the proxy), and
// which is the same clock egon_windup_end is set off — so the pose flips at
// exactly the instant the run sound takes over, for everyone.
//
// Fidelity caveat, stated plainly: this is a fixed cycle, not RandomLong.
// wep_action_id advances by exactly two per beam (once in W_EgonFire, once in
// the release path), so the beam counter below is `wep_action_id / 2` and its
// low two bits walk fire1..fire4 in order — all four are reached, unlike a bare
// `wep_action_id mod 4`, which with a step of two could only ever land on two of
// them.  The mid-beam re-pick is offset by 1..3 poses instead of always +1, so
// it lands somewhere different each beam.  Not uniform-random like the SDK, but
// it does use the whole set and it cannot desync.
float(entity plyr, float elapsed) SH_EgonFireSeq =
{
    float beam  = floor(plyr.wep_action_id * 0.5);
    float phase = (elapsed >= EGON_WINDUP_TIME) ? 1 : 0;   // 0 = windup, 1 = run
    float roll  = beam + phase * (1 + (beam - floor(beam / 3) * 3));
    return EGON_SEQ_FIRE1 + (roll - floor(roll * 0.25) * 4);
};

float(float now) SH_EgonTickState =
{
    float elapsed;
    if (self.weaponstate == WS_IDLE) return 0;
    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= EGON_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
    }
    return 0;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// server/sv_screenshake.qc, which compiles at sv_progs.src position 201 against
// this file's 87 — so the beam's UTIL_ScreenShake call needs the function
// forward-declared.  Inside the SSQC guard because the shake channel's sending
// half exists only in the server VM.
void(vector center, float amplitude, float frequency, float duration, float radius) SV_ScreenShake;

void(entity player) W_EgonPickupCopy =
{ player.ammo_hlegon = self.ammo_hlegon; };

// ---- The beam itself -------------------------------------------------------
//
// TWO layered beams plus an endpoint flare, per egon.cpp:433-472 (CreateEffect)
// and :406-421 (UpdateEffect).  Half-Life's egon has never been one beam, and it
// has never been a particle streak: it is a 4.0-unit sine-noise core over a
// 5.5-unit low-noise wash, both scrolling, both on sprites/xbeam1.spr.
//
// These are PERSISTENT entities that live for the whole burst (HL's are created
// with life 99999 and explicitly destroyed on stop).  The old code re-emitted a
// 0.18 s particle recipe from both the server pulse path and the between-pulse
// path, i.e. several times a second, which is what made it read as a flicker
// rather than a continuous stream.
//
// Retail Half-Life locks m_fireMode to FIRE_WIDE (egon.cpp:253), so the
// FIRE_NARROW numbers (scroll 110 / noise 5, noise beam 80,120,255 / noise 2)
// are deliberately not used here.
.entity egon_beam_core;    // m_pBeam  — the sine-noise core
.entity egon_beam_wash;    // m_pNoise — the wider, quieter wash
.entity egon_beam_flare;   // m_pSprite — endpoint flare, only on a live target

void(entity player) W_EgonBeamHide =
{
    HLBeam_EntKill(player.egon_beam_core);  player.egon_beam_core  = world;
    HLBeam_EntKill(player.egon_beam_wash);  player.egon_beam_wash  = world;
    if (player.egon_beam_flare)
    { remove(player.egon_beam_flare); player.egon_beam_flare = world; }
};

void(entity player, vector from, vector to, float on_target) W_EgonBeamShow =
{
    // egon.cpp:411 pulses the core's blue channel on |sin(time*10)| while red
    // and green sit at their timeBlend=0 values.  timeBlend itself ramps with
    // how long the trigger has been held and drives SetWidth(40 - t*20) and
    // SetBrightness(255 - t*180); it is held at 0 here, so the beam stays at its
    // full 4.0 units and full brightness for the whole burst rather than
    // thinning out.  That is a deliberate simplification, not an oversight.
    float pulse = 64 + 80 * fabs(sin(time * 10));
    vector core_col = [30, 30, pulse];

    player.egon_beam_core = HLBeam_EntUpdate(player.egon_beam_core, player,
        from, to, getmodelindex(EGON_BEAM_SPRITE),
        core_col, 255, 40, 20, 50, 0);

    player.egon_beam_wash = HLBeam_EntUpdate(player.egon_beam_wash, player,
        from, to, getmodelindex(EGON_BEAM_SPRITE),
        '50 50 255', 100, 55, 8, 25, 0);

    // egon.cpp:282-289 keeps m_pSprite EF_NODRAW'd unless the beam is actually
    // on something that takes damage — the flare is the "I am hurting this"
    // read, not a permanent part of the beam.  Spawned and removed rather than
    // flagged, since this tree has no EF_NODRAW constant.
    if (on_target)
    {
        if (!player.egon_beam_flare)
        {
            entity f = spawn();
            f.classname = "egon_flare";
            f.owner     = player;
            f.movetype  = MOVETYPE_NONE;
            f.solid     = SOLID_NOT;
            setmodel(f, EGON_FLARE_SPRITE);
            // XSpark1.spr is SPR_ADDITIVE art and HL draws it kRenderGlow 255.
            // FTE reads neither, so without this the flare is an opaque black
            // 32x32 square parked on whatever you are burning.  EF_FULLBRIGHT
            // covers the kRenderFxNoDissipation half (egon.cpp:452).
            f.effects   = f.effects | EF_ADDITIVE | EF_FULLBRIGHT;
            player.egon_beam_flare = f;
        }
        setorigin(player.egon_beam_flare, to);
        // egon.cpp:417-419: pev->frame += 8 * frametime, wrapping at Frames().
        // XSpark1.spr carries 11 of them; a static frame 0 reads as a decal
        // rather than a spark.
        player.egon_beam_flare.frame =
            player.egon_beam_flare.frame + 8 * frametime;
        if (player.egon_beam_flare.frame >= EGON_FLARE_FRAMES)
            player.egon_beam_flare.frame = 0;
    }
    else if (player.egon_beam_flare)
    {
        remove(player.egon_beam_flare);
        player.egon_beam_flare = world;
    }
};

// Where the beam leaves the gun, shared by both emit paths so they cannot drift.
vector() W_EgonMuzzle =
{
    makevectors(self.v_angle);
    return self.origin + self.view_ofs + v_right * 4 + v_up * -8;
};

void() W_EgonBeamDamage =
{
    vector src, dir, end, beam_end, muzzle;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    dir = v_forward;
    end = src + dir * EGON_BEAM_RANGE;
    muzzle = src + v_right * 4 + v_up * -8;
    W_WeaponTraceLine(src, end);
    beam_end = (trace_fraction < 1.0) ? trace_endpos : end;

    float on_target = (trace_fraction < 1.0) && W_CanDamageTarget(trace_ent);
    W_EgonBeamShow(self, muzzle, beam_end, on_target);

    if (trace_fraction < 1.0)
    {
        if (W_CanDamageTarget(trace_ent))
            W_ApplyDamage(self, trace_ent, EGON_DAMAGE_PER_PULSE);
        else
            W_ImpactEffect(trace_endpos);
        W_DebugImpact(trace_endpos, EGON_DAMAGE_PER_PULSE, W_BoneToHitgroup(trace_bone_id));
    }

    // egon.cpp:377-381.  At the BEAM ENDPOINT, not at the shooter — the egon
    // shakes what it is pointed at, over a 250-unit radius, which is why
    // standing near someone else's beam is unpleasant.  Own throttle (1.5 s)
    // rather than the damage pulse's, exactly as m_shakeTime is separate from
    // pev->dmgtime in the SDK.
    if (time >= self.egon_next_shake)
    {
        SV_ScreenShake(beam_end, 5.0, 150.0, 0.75, 250.0);
        self.egon_next_shake = time + 1.5;
    }
};

// Called by W_WeaponFrame when button0 is pressed
void() W_EgonFire =
{
    if (Weapon_SprintBlocksFire()) return;
    if (Weapon_LowerBlocksFire()) return;
    if (self.weaponstate == WS_FIRE) return;  // already firing
    if (self.weaponstate == WS_DRAW) return;
    if (self.ammo_hlegon <= 0)
    {
        self.attack_finished = time + EGON_DRYFIRE_DELAY;
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
        return;
    }

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = time;
    self.egon_fire_state = 1;
    self.egon_next_drain = time + EGON_AMMO_DRAIN_RATE;
    self.egon_next_damage = time + EGON_DAMAGE_PULSE_RATE;
    self.egon_windup_end = time + EGON_WINDUP_TIME;
    // Must come after wep_action_id and wep_anim_start are set — the pick is
    // derived from both so CSQC and any observer land on the same sequence.
    // Elapsed is 0 by construction here: this IS the start of the anim.
    self.weaponframe     = SH_EgonFireSeq(self, 0);
    self.wep_nextframe   = time + EGON_FRAME_INTERVAL;
    sound(self, CHAN_WEAPON, EGON_SND_WINDUP, 1, ATTN_NORM);
};

void() W_EgonFrame =
{
    self.wep_nextframe = time + EGON_FRAME_INTERVAL;

    if (self.weaponstate == WS_IDLE)
    { self.weaponframe = EGON_SEQ_IDLE1; return; }

    if (self.weaponstate == WS_DRAW)
    {
        // NO `self.weaponframe += 1` any more.  weaponframe is a sequence index
        // now, and incrementing it walked off the end of an eleven-sequence
        // model within half a second.  The engine advances the sub-frame itself
        // from .frame1time (cl_weapons.qc:1696), so the draw just holds its
        // sequence and ends on a clock instead of on a frame counter — the same
        // elapsed-time check SH_EgonTickState already ran for CSQC.
        self.weaponframe = EGON_SEQ_DRAW;
        float result = SH_EgonTickState(time);
        if (result & 1)
            self.weaponframe = EGON_SEQ_IDLE1;
        return;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (Weapon_LowerBlocksFire()) {
            self.weaponstate = WS_IDLE;
            W_EgonBeamHide(self);
            return;
        }

        // Released +attack or out of ammo → stop
        if (!self.button0 || self.ammo_hlegon <= 0)
        {
            self.egon_fire_state = 0;
            self.weaponstate     = WS_IDLE;
            self.wep_action_id  += 1;
            self.wep_anim_start  = 0;
            self.weaponframe     = EGON_SEQ_IDLE1;
            sound(self, CHAN_WEAPON, EGON_SND_OFF, 1, ATTN_NORM);
            W_EgonBeamHide(self);   // egon.cpp DestroyEffect
            return;
        }

        // Windup → run sound transition.  This is our analogue of the SDK's
        // pev->fuser1 re-play (egon.cpp:222, :234-237), which also re-rolls the
        // hold pose via ev_hldm.cpp:1438 — so re-roll here too.
        if (self.egon_fire_state == 1 && time >= self.egon_windup_end)
        {
            self.egon_fire_state = 2;
            sound(self, CHAN_WEAPON, EGON_SND_RUN, 1, ATTN_NORM);
            self.weaponframe     = SH_EgonFireSeq(self, time - self.wep_anim_start);
        }

        // Drain ammo
        if (time >= self.egon_next_drain)
        {
            self.ammo_hlegon -= 1;
            if (self.ammo_hlegon < 0) self.ammo_hlegon = 0;
            self.egon_next_drain = time + EGON_AMMO_DRAIN_RATE;
        }

        // Damage pulse + beam
        if (time >= self.egon_next_damage)
        {
            W_EgonBeamDamage();
            self.egon_next_damage = time + EGON_DAMAGE_PULSE_RATE;
        }
        else
        {
            // Beam visual between damage pulses — same two persistent beams,
            // just re-pointed.  It is the SAME entities the pulse path updates,
            // so this costs a delta rather than a new effect.
            vector src, end, beam_end;
            makevectors(self.v_angle);
            src = self.origin + self.view_ofs;
            end = src + v_forward * EGON_BEAM_RANGE;
            W_WeaponTraceLine(src, end);
            beam_end = (trace_fraction < 1.0) ? trace_endpos : end;
            W_EgonBeamShow(self, src + v_right * 4 + v_up * -8, beam_end,
                           (trace_fraction < 1.0) && W_CanDamageTarget(trace_ent));
        }

        // No frame cycling: fire1..fire4 are all looping sequences, so the
        // engine holds and repeats whichever one SH_EgonFireSeq picked for as
        // long as the beam is up.  The old `weaponframe += 1` walk over the
        // baked 11..51 block is what the loop flag replaces.
        return;
    }

    self.weaponframe = EGON_SEQ_IDLE1;
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
};

void() W_EgonEquip =
{
    // Was an inline copy of exactly what W_StandardEquipSetup does (model,
    // name, draw start, WS_DRAW, action id, anim start, nextframe, and the
    // altfire/altrelease/shoot/special clears).  Folded into the helper so the
    // draw SEQUENCE goes through the one place that seeds .weaponframe, the
    // same shape every migrated weapon now has.  egon.cpp:97 deploys EGON_DRAW.
    W_StandardEquipSetup(EGON_VIEWMODEL, EGON_DISPLAY_NAME, EGON_SEQ_DRAW,
        EGON_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.reload   = __NULL__;
    self.fire     = W_EgonFire;
    self.wepframe = W_EgonFrame;
    self.weapon_uses_sequences = TRUE;
    self.egon_fire_state = 0; self.egon_next_drain = 0; self.egon_next_damage = 0;
    W_EgonBeamHide(self);   // nothing should survive a re-deploy
    W_SetCrosshairProfile(0, 0, 0, 0, TRUE);
};

void() W_EgonDrop =
{
    entity tgt = weapon_drop_target;
    tgt.ammo_hlegon = self.ammo_hlegon;
    self.ammo_hlegon = 0;
    setmodel(tgt, EGON_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname = "weapon_hlegon"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_HLEGON; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_EgonEquip; tgt.weap_drop_func = W_EgonDrop;
    tgt.pickupcopy = W_EgonPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_hlegon =
{
    setmodel(self, EGON_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname = "weapon_hlegon"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_HLEGON; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_EgonEquip; self.weap_drop_func = W_EgonDrop;
    self.pickupcopy = W_EgonPickupCopy; self.touch = weapon_touch;
    self.ammo_hlegon = MAX_AMMO_HLEGON;
    W_RegisterMapWeapon(weapon_hlegon);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

// The shooter's own beam pair.
//
// HL flags the server's egon CBeams FL_SKIPLOCALHOST (egon.cpp:433-448) and has
// the firing client draw its own in EV_EgonFire (ev_hldm.cpp:1483) -- because a
// sustained beam swept across a room has to sit on the crosshair, and a
// networked one trails it by a round trip.  HLBeam_SendEntity now excludes the
// owner for the same reason, so this is the other half of that split: without
// it the shooter sees nothing at all.
//
// Globals rather than fields: there is exactly one local player, and the
// .egon_beam_* fields are declared inside the file's #ifdef SSQC block.
//
// The numbers below are deliberately identical to W_EgonBeamShow's, down to the
// sine pulse, so the shooter's beam and everyone else's are the same beam.
entity csqc_egon_beam_core;
entity csqc_egon_beam_wash;

// The dead-man timer can fire before we do (weapon switch, death, prediction
// stopping), which would leave the globals pointing at freed entities and turn
// the next CSQC_EgonBeamHide into a remove() on an already-removed entity.
// Clearing the global from the expire itself is what makes the pair safe to
// hold in globals at all.
void() CSQC_EgonBeamExpire =
{
    if (csqc_egon_beam_core == self) csqc_egon_beam_core = world;
    if (csqc_egon_beam_wash == self) csqc_egon_beam_wash = world;
    remove(self);
};

void() CSQC_EgonBeamHide =
{
    CSQC_EnvBeam_LocalKill(csqc_egon_beam_core); csqc_egon_beam_core = world;
    CSQC_EnvBeam_LocalKill(csqc_egon_beam_wash); csqc_egon_beam_wash = world;
};

void(vector from, vector to) CSQC_EgonBeamShow =
{
    float pulse = 64 + 80 * fabs(sin(time * 10));
    float sprite = getmodelindex(EGON_BEAM_SPRITE);

    csqc_egon_beam_core = CSQC_EnvBeam_Local(csqc_egon_beam_core, from, to,
        sprite, [30, 30, pulse], 255, 40, 20, 50, 0, 0);
    csqc_egon_beam_wash = CSQC_EnvBeam_Local(csqc_egon_beam_wash, from, to,
        sprite, '50 50 255', 100, 55, 8, 25, 0, 0);

    // The `from` above only seeds the beam; the muzzle end is re-derived from
    // the LIVE camera every render frame from here on.  Prediction runs at input
    // rate while the camera is rebuilt per render frame with smoothing and bob
    // applied, so a stored muzzle point lagged the eye and sat off-axis while
    // moving -- the beam appeared to trail along behind the player.  This is the
    // port of HL's attachment-anchored beam (egon.cpp:436, ev_hldm.cpp:1483);
    // only the impact end stays a snapshot, exactly as it is in HL.
    CSQC_EnvBeam_LocalAnchorToView(csqc_egon_beam_core, EGON_MUZZLE_VIEW_OFS);
    CSQC_EnvBeam_LocalAnchorToView(csqc_egon_beam_wash, EGON_MUZZLE_VIEW_OFS);

    csqc_egon_beam_core.think = CSQC_EgonBeamExpire;
    csqc_egon_beam_wash.think = CSQC_EgonBeamExpire;
};

void() CSQC_PredictEgonCommand =
{
    // Egon is continuous hold-to-fire — skip entirely during replay.
    // Server reconciliation handles the authoritative state.
    if (pm_suppress_sounds)
        return;

    float firing = (input_buttons & 1);

    if (firing && self.weaponstate != WS_FIRE)
    {
        if (self.weaponstate == WS_DRAW) return;
        if (self.ammo_hlegon <= 0)
        {
            self.attack_finished = csqc_pred_time + EGON_DRYFIRE_DELAY;
            localsound("sounds/weapons/dryfire1.wav");
            CSQC_RecordPredictedWeaponSound();
            CSQC_MarkPendingWeaponAck();
            return;
        }

        // Start fire
        self.weaponstate     = WS_FIRE;
        self.wep_action_id  += 1;
        self.wep_anim_start  = csqc_pred_time;
        self.egon_fire_state = 1;
        self.egon_next_drain = csqc_pred_time + EGON_AMMO_DRAIN_RATE;
        self.egon_windup_end = csqc_pred_time + EGON_WINDUP_TIME;
        sound(self, CHAN_WEAPON, EGON_SND_WINDUP, 1, ATTN_NONE);
        CSQC_RecordPredictedWeaponSound();
        CSQC_MarkPendingWeaponAck();
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (!firing || self.ammo_hlegon <= 0)
        {
            // Stop
            self.egon_fire_state = 0;
            self.weaponstate     = WS_IDLE;
            self.wep_action_id  += 1;
            self.wep_anim_start  = 0;
            sound(self, CHAN_WEAPON, EGON_SND_OFF, 1, ATTN_NONE);
            CSQC_RecordPredictedWeaponSound();
            CSQC_MarkPendingWeaponAck();
            CSQC_EgonBeamHide();
            return;
        }

        // Windup → run sound
        if (self.egon_fire_state == 1 && csqc_pred_time >= self.egon_windup_end)
        {
            self.egon_fire_state = 2;
            sound(self, CHAN_WEAPON, EGON_SND_RUN, 1, ATTN_NONE);
            CSQC_RecordPredictedWeaponSound();
        }

        // Drain ammo
        if (csqc_pred_time >= self.egon_next_drain)
        {
            self.ammo_hlegon -= 1;
            if (self.ammo_hlegon < 0) self.ammo_hlegon = 0;
            self.egon_next_drain = csqc_pred_time + EGON_AMMO_DRAIN_RATE;
        }

        // Draw the shooter's own beam pair, refreshed every predicted tick so
        // it stays welded to the crosshair while the beam is swept.  The
        // networked pair the server holds open (W_EgonBeamShow) is what every
        // OTHER player sees; HLBeam_SendEntity keeps it away from this one.
        makevectors(input_angles);
        vector esrc = self.origin + self.view_ofs;
        vector emuzzle = esrc + v_right * 4 + v_up * -8;
        CSQC_WeaponTraceLine(esrc, esrc + v_forward * EGON_BEAM_RANGE,
                             MOVE_NORMAL, self);
        vector eend = (trace_fraction < 1.0)
                    ? trace_endpos
                    : esrc + v_forward * EGON_BEAM_RANGE;
        CSQC_EgonBeamShow(emuzzle, eend);
    }
    else
    {
        // Not firing -- tear the local pair down.  CSQC_EnvBeam_Local also arms
        // a 0.3 s dead-man timer on every refresh, so a path that forgets this
        // (weapon switch, death, prediction simply stopping) still cannot leave
        // a beam hanging in the air.
        CSQC_EgonBeamHide();
    }

    SH_EgonTickState(csqc_pred_time);
};

// Returns a SEQUENCE index now, not an interpolated frame number.  The engine
// does the within-sequence advance itself from .frame1time, so `elapsed` no
// longer selects a sub-frame here — the manual loop wrap the fire case used to
// do by hand is replaced by the sequences' own loop flag.  It is still read,
// though: it is what tells the fire pick whether the beam is past its windup,
// and it is the one time base the remote/spectate path also supplies
// (cl_weapons.qc:1803), which is why the pick is keyed on it.
float(float elapsed) CSQC_EgonDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return EGON_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SH_EgonFireSeq(predicted_player, elapsed);
    // egon.cpp:518-531 coin-flips idle1 against fidget1 on an idle timer.
    // Neither half of this weapon has that timer, and a coin flip would be the
    // one thing the server could not agree with, so idle stays on idle1 —
    // which is looping, so it holds indefinitely on its own.
    return EGON_SEQ_IDLE1;
};

void() CSQC_EgonDropClear =
{
	self.ammo_hlegon = 0;
};

void() CSQC_EgonEquip =
{
	self.weapon_name         = EGON_DISPLAY_NAME;
	self.weapon_viewmodel    = EGON_VIEWMODEL;
	self.weapon_worldmodel   = EGON_WORLDMODEL;
	self.weapon_deploy_sound = EGON_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictEgonCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_EgonDisplayFrame;
	self.csqc_drop_clear     = CSQC_EgonDropClear;
	self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
