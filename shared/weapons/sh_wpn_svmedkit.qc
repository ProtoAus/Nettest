// ============================================================
//  shared/weapons/sh_wpn_svmedkit.qc  -  Sven Co-op medkit (healing tool)
//
//  Slot  : SLOT_UTILITY  (impulse 5 / key 5)
//  Stats : ammo_medkit charge pool, heals another PLAYER you aim at
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: sven-coop.fgd:6953 —
//      @PointClass base(Weapon, Targetx, ExclusiveHold)
//          studio("models/w_pmedkit.mdl") = weapon_medkit : "Medkit" []
//  and svencoop/models/{v,p,w}_medkit.mdl + w_pmedkit.mdl.
//
//  WHAT THIS REPLACES.  server/sv_goldsrc_compat.qc rewrote weapon_medkit's
//  classname to item_healthkit and called it: a 25 HP floor pickup that vanished
//  on touch.  The comment there was honest about it being a downgrade ("a player
//  expecting a carryable medkit will be surprised") and this is the thing it was
//  waiting for.
//
//  NOTE THE WORLD MODEL.  The carried weapon is w_pmedkit.mdl — "p" for player.
//  w_medkit.mdl is a DIFFERENT file and belongs to item_healthkit
//  (sven-coop.fgd:3414), which still exists and still uses it.  Getting these
//  two the wrong way round gives you a pickup that looks like a weapon.
//
//  TARGETS: OTHER PLAYERS ONLY.  Not ally NPCs — the faction layer is right
//  there and deliberately not wired in — and not yourself.
//
//  THE SECONDARY IS REVIVE, NOT SELF-HEAL.  This header used to say "Sven's
//  medkit does self-heal on secondary; that is a second fire mode and is not
//  implemented here".  That misnamed the gap: Sven's manual
//  (svencoop/manual/weapons.html) is explicit that self-heal is IMPOSSIBLE —
//      "You cannot heal yourself with the medkit.  Instead you will need to use
//       the medic command (press Z) to call for assistance."
//  and that the second fire mode is REVIVE —
//      "To revive a dead player or friendly NPC, your medkit will need to have
//       at least 50 health points stored.  Get close to the other player or NPC
//       and use the secondary fire to revive them."
//      "You can only revive players and NPCs that haven't been gibed."
//  So the weapon was missing a whole fire mode, and the note describing the gap
//  would have had us implement the one behaviour Sven deliberately does not have.
//  Revive is implemented below; PLAYERS only, see W_MedkitRevive for why NPCs
//  are not in it.

// --- Sequence indices, read out of svencoop/models/v_medkit.mdl (6 seqs) -----
// .frame is a SEQUENCE INDEX for a GoldSrc model (gl_hlmdl.c:780).  Durations
// are (numframes-1)/fps, what frameduration() reports (gl_hlmdl.c:1542).
const float MEDKIT_SEQ_IDLE     = 0;   // idle,      2.000 s  (121f @ 60)  LOOPING
const float MEDKIT_SEQ_LONGIDLE = 1;   // longidle,  2.000 s  (121f @ 60)  LOOPING
const float MEDKIT_SEQ_LONGUSE  = 2;   // longuse,   2.000 s  (121f @ 60)
const float MEDKIT_SEQ_SHORTUSE = 3;   // shortuse,  0.983 s  (60f  @ 60)
const float MEDKIT_SEQ_HOLSTER  = 4;   // holster,   fps is ZERO — see below
const float MEDKIT_SEQ_DRAW     = 5;   // draw,      0.500 s  (31f  @ 60)

// HOLSTER'S FPS IS 0 IN THE FILE.  Not a rounding artefact - the sequence header
// really carries 0.00, so (numframes-1)/fps is a divide by zero and any duration
// computed from it is 0 or a NaN depending on which engine path asks.  Nothing
// here reads it: there is no holster state in this mod's weapon machine, and the
// constant is named only so the index list reads straight against the model.

const float MEDKIT_FRAME_INTERVAL = 0.05;   // wepframe tick rate, not an anim rate

// --- Balance ---
// The charge pool.  100 is Sven's, and it is the number the HUD shows.
const float MAX_AMMO_MEDKIT   = 100;
// Per use.  20 HP for 20 charge means a full medkit is 100 HP handed to your
// team - four uses - which sits deliberately between item_healthkit's one-shot
// 25 and something that trivialises a firefight.
const float MEDKIT_HEAL       = 20;
const float MEDKIT_COST       = 20;
// Reach.  72 units is this mod's melee range (crowbar, wrench, spanner) and the
// right number for the same reason: you have to actually go and stand with them.
const float MEDKIT_RANGE      = 72;
// Matches shortuse, which is the animation a single use plays.
const float MEDKIT_FIRE_DELAY = 1.0;

// Revive, on secondary.  "at least 50 health points stored" is quoted from the
// manual and is both the gate and the cost — a revive empties half a full
// medkit, which is what makes it a decision rather than a reflex.  It plays
// LONGUSE (the 2.000 s animation), so the cooldown matches that instead of the
// 1.0 s a heal takes.
const float MEDKIT_REVIVE_COST  = 50;
const float MEDKIT_REVIVE_DELAY = 2.0;
// What the revived player comes back on.  Not full health: a revive is a second
// chance, not a reset, and coming back at 100 would make the medic strictly
// better than dying and respawning.
const float MEDKIT_REVIVE_HEALTH = 50;

// --- State durations, taken from the sequences themselves ---
const float MEDKIT_DRAW_DURATION   = 0.500;
const float MEDKIT_FIRE_DURATION   = 0.983;   // shortuse
const float MEDKIT_REVIVE_DURATION = 2.000;   // longuse

const string MEDKIT_VIEWMODEL    = "models/v_medkit.mdl";
const string MEDKIT_WORLDMODEL   = "models/w_pmedkit.mdl";
const string MEDKIT_PLAYERMODEL  = "models/p_medkit.mdl";
const string MEDKIT_DEPLOY_SOUND = "";
const string MEDKIT_DISPLAY_NAME = "MEDKIT";

// items/, not weapons/ — there is no medkit audio under sound/weapons/ at all.
const string MEDKIT_SND_HEAL1    = "items/medshot4.wav";
const string MEDKIT_SND_HEAL2    = "items/medshot5.wav";
const string MEDKIT_SND_REFUSE   = "items/medshotno1.wav";

// ============================================================
//  SHARED — state machine
// ============================================================

// Which of the two fire modes the current WS_FIRE is.  SHARED, and set by the
// shared try-functions on both sides, so the client retires the longer revive
// animation at the right moment instead of dropping back to idle a second early.
// The revive's OUTCOME is server-only; only its state and cadence are predicted,
// exactly as the heal already is.
.float medkit_reviving;

// Sub-point remainder for the regeneration below.  Server-only in practice, but
// declared here with the rest of the medkit's state because this file compiles
// into both VMs and a field declared in one is not a field in the other.
.float medkit_regen_accum;

float(float now) SH_MedkitTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= MEDKIT_DRAW_DURATION)
        {
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        float dur = self.medkit_reviving ? MEDKIT_REVIVE_DURATION
                                         : MEDKIT_FIRE_DURATION;
        if (elapsed >= dur)
        {
            self.medkit_reviving = FALSE;
            SH_WeaponEnterIdle();
            return 1;
        }
        return 0;
    }

    return 0;
};

// Hand-rolled rather than SH_StandardTryFire, because there is no magazine to
// spend and no shot to predict — which is exactly why WEP_MEDKIT has to appear
// in W_FireIsServerAutonomous (sh_weapons.qc).  A bespoke try-fire that is NOT
// in that list never emits `cmd cs`, so under the shipped sv_trust_clienthits
// the server's fire() is never called and +attack does nothing at all.
#ifdef SSQC
entity() W_MedkitFindTarget;   // defined below, beside W_MedkitUse
entity() W_MedkitFindCorpse;   // defined below, beside W_MedkitRevive
#endif

// IS THERE ANYONE TO HEAL, OR ANYONE TO REVIVE?
//
// "don't do weapon_medkit animations if no healing is going to take place" — and
// it did, on both fire modes: the gate below tested only sprint / lower / state /
// cooldown / charge, committed WS_FIRE, and the real predicate (is that a valid
// target, is it a friendly, is it already at full health, is that corpse
// revivable) ran three lines later inside W_MedkitUse.  So aiming at a wall, an
// enemy, or an ally already on full health played the entire shortuse/longuse
// take and healed nobody.
//
// The verdict is SERVER-COMPUTED and mirrored to the carrier as STAT_CAN_MEDKIT,
// the same shape the C4's plant gate uses (sh_wpn_cfc4.qc:1046).  It is not
// shareable the way the tripmine's surface trace is: W_WeaponTraceLine is server
// machinery (lag-comp rewind, corpse masking, monster cull inflation) and CSQC
// cannot see monsters at all (client/cl_monstertrace.qc:11) — friendly NPCs are
// half the valid targets, so a client-side traceline would refuse every ally.
//
// A server-only gate would have changed nothing on screen: reconcile does not
// write weaponstate back (client/cl_player.qc:1022), so CSQC would have kept
// animating regardless.  That is why the stat exists rather than just a check.
float() SH_MedkitCanHeal =
{
#ifdef CSQC
    return (getstatf(STAT_CAN_MEDKIT) & MEDKIT_CAN_HEAL);
#else
    return (W_MedkitFindTarget() != world);
#endif
};

float() SH_MedkitCanRevive =
{
#ifdef CSQC
    return (getstatf(STAT_CAN_MEDKIT) & MEDKIT_CAN_REVIVE);
#else
    return (W_MedkitFindCorpse() != world);
#endif
};

// A whiff costs this instead of the full 1 s / 2 s lockout.  Refusing to animate
// should not also cost the player the weapon for a second.
const float MEDKIT_DRYFIRE_DELAY = 0.25;

float(float now) SH_MedkitTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    // `now`-based — see sh_weapon_standard.qc SH_StandardTryFire.
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;
    if (self.ammo_medkit < MEDKIT_COST)
        return 0;

    // -1 = refuse audibly, do NOT animate.  Callers must test `== 1` and
    // `== -1`, never truthiness: -1 is truthy in QC.
    if (!SH_MedkitCanHeal())
    {
        self.attack_finished  = now + MEDKIT_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard  = now + MEDKIT_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.medkit_reviving  = FALSE;
    self.attack_finished  = now + MEDKIT_FIRE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + MEDKIT_FIRE_DELAY;
#endif
    return 1;
};

// The revive gate, shared for the same reason SH_MedkitTryFire is: a bespoke
// try-fire that both sides run keeps the animation and the cooldown in step
// without predicting the outcome.  The charge is NOT spent here — the server
// spends it in W_MedkitRevive only if a valid body was actually found, so a
// misaimed revive costs you the animation and nothing else.  Same shape as the
// heal, which refuses audibly and spends nothing.
float(float now) SH_MedkitTryRevive =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;
    // "your medkit will need to have at least 50 health points stored"
    if (self.ammo_medkit < MEDKIT_REVIVE_COST)
        return 0;

    // Same three-valued contract as SH_MedkitTryFire — see the note there.
    if (!SH_MedkitCanRevive())
    {
        self.attack_finished  = now + MEDKIT_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard  = now + MEDKIT_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.medkit_reviving  = TRUE;
    self.attack_finished  = now + MEDKIT_REVIVE_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + MEDKIT_REVIVE_DELAY;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_MedkitPickupCopy =
{
    player.ammo_medkit = bound(0, player.ammo_medkit + self.ammo_medkit, MAX_AMMO_MEDKIT);
};

// ---------------------------------------------------------------------------
//  The charge regrows.  Sven's manual states this outright and this tree never
//  implemented it:
//      "Ammo: Health points (self-generating) ... The medkit will be emptied
//       quickly if lots of people need healing, but it will slowly recharge
//       itself.  You can also refill it quickly using wall-mounted health
//       chargers once your own health is full."
//  Without it a medkit is a one-shot 100-point pool for the whole map, which
//  makes the medic role a stopwatch rather than a job.
//
//  THE RATE IS A CHOICE, and worth saying so plainly: the manual says "slowly"
//  and nothing more.  skill.cfg carries sk_plr_HpMedic (the 10-per-use heal)
//  but no regeneration figure at all — it is inside Sven's own binary — so
//  there is no number here to port.  2 points/second refills an emptied medkit
//  in 50 seconds, i.e. one heal (20 here) back every ten, which is fast enough
//  to keep a medic working between fights and far too slow to matter during
//  one.  It is a cvar so a server owner can disagree without a rebuild.
//
//  RUNS WHETHER OR NOT THE MEDKIT IS IN YOUR HANDS.  W_MedkitFrame is the
//  obvious home and the wrong one twice over: it only ticks while the weapon is
//  selected, AND it stops entirely at the idle retire (wep_nextframe = 0), so a
//  medic who put the medkit away — which is most of the time — would never
//  regenerate.  Sven's regrows in your pack.  Hence PlayerPreThink.
//
//  Ownership, not ammo, decides: W_UtilityEntityOwns is the test that keeps an
//  EMPTIED medkit yours (sh_wpn_snowball.qc), which is exactly the state that
//  needs to refill.  An ammo test here would mean a medkit that hit zero could
//  never come back.
const float MEDKIT_REGEN_PER_SEC = 2;

void(entity p) SH_MedkitRegenTick =
{
    if (p.health <= 0)
        return;
    if (!W_UtilityEntityOwns(p, WEP_MEDKIT))
        return;
    if (p.ammo_medkit >= MAX_AMMO_MEDKIT)
        return;

    float rate = cvar("sv_medkit_regen");
    if (rate < 0)
        rate = MEDKIT_REGEN_PER_SEC;
    if (rate == 0)
        return;                     // explicitly disabled

    // Accumulate in a float and only spend whole points, so the wire byte and
    // the HUD move in integers however coarse the server frame is.
    p.medkit_regen_accum += rate * frametime;
    if (p.medkit_regen_accum < 1)
        return;

    float whole = floor(p.medkit_regen_accum);
    p.medkit_regen_accum -= whole;
    p.ammo_medkit = min(MAX_AMMO_MEDKIT, p.ammo_medkit + whole);
};

// The charger half of the manual's sentence.  Called from Charger_Use once the
// player's own health is already at the cap, so a full-health medic standing at
// a wall station tops the medkit up out of the station's juice instead of
// getting the "you are full" beep and nothing else.  Returns TRUE if it took a
// point, which is what tells the charger to spend one and keep its loop sound
// running rather than shutting off.
float(entity p) SH_MedkitChargerTopUp =
{
    if (!W_UtilityEntityOwns(p, WEP_MEDKIT))
        return FALSE;
    if (p.ammo_medkit >= MAX_AMMO_MEDKIT)
        return FALSE;
    p.ammo_medkit = min(MAX_AMMO_MEDKIT, p.ammo_medkit + 1);
    return TRUE;
};

// Can this trace hit take a heal?  Deliberately its own test rather than an
// inverted W_CanDamageTarget: that helper is a damage gate with no friendly
// concept and no negative path, and there is no healing code anywhere else in
// this tree to reuse - no charger, no medic AI, no AI_Heal.
//
// `other LIVE player` is the whole rule.  Not self — Sven's manual is explicit
// that self-healing is impossible and that the `medic` call is what you use
// instead — not monsters, not props.  The DEAD are handled by the secondary
// (W_MedkitValidCorpse), which is the mirror of this test.
// FRIENDLY NPCs COUNT, and the comment above used to say they did not.
//
// Sven's manual describes the medkit as healing "a player or friendly NPC" and
// that half was simply missing: the classname test refused every monster, so a
// scientist bleeding out beside you could not be touched.  Reviving one is still
// out of scope for the reason W_MedkitValidCorpse gives - there is no AI_Revive
// and the body is disposed of - but HEALING a live ally needs none of that.
//
// "Friendly" is asked of the AI rather than of a spawnflag: .is_player_ally is
// the map's declaration and does not cover a monster_barney who simply has not
// been provoked, nor a scientist, nor anything a map cfg reclassified.  A monster
// that does not HATE you is one you may patch up, which is the same question the
// friendly-fire hold already asks (AI_Hates, sv_ai_factions.qc).
//
// Prisoners are excluded on purpose: SF_MON_PRISONER is Half-Life's "this one is
// scenery, it never fights and is never targeted", and a handcuffed prisoner is
// not a squadmate to be kept alive.
// server/sv_ai_factions.qc, which compiles after this file — same forward
// declaration block shape as the PlayerSpawn trio further down.
float(entity m, entity e) AI_Hates;

float(entity e) W_MedkitFriendlyNPC =
{
    if (!(e.flags & FL_MONSTER)) return FALSE;
    if (e.ai_prisoner)           return FALSE;
    if (e.deadflag != DEAD_NO)   return FALSE;
    return !AI_Hates(e, self);
};

// What a full tank looks like for this target.  A player's ceiling is 100; a
// monster's is whatever Monster_Build seated, which ranges from a headcrab's 10
// to a gargantua's 800 - so a fixed 100 would either refuse to touch a wounded
// grunt or over-heal a headcrab.
float(entity e) W_MedkitTargetMax =
{
    if (e.classname == "player")
        return 100;
    if (e.max_health > 0)
        return e.max_health;
    return e.health;        // never seated: treat as already full
};

float(entity e) W_MedkitValidTarget =
{
    if (!e || e == world)      return FALSE;
    if (e == self)             return FALSE;
    if (e.classname != "player" && !W_MedkitFriendlyNPC(e))
        return FALSE;
    if (e.health <= 0)         return FALSE;
    if (e.health >= W_MedkitTargetMax(e)) return FALSE;   // already full - refuse, don't waste charge
    return TRUE;
};

// The reach half of the heal predicate, split out so the per-frame stat mirror
// (sv_main.qc, STAT_CAN_MEDKIT) and the authoritative use path ask exactly the
// same question and cannot drift.  Runs on `self`.
entity() W_MedkitFindTarget =
{
    vector src, end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * MEDKIT_RANGE;

    W_WeaponTraceLine(src, end);

    if (!W_MedkitValidTarget(trace_ent))
        return world;
    return trace_ent;
};

void() W_MedkitUse =
{
    entity tgt = W_MedkitFindTarget();
    if (!tgt)
    {
        // No charge spent.  A refusal has to be audible or the weapon reads as
        // broken when you are a few units too far away or they are already full.
        sound(self, CHAN_WEAPON, MEDKIT_SND_REFUSE, 1, ATTN_NORM);
        return;
    }

    tgt.health = min(W_MedkitTargetMax(tgt), tgt.health + MEDKIT_HEAL);
    self.ammo_medkit = max(0, self.ammo_medkit - MEDKIT_COST);

    // On the TARGET, so the person being healed hears it at their own position -
    // this is their feedback as much as the medic's.
    if (random() < 0.5)
        sound(tgt, CHAN_ITEM, MEDKIT_SND_HEAL1, 1, ATTN_NORM);
    else
        sound(tgt, CHAN_ITEM, MEDKIT_SND_HEAL2, 1, ATTN_NORM);
};

void() W_MedkitFire =
{
    // `== 1` / `== -1`, never truthiness — -1 is truthy in QC, so a bare
    // `if (SH_MedkitTryFire(time))` would animate the very refusal the gate
    // exists to suppress.
    float r = SH_MedkitTryFire(time);
    if (r == 1)
    {
        self.weaponframe   = MEDKIT_SEQ_SHORTUSE;
        self.wep_nextframe = time + MEDKIT_FRAME_INTERVAL;
        W_MedkitUse();
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, MEDKIT_SND_REFUSE, 1, ATTN_NORM);
};

// All defined in sv_player.qc, which compiles after this file — the same
// forward-declaration block sv_checkpoint.qc:31-36 carries, and for the same
// reason.
void() PlayerSpawn;
void(entity p) PlayerRefreshScoreboardInfo;
void(entity p) PM_SyncPredictionProxy;

// A body this medkit could bring back.  Deliberately a separate test from
// W_MedkitValidTarget, which wants the OPPOSITE liveness: that one refuses the
// dead, this one requires them.
//
// NPCs ARE NOT IN SCOPE, and that is a real gap rather than an oversight.  Sven
// revives "a dead player or friendly NPC", but a monster in this tree does not
// survive its own death in a revivable form: sv_ai_gibs.qc disposes of the body,
// the schedule/squad state is torn down, and there is no AI_Revive to rebuild
// it.  Reviving a player is a solved problem here - trigger_respawn and
// point_checkpoint already do it - so the half that had an answer is the half
// that ships.
float(entity e) W_MedkitValidCorpse =
{
    if (!e || e == world)        return FALSE;
    if (e == self)               return FALSE;   // no self-revive, by definition
    if (e.classname != "player") return FALSE;
    if (!e.is_dead)              return FALSE;
    if (e.health > 0)            return FALSE;
    // "You can only revive players and NPCs that haven't been gibed."
    if (e.death_was_gib)         return FALSE;
    return TRUE;
};

// The reach half of the revive predicate — same split, same reason, as
// W_MedkitFindTarget above.
entity() W_MedkitFindCorpse =
{
    vector src, end;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + v_forward * MEDKIT_RANGE;

    // A corpse is SOLID_NOT, so an eye traceline goes straight through it and
    // trace_ent is whatever is behind them.  Scan the player chain for a dead
    // body within reach instead - the same "walk the players" shape the round
    // and scoreboard code uses, and cheap at this player count.
    entity best = world;
    float  bestd = MEDKIT_RANGE + 1;
    entity p = player_chain_head;
    while (p)
    {
        if (W_MedkitValidCorpse(p))
        {
            // Measure to the body's CENTRE, not its origin: a corpse's origin is
            // at its feet and the reach test would fail while you are standing
            // right over them.
            vector c = p.origin + (p.mins + p.maxs) * 0.5;
            float  d = vlen(c - src);
            if (d < bestd)
            {
                // Must be roughly in front of you, so a revive cannot be
                // performed with your back turned.
                vector to = normalize(c - src);
                if ((to * v_forward) > 0.5)
                {
                    best  = p;
                    bestd = d;
                }
            }
        }
        p = p.player_chain_next;
    }
    return best;
};

// The STAT_CAN_MEDKIT mirror, called once per player-frame from sv_main.qc for
// the carrier only.  Both find-halves run on `self`, so this rebinds and
// restores it — the caller's loop uses a local, not self.
float(entity p) W_MedkitStatBits =
{
    entity saved = self;
    float  bits  = 0;

    self = p;
    if (p.ammo_medkit >= MEDKIT_COST        && W_MedkitFindTarget() != world)
        bits = bits | MEDKIT_CAN_HEAL;
    if (p.ammo_medkit >= MEDKIT_REVIVE_COST && W_MedkitFindCorpse() != world)
        bits = bits | MEDKIT_CAN_REVIVE;
    self = saved;

    return bits;
};

void() W_MedkitRevive =
{
    entity best = W_MedkitFindCorpse();

    if (!best)
    {
        // No charge spent - see W_MedkitUse for why a refusal is audible.
        sound(self, CHAN_WEAPON, MEDKIT_SND_REFUSE, 1, ATTN_NORM);
        return;
    }

    self.ammo_medkit = max(0, self.ammo_medkit - MEDKIT_REVIVE_COST);

    // The revive itself.  THIS DOES NOT INVENT A RESPAWN MECHANISM: it is the
    // shape sv_checkpoint.qc:175-187 already uses, which is itself the shape
    // trigger_respawn established - clear the death latches, run PlayerSpawn(),
    // then move the player to where they are supposed to come back and resync
    // the prediction proxy, because there is no server-authoritative "teleport
    // this player" entry point.  Here that place is where they fell.
    vector where = best.origin;
    entity oldself = self;
    entity medic = self;

    self = best;
    best.is_dead            = FALSE;
    best.death_time         = 0;
    best.death_was_gib      = FALSE;
    best.pending_round_join = FALSE;
    PlayerRefreshScoreboardInfo(best);
    PlayerSpawn();
    setorigin(best, where);
    best.health   = MEDKIT_REVIVE_HEALTH;
    best.fixangle = TRUE;
    PM_SyncPredictionProxy(best);
    self = oldself;

    // Heard at the revived player's position - it is their feedback as much as
    // the medic's, the same argument W_MedkitUse makes for the heal.
    sound(best, CHAN_ITEM, MEDKIT_SND_HEAL1, 1, ATTN_NORM);
    sound(medic, CHAN_WEAPON, MEDKIT_SND_HEAL2, 1, ATTN_NORM);
};

void() W_MedkitAltFire =
{
    float r = SH_MedkitTryRevive(time);
    if (r == 1)
    {
        self.weaponframe   = MEDKIT_SEQ_LONGUSE;
        self.wep_nextframe = time + MEDKIT_FRAME_INTERVAL;
        W_MedkitRevive();
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, MEDKIT_SND_REFUSE, 1, ATTN_NORM);
};

void() W_MedkitFrame =
{
    float result;

    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += MEDKIT_FRAME_INTERVAL;

    result = SH_MedkitTickState(time);
    if (result & 1)
    {
        // The resting pose must be a LOOPING sequence, or once wep_anim_start
        // goes to 0 the viewmodel is clamped to its final frame and freezes for
        // the rest of the map (the trap written up in sh_wpn_thspanner.qc).
        // Sequence 0 carries STUDIO_LOOPING, so this one is safe.
        self.weaponframe   = MEDKIT_SEQ_IDLE;
        self.wep_nextframe = 0;    // idle retire — the only legal zero here
    }
};

void() W_MedkitEquip =
{
    W_StandardEquipSetup(MEDKIT_VIEWMODEL, MEDKIT_DISPLAY_NAME, MEDKIT_SEQ_DRAW,
        MEDKIT_FRAME_INTERVAL, PLAYER_ATTACKANIM_MELEE);
    self.fire     = W_MedkitFire;
    self.altfire  = W_MedkitAltFire;
    self.reload   = __NULL__;
    self.wepframe = W_MedkitFrame;
    self.shoot    = W_MedkitUse;
    self.medkit_reviving = FALSE;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_MedkitDrop =
{
    entity tgt = weapon_drop_target;

    setmodel(tgt, MEDKIT_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_medkit";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_MEDKIT;
    tgt.weapon_slot    = SLOT_UTILITY;
    tgt.weap_draw      = W_MedkitEquip;
    tgt.weap_drop_func = W_MedkitDrop;
    tgt.pickupcopy     = W_MedkitPickupCopy;
    tgt.ammo_medkit    = self.ammo_medkit;
    // Hand the charge over, exactly as W_SoflamDrop does (sh_wpn_assoflam.qc:366-367)
    // and every grenade drop before it.  Without this the medkit you put down could
    // never be picked back up: weapon_touch's duplicate-utility reject
    // (server/sv_weapons.qc:3463) asks W_UtilityEntityHasWeapon, which for the medkit
    // is ammo_medkit > 0 (sh_wpn_snowball.qc:212-213) — so a still-full pool means
    // walking back over your own medkit is silently refused forever.
    self.ammo_medkit   = 0;
    tgt.touch          = weapon_touch;
    tgt.dropped_spin   = 0;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_medkit =
{
    setmodel(self, MEDKIT_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_medkit";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_MEDKIT;
    self.weapon_slot    = SLOT_UTILITY;
    self.weap_draw      = W_MedkitEquip;
    self.weap_drop_func = W_MedkitDrop;
    self.pickupcopy     = W_MedkitPickupCopy;
    if (!self.ammo_medkit)
        self.ammo_medkit = MAX_AMMO_MEDKIT;
    self.touch          = weapon_touch;
    self.dropped_spin   = 0;
    W_RegisterMapWeapon(weapon_medkit);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictMedkitCommand =
{
    // Nothing about the heal itself is predicted — the target's health is
    // server state and a mispredicted heal would be a health bar that jumps
    // back.  Only the animation and the cooldown run here, which is what stops
    // the viewmodel waiting a round trip before it moves.
    // NOT gated on pm_suppress_sounds — see the same note in sh_wpn_assoflam.qc.
    // That flag marks a prediction REPLAY, so gating the try-fire on it stopped
    // the replay reproducing the state the live pass had predicted, and the
    // viewmodel never left idle.  There is no sound in this branch to suppress.
    if (input_buttons & 1)
    {
        // `== 1`: a -1 refusal must not claim an ack for an action that never
        // happened.  The refuse sound stays server-side — it is the server's
        // verdict being reported, and the stat this predicts from is one
        // snapshot stale, so a client-side cue could fire on a heal that
        // actually succeeded.
        if (SH_MedkitTryFire(csqc_pred_time) == 1)
            CSQC_MarkPendingWeaponAck();
    }
    // Secondary = REVIVE.  Predicted to the animation and the cooldown, never the
    // outcome.  Whether a body is in reach IS a server question — it walks the
    // player chain and reads .is_dead / .death_was_gib, neither of which the
    // client has — which is exactly why that verdict is now mirrored as
    // STAT_CAN_MEDKIT rather than assumed true.  The old comment here said "a
    // predicted revive that finds nothing still plays the animation... which is
    // what the server does too": both halves were accurate, and both were the bug.
    else if (input_buttons & 4)
    {
        if (SH_MedkitTryRevive(csqc_pred_time) == 1)
            CSQC_MarkPendingWeaponAck();
    }

    SH_MedkitTickState(csqc_pred_time);
};

// Returns a SEQUENCE index.  The engine does the within-sequence advance itself
// from .frame1time, so `elapsed` is unused — it stays in the signature because
// csqc_display_frame is a shared function-pointer type.
float(float elapsed) CSQC_MedkitDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return MEDKIT_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        // LONGUSE for a revive, SHORTUSE for a heal — the model carries both and
        // only one of them was ever played.
        return predicted_player.medkit_reviving ? MEDKIT_SEQ_LONGUSE
                                                : MEDKIT_SEQ_SHORTUSE;
    return MEDKIT_SEQ_IDLE;
};

void() CSQC_MedkitDropClear =
{
    // Mirror of the ammo hand-off W_MedkitDrop now performs on the server.  The HUD
    // charge readout is predicted_player.ammo_medkit (client/cl_hud.qc:916), so
    // without this the bar stayed full for a round trip after the drop.  The value is
    // server-authoritative (it rides the prediction proxy, server/sv_player.qc:2535 /
    // :2720, read back at client/cl_player.qc:6015), so a mispredicted drop self-heals
    // on the next snapshot.
    self.ammo_medkit = 0;
};

void() CSQC_MedkitEquip =
{
    self.weapon_name         = MEDKIT_DISPLAY_NAME;
    self.weapon_viewmodel    = MEDKIT_VIEWMODEL;
    self.weapon_worldmodel   = MEDKIT_WORLDMODEL;
    self.weapon_deploy_sound = MEDKIT_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictMedkitCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_MedkitDisplayFrame;
    self.csqc_drop_clear     = CSQC_MedkitDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
