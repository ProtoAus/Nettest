// ============================================================
//  shared/weapons/sh_wpn_oppenguin.qc  -  Opposing Force penguin
//
//  Slot  : SLOT_UTILITY  (impulse 4 / key 4)
//  Stats : ammo_penguin (direct pool, max 15 — the snark's SNARK_MAX_CARRY)
//  Fire  : +attack drops a live penguin in front of you.  It hunts, bites, and
//          pops on the same fuse a snark does.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: gearbox/sprites/weapon_penguin.txt names it as one of Opposing
//  Force's ten weapons; gearbox/models/{v,p,w}_penguin.mdl and
//  w_penguinnest.mdl carry it.  Sound comes from valve's squeek/ set — gearbox
//  ships no penguin audio of its own, which is itself the tell that Opposing
//  Force reskinned the squeak grenade rather than writing a new creature.
//
//  WHAT WAS HERE BEFORE: a MODEL SWAP.  `weapon_penguin` was a
//  GoldSrc_AliasSetup onto WEP_SNARK (sv_goldsrc_pickups.qc), so picking one up
//  gave you snarks that happened to be wearing a penguin on the ground and threw
//  snarks when you fired.  It was the LAST remaining stand-in in the tree, and
//  client/cl_weaponpanel.qc labelled it as one: "Penguin ^7(Snark)".
//
//  >>> THE LIVE CREATURE IS DELIBERATELY THE SNARK'S, RE-MODELLED. <<<
//  W_PenguinSpawn calls W_SnarkSpawn and then swaps the model.  That is not
//  laziness about ~200 lines of hunt/bite/pop AI, it is the correct behaviour:
//  Opposing Force's penguin IS CSqueakGrenade with a different model, so a
//  duplicated copy of that AI could only ever drift away from the original.
//
//  It also keeps the classname "monster_snark", and that part is load-bearing
//  rather than cosmetic.  Three places key on that exact string:
//      sh_wpn_hlsnark.qc:184  - a snark does not bite another snark
//      sh_wpn_hlsnark.qc:244  - ...nor pick one as a hunt target
//      server/sv_main.qc:1113 - round cleanup findchains them
//  Under a separate "monster_penguin" classname, snarks and penguins would hunt
//  and eat each other, and a thrown penguin would survive a round restart.  The
//  two are the same creature in Opposing Force and they stay the same creature
//  here; only the model differs.

// --- Ammo field ---
// .float ammo_penguin is declared in shared/sh_weapons.qc beside .ammo_snark,
// NOT here.  sh_wpn_snowball.qc's utility ring reads it and compiles first
// (sv_progs.src line 79 against this file's 148), and QC forward-declares
// functions but not fields.  It is its OWN pool rather than the snark's:
// sharing one would make a penguin pickup refill snarks and vice versa.

// --- Sequence indices, read out of gearbox/models/v_penguin.mdl (6 seqs) -----
// Dumped rather than recalled.  Identical in shape to v_squeak.mdl's six, which
// is the other half of the evidence that this is a reskin.
const float PENG_SEQ_IDLE       = 0;   // idle1,      1.875 s (31f @ 16)  LOOPING
const float PENG_SEQ_FIDGETFIT  = 1;   // fidgetfit,  4.375 s (71f @ 16)
const float PENG_SEQ_FIDGETNIP  = 2;   // fidgetnip,  5.000 s (81f @ 16)
const float PENG_SEQ_DOWN       = 3;   // down,       1.250 s (21f @ 16)
const float PENG_SEQ_UP         = 4;   // up,         1.667 s (51f @ 30)
const float PENG_SEQ_THROW      = 5;   // throw,      0.542 s (14f @ 24)

const float PENG_FRAME_INTERVAL = 0.05;
const float PENG_DRAW_DURATION  = 1.0;     // "up" runs 1.667; 1.0 is where the
                                           // penguin is actually in shot.
const float PENG_THROW_DURATION = 0.542;   // the throw sequence's own length

const float MAX_AMMO_PENGUIN    = 15;      // the snark's SNARK_MAX_CARRY
const float PENG_DEFAULT_GIVE   = 3;       // w_penguinnest.mdl is a nest of three

// The throw itself is the snark's, so its numbers are too — see W_PenguinSpawn.
const float PENG_THROW_FORWARD  = 200;     // squeakgrenade.cpp:456
const float PENG_ATTACK_DELAY   = 0.3;     // squeakgrenade.cpp:468

const string PENG_VIEWMODEL     = "models/v_penguin.mdl";
// UNLIKE THE SNARK, the proper nest model is on the mount.  sh_wpn_hlsnark.qc:53
// records w_sqknest.mdl as missing and falls back to a lone snark for its ground
// pickup; gearbox ships w_penguinnest.mdl, so this one gets the nest it should
// have.  (valve/models/w_sqknest.mdl turns out to be present too — that comment
// is stale, and is corrected in the snark file.)
const string PENG_WORLDMODEL    = "models/w_penguinnest.mdl";
const string PENG_LIVE_MODEL    = "models/w_penguin.mdl";
const string PENG_DEPLOY_SOUND  = "";
const string PENG_DISPLAY_NAME  = "PENGUIN";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_PenguinTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= PENG_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= PENG_THROW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

float(float now) SH_PenguinTryThrow =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.ammo_penguin <= 0) return 0;

    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.attack_finished = now + PENG_ATTACK_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Additive and capped — see W_SnarkPickupCopy.
void(entity player) W_PenguinPickupCopy =
{ player.ammo_penguin = bound(0, player.ammo_penguin + self.ammo_penguin, MAX_AMMO_PENGUIN); };

// The whole creature, borrowed.  See the header for why the classname stays
// "monster_snark"; the ONLY difference between a thrown penguin and a thrown
// snark is the model on it.
//
// setsize AFTER setmodel, and not the other way round: setmodel on an alias
// model overwrites mins/maxs from the model's own bounds, so re-modelling here
// would silently resize the creature's hull away from squeakgrenade.cpp:103's
// (-4 -4 0)/(4 4 8) if the size were not restored.
entity(entity thrower, vector org, vector vel) W_PenguinSpawn =
{
    entity p = W_SnarkSpawn(thrower, org, vel);
    setmodel(p, PENG_LIVE_MODEL);
    setsize(p, '-4 -4 0', '4 4 8');
    setorigin(p, org);
    return p;
};

void() W_PenguinFire =
{
    // BEFORE the try-throw — see SH_SnarkHasReleaseRoom in sh_wpn_hlsnark.qc.
    // A blocked release costs no WS_FIRE, no action-id bump, no animation and no
    // cooldown, and is silent, as Half-Life's is.  Shared with the snark rather
    // than duplicated, the same way W_PenguinSpawn delegates to W_SnarkSpawn.
    if (!SH_SnarkHasReleaseRoom(self.v_angle)) return;
    if (!SH_PenguinTryThrow(time)) return;

    self.weaponframe   = PENG_SEQ_THROW;
    // MUST schedule, not clear — sv_weapons.qc only calls wepframe while
    // wep_nextframe > 0, and W_PenguinFrame is the ONLY route back to
    // SH_WeaponEnterIdle, so a 0 here pins weaponstate at WS_FIRE and
    // SH_PenguinTryThrow's `weaponstate != WS_IDLE` gate then refuses every
    // later throw: one penguin per equip.  Same trap the snark, satchel and
    // tripmine all had.
    self.wep_nextframe = time + PENG_FRAME_INTERVAL;

    // Re-run for the spawn point — the try-throw sits between this and the gate
    // above, so trace_endpos is re-derived rather than assumed to have survived.
    if (!SH_SnarkHasReleaseRoom(self.v_angle))
        return;

    W_PenguinSpawn(self, trace_endpos, v_forward * PENG_THROW_FORWARD + self.velocity);
    self.ammo_penguin -= 1;

    if (random() <= 0.5)
        sound(self, CHAN_VOICE, "squeek/sqk_hunt2.wav", 1, ATTN_NORM, 105, 0);
    else
        sound(self, CHAN_VOICE, "squeek/sqk_hunt3.wav", 1, ATTN_NORM, 105, 0);

    if (self.ammo_penguin <= 0)
        self.slot_utility = W_UtilityNextAfterSpent(WEP_PENGUIN);
};

void() W_PenguinFrame =
{
    float result = SH_PenguinTickState(time);
    if (result & 1)
    {
        if (self.ammo_penguin <= 0 && self.weapon == WEP_PENGUIN)
        {
            if      (self.slot_utility)   W_SelectWeapon(self.slot_utility);
            else if (self.slot_primary)   W_SelectWeapon(self.slot_primary);
            else if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     W_SelectWeapon(self.slot_melee);
            return;
        }
        self.weaponframe   = PENG_SEQ_IDLE;
        self.wep_nextframe = 0;
    }
};

void() W_PenguinEquip =
{
    W_StandardEquipSetup(PENG_VIEWMODEL, PENG_DISPLAY_NAME, PENG_SEQ_UP,
        PENG_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_PenguinFire;
    self.altfire  = __NULL__;
    self.reload   = __NULL__;
    self.wepframe = W_PenguinFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    // squeakgrenade.cpp:376 — drawing the weapon squeaks.
    if (random() <= 0.5)
        sound(self, CHAN_VOICE, "squeek/sqk_hunt2.wav", 1, ATTN_NORM, 100, 0);
    else
        sound(self, CHAN_VOICE, "squeek/sqk_hunt3.wav", 1, ATTN_NORM, 100, 0);
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_PenguinDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_penguin = self.ammo_penguin;
    self.ammo_penguin = 0;

    setmodel(tgt, PENG_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname      = "weapon_penguin";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_PENGUIN;
    tgt.weapon_slot    = SLOT_UTILITY;
    tgt.weap_draw      = W_PenguinEquip;
    tgt.weap_drop_func = W_PenguinDrop;
    tgt.pickupcopy     = W_PenguinPickupCopy;
    tgt.touch          = weapon_touch;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_penguin =
{
    setmodel(self, PENG_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname      = "weapon_penguin";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_PENGUIN;
    self.weapon_slot    = SLOT_UTILITY;
    self.weap_draw      = W_PenguinEquip;
    self.weap_drop_func = W_PenguinDrop;
    self.pickupcopy     = W_PenguinPickupCopy;
    self.touch          = weapon_touch;
    self.ammo_penguin   = PENG_DEFAULT_GIVE;
    W_RegisterMapWeapon(weapon_penguin);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictPenguinCommand =
{
    if (input_buttons & 1)
    {
        // input_angles, NOT self.v_angle — predicted_player has no v_angle on
        // CSQC.  This is the half that stops the phantom animation; a
        // server-only gate is invisible (client/cl_player.qc:1022).
        if (SH_SnarkHasReleaseRoom(input_angles)
            && SH_PenguinTryThrow(csqc_pred_time))
            CSQC_MarkPendingWeaponAck();
    }

    if (SH_PenguinTickState(csqc_pred_time) & 1)
    {
        if (self.ammo_penguin <= 0)
        {
            if      (self.slot_utility)   CSQC_PredictSelectWeapon(self.slot_utility);
            else if (self.slot_primary)   CSQC_PredictSelectWeapon(self.slot_primary);
            else if (self.slot_secondary) CSQC_PredictSelectWeapon(self.slot_secondary);
            else if (self.slot_melee)     CSQC_PredictSelectWeapon(self.slot_melee);
        }
    }
};

float(float elapsed) CSQC_PenguinDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return PENG_SEQ_UP;
    if (predicted_player.weaponstate == WS_FIRE)
        return PENG_SEQ_THROW;
    return PENG_SEQ_IDLE;   // LOOPING — safe to hold
};

void() CSQC_PenguinDropClear =
{ self.ammo_penguin = 0; };

void() CSQC_PenguinEquip =
{
    self.weapon_name         = PENG_DISPLAY_NAME;
    self.weapon_viewmodel    = PENG_VIEWMODEL;
    self.weapon_worldmodel   = PENG_WORLDMODEL;
    self.weapon_deploy_sound = PENG_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictPenguinCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_PenguinDisplayFrame;
    self.csqc_drop_clear     = CSQC_PenguinDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
