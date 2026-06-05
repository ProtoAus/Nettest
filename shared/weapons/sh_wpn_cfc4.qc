// ============================================================
//  shared/weapons/sh_wpn_cfc4.qc  -  C4 Plant + Defuse
//
//  Slot  : SLOT_UTILITY
//  Stats : One charge per round.  Held weapon (v_c4.mdl, GoldSrc seq)
//          plants a separate "planted_c4" world entity at the player's
//          feet.  Held weapon is consumed; planted entity owns the
//          45 s timer, beep, defuse, and detonation.
//
//  Three logical pieces, all in this file:
//    1. Held weapon — viewmodel + plant flow (cancel on early release)
//    2. Planted bomb entity — think function, beep ramp, detonation
//    3. Defuse interaction — per-frame +use poll on the planter team's
//       opposite team
//
//  The Defuse gamemode (sv_gamemode 5) wraps round-end win conditions
//  around 1 + 2 — outside that mode the C4 still functions as a
//  damaging utility weapon (no round-end trigger).
//
//  Sequence layout (v_c4.mdl):
//     0  idle_0   30 fps
//     1  select   30 fps  (pullout @ frame 1)
//     2  fire     30 fps  (commit anim, 0.87 s, no events)
//     3  prefire  50 fps  (planting hold, 3.0 s, cancellable on release)
// ============================================================

// --- Ammo (utility-style, single charge per round) ---
// .float ammo_cfc4 declared in shared/sh_weapons.qc next to the other
// utility ammo fields, so the cross-utility helpers in sh_wpn_snowball.qc
// (W_UtilityNextCarried etc.) can reference it without compile-order
// gymnastics.

// --- Sequence indices ---
const float CFC4_SEQ_IDLE    = 0;
const float CFC4_SEQ_SELECT  = 1;
const float CFC4_SEQ_FIRE    = 2;
const float CFC4_SEQ_PREFIRE = 3;

// --- Timing (held weapon) ---
const float CFC4_PREFIRE_DURATION = 3.00;   // hold +attack this long to commit
const float CFC4_FIRE_DURATION    = 0.87;   // post-commit "let go of bomb" anim
const float CFC4_SELECT_DEPLOY_TIME = 0.033;
const float CFC4_FRAME_INTERVAL   = 0.05;

// Prefire arming clicks — model's $sequence puts C4_CLICK events at
// these frames (50 fps).  We honour them from QC since FTE doesn't
// auto-play 5004 events; the planter (and nearby players) hear the
// bomb arming as the plant progresses.
const float CFC4_PREFIRE_CLICK1_TIME = 1.00;   // frame 50 / 50 fps
const float CFC4_PREFIRE_CLICK2_TIME = 1.32;   // frame 66
const float CFC4_PREFIRE_CLICK3_TIME = 1.60;   // frame 80
const float CFC4_PREFIRE_CLICK4_TIME = 1.92;   // frame 96
const float CFC4_PREFIRE_CLICK5_TIME = 2.30;   // frame 115

// --- Timing (planted bomb) ---
const float CFC4_FUSE_TIME       = 35.0;   // total countdown
const float CFC4_DEFUSE_TIME     = 5.0;    // hold +use this long
// Normal beep ramp — gap at full timeleft → gap during the ramp tail.
// Stops accelerating once we enter the final phase below.  Curve is
// quadratic (ramp²) so the gap drops slowly early and accelerates
// once the fuse is half-spent — keeps the "tension building" feel.
// MIN bumped from 0.08 to 0.18 because the late-stage cadence was
// running ~12 beeps/sec which felt frantic; 0.18 caps it at ~5.5/sec.
const float CFC4_BEEP_INTERVAL_MAX = 1.0;
const float CFC4_BEEP_INTERVAL_MIN = 0.18;
// Final-phase choreography (last 1.4 s before detonation):
//   timeleft 1.4 → 0.7  : silence (no beeps)
//   timeleft 0.7        : final beep #1
//   timeleft 0.5        : final beep #2
//   timeleft 0.0        : explode
// All anchored to c4_explode_time so the timing doesn't drift.
const float CFC4_FINAL_PHASE_DURATION = 1.4;
const float CFC4_FINAL_BEEP1_OFFSET   = 0.7;   // seconds before explode
const float CFC4_FINAL_BEEP2_OFFSET   = 0.5;

// --- Detonation (CS C4 territory) ---
const float CFC4_RADIUS        = 1024;
const float CFC4_PEAK_DAMAGE   = 500;
const float CFC4_MIN_DAMAGE    = 50;
const float CFC4_PUSH_FORCE    = 1024;
const float CFC4_PUSH_UPLIFT   = 256;

const string CFC4_VIEWMODEL    = "models/weapons/wpn_cfc4/v_c4.mdl";
const string CFC4_WORLDMODEL   = "models/weapons/wpn_cfc4/w_c4.mdl";
const string CFC4_DEPLOY_SOUND = "";
const string CFC4_DISPLAY_NAME = "C4";

const string CFC4_SND_PULLOUT = "sounds/weapons/wpn_cfc4/pullout.wav";
const string CFC4_SND_PLANT   = "sounds/weapons/wpn_cfc4/plant.wav";
const string CFC4_SND_BEEP    = "sounds/weapons/wpn_cfc4/beep.wav";
const string CFC4_SND_DISARM  = "sounds/weapons/wpn_cfc4/disarm.wav";
const string CFC4_SND_EXPLODE = "sounds/weapons/wpn_cfc4/explode.wav";

.float cfc4_snd_stage;

// --- Planted-bomb fields ---
.float c4_plant_time;       // server time when planted (== self.spawntime alias)
.float c4_explode_time;     // c4_plant_time + CFC4_FUSE_TIME
.float c4_next_beep_time;   // when to play the next beep
.float c4_last_beep_time;   // last beep — drives CSQC dlight pulse
.float c4_defuse_progress;  // 0..CFC4_DEFUSE_TIME; only nonzero while a defuse is in flight
.float c4_beep_serial;      // increments per beep; CSQC syncs the dlight pulse off this
.float c4_final_beep_stage; // 0=normal, 1=after final beep #1, 2=after final beep #2
// Snapshot of the planter's team AT PLANT TIME.  We can't derive this
// from bomb.owner.player_team because that pointer reads the LIVE
// team — if the planter swaps teams via the menu, the gate would
// follow them and the bomb thinks the new team planted it.
.float c4_planter_team;

// Forward decls — these are defined later in compile order
// (sv_player.qc / sh_pmove.qc come after weapons).  Re-declaring is
// safe in fteqcc as long as the type matches the canonical definition.
.float cmd_last_buttons;
const float CFC4_BTN_USE = 128;   // mirrors PM_BTN_USE in sh_pmove.qc:45

// ============================================================
//  SHARED — state-machine + cancel logic for held weapon
// ============================================================
//
// State usage:
//   WS_FIRE    — prefire (3.0 s plant hold, cancellable on release)
//   WS_SPECIAL — fire (0.87 s commit, non-cancellable, ends in plant)
//
// Tick state pattern: when WS_FIRE elapsed >= prefire dur AND button still
// held → transition to WS_SPECIAL (caller does this in the frame func).
// When WS_FIRE elapsed and button released → cancel.
// When WS_SPECIAL elapsed → spawn bomb + go idle.

// ============================================================
//  SERVER ONLY — held weapon + planted bomb + defuse + detonate
// ============================================================

#ifdef SSQC

// Forward decls used by other systems (sv_player.qc PlayerPreThink calls
// C4_TickDefuseInteraction; sv_main.qc's RoundRestart sweeps planted_c4).
void(entity player) C4_TickDefuseInteraction;
void() C4_PlantedThink;
void() C4_PlantedDetonate;
void(entity defuser) C4_PlantedDefuseComplete;
// Defined in sv_doors.qc, which compiles after this file.
void(entity caller, entity triggerer) Trigger_UseTargets;
float(entity playerent, float changedflags) c4_planted_SendEntity;
void() Defuse_TriggerRoundEnd;   // defined later in this file (server-only)

// Per-map override for the C4 explosion radius — set by an
// info_map_parameters entity (sv_info_map_parameters.qc) at spawn.
// 0 = no entity placed → fall back to CFC4_RADIUS in
// C4_PlantedDetonate.  Declared here because this file compiles
// before sv_info_map_parameters.qc; the latter just assigns to the
// global without redeclaring.
float map_c4_radius;
// W_CFC4Frame's leave-area cancel needs these helpers (defined further
// down the file).  Forward decls so the call site compiles.
float(vector pos) C4_PosInBombTarget;
float() C4_MapHasBombTargets;

// PlayerSpawn-time pickup hand-off: in Defuse mode, RoundStart sets this
// flag if no live red player exists; the next red player to spawn picks
// it up via PlayerSpawn check.  Cleared on assignment.
float sv_defuse_pending_red_pickup;

// ============================================================
//  HELD WEAPON
// ============================================================

void(entity player) W_CFC4PickupCopy =
{
    player.ammo_cfc4 = self.ammo_cfc4;
};

// Plant commit: spawn the planted_c4 entity on the floor under the
// planter, decrement charge, switch off this utility (auto-cycle to
// next).
void() W_CFC4PlantCommit =
{
    entity planter = self;

    // Trace from chest height (origin) straight down by 96 qu — the
    // player's bbox extends ~24 qu below the origin to their feet, so
    // an extra 72 qu of slack catches the floor on slopes / when
    // standing on a small ledge.  Land 1 qu above the hit point so
    // the bomb sits flat on the surface.  Fallback: place at the
    // player's foot height (origin + mins_z) if the trace ever fails.
    vector trace_start = planter.origin;
    vector trace_end   = trace_start;
    trace_end_z -= 96;
    traceline(trace_start, trace_end, MOVE_NORMAL, planter);

    vector floor_pos;
    vector floor_normal;
    if (trace_fraction < 1.0)
    {
        floor_pos = trace_endpos;
        floor_pos_z = trace_endpos_z + 1;
        floor_normal = trace_plane_normal;
    }
    else
    {
        floor_pos = planter.origin;
        floor_pos_z = planter.origin_z + planter.mins_z;   // foot height
        floor_normal = '0 0 1';
    }

    entity bomb = spawn();
    bomb.classname    = "planted_c4";
    bomb.owner        = planter;            // kill-credit + dlight position
    bomb.c4_planter_team = planter.player_team;   // snapshot — see field decl
    bomb.movetype     = MOVETYPE_NONE;
    bomb.solid        = SOLID_BBOX;
    setmodel(bomb, CFC4_WORLDMODEL);
    setsize(bomb, '-8 -8 0', '8 8 8');
    setorigin(bomb, floor_pos);

    // Lay flat on the surface — same algorithm CSQC_ShellSettle uses
    // for spent shell casings.  Pitch/roll derived from the floor
    // normal, yaw randomised so successive plants don't all face the
    // same direction.  For a perfectly flat floor (n_z > 0.99) we
    // skip the trig and just use angles = (0, yaw, 0).
    float yaw = random() * 360;
    if (floor_normal_z > 0.99)
    {
        bomb.angles = [0, yaw, 0];
    }
    else
    {
        vector fwd, rt;
        makevectors([0, yaw, 0]);
        fwd = v_forward;
        rt = v_right;
        bomb.angles_x = -asin(floor_normal * fwd) * (180.0 / M_PI);
        bomb.angles_z = asin(floor_normal * rt) * (180.0 / M_PI);
        bomb.angles_y = yaw;
    }

    bomb.c4_plant_time   = time;
    bomb.c4_explode_time = time + CFC4_FUSE_TIME;
    bomb.c4_next_beep_time = time;          // first beep immediately on plant
    bomb.c4_last_beep_time = time;
    bomb.c4_defuse_progress = 0;
    bomb.enemy           = world;           // current defuser; not .owner (that's the planter)
    bomb.c4_beep_serial  = 0;
    bomb.SendEntity      = c4_planted_SendEntity;
    bomb.SendFlags       = -1;              // full first-time replication
    bomb.think           = C4_PlantedThink;
    bomb.nextthink       = time + 0.05;

    sound(bomb, CHAN_VOICE, CFC4_SND_PLANT, 1, ATTN_NORM);

    // Decrement held ammo first so the auto-switch below sees no C4
    // to come back to.
    planter.ammo_cfc4 = 0;
    SH_WeaponEnterIdle();

    // Force the player off the (now-empty) C4 onto whatever they have
    // available — without this they'd keep "holding" the gone-bomb's
    // viewmodel.  Priority: primary → secondary → melee → utility.
    if (planter.slot_primary)
        W_SelectWeapon(planter.slot_primary);
    else if (planter.slot_secondary)
        W_SelectWeapon(planter.slot_secondary);
    else if (planter.slot_melee)
        W_SelectWeapon(planter.slot_melee);
    else if (planter.slot_utility)
        W_SelectWeapon(planter.slot_utility);
};

// Frame function — drives the prefire (cancellable) → fire (commit) → plant
// state transitions.  Called every server frame on the player while C4 is
// equipped.
void() W_CFC4Frame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;

    self.wep_nextframe += CFC4_FRAME_INTERVAL;

    // Deploy click — single sound event during select.
    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= CFC4_SELECT_DEPLOY_TIME && self.cfc4_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, CFC4_SND_PULLOUT, 1, ATTN_NORM);
            self.cfc4_snd_stage = 1;
        }
        if (elapsed >= SH_SeqDuration(CFC4_VIEWMODEL, CFC4_SEQ_SELECT, 1.0))
        {
            self.weaponframe   = CFC4_SEQ_IDLE;
            self.weaponstate   = WS_IDLE;
            self.wep_anim_start = 0;
            self.cfc4_snd_stage = 0;
        }
    }
    else if (self.weaponstate == WS_FIRE)
    {
        // PREFIRE phase — three cancel triggers, all snap back to idle:
        //   (a) released +attack — standard hold-to-plant cancel.
        //   (b) left the bomb_target area (only matters when
        //       mp_plantanywhere is OFF and the map has bombsites).
        // The freeze logic in sv_player.qc zeroes WASD during prefire,
        // so leaving the area realistically only happens via push /
        // teleport / explosion knockback, but covering it here keeps
        // the gate consistent.
        float left_area = FALSE;
        if (!cvar("mp_plantanywhere") && C4_MapHasBombTargets()
            && !C4_PosInBombTarget(self.origin))
            left_area = TRUE;

        if (!self.button0 || left_area)
        {
            self.weaponframe   = CFC4_SEQ_IDLE;
            self.weaponstate   = WS_IDLE;
            self.wep_anim_start = 0;
            self.cfc4_snd_stage = 0;
            return;
        }

        // Arming clicks at the model's frame events.  Each fires once
        // per plant via cfc4_snd_stage (reset on cancel / commit).
        if (elapsed >= CFC4_PREFIRE_CLICK1_TIME && self.cfc4_snd_stage < 1)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM);
            self.cfc4_snd_stage = 1;
        }
        if (elapsed >= CFC4_PREFIRE_CLICK2_TIME && self.cfc4_snd_stage < 2)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM);
            self.cfc4_snd_stage = 2;
        }
        if (elapsed >= CFC4_PREFIRE_CLICK3_TIME && self.cfc4_snd_stage < 3)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM);
            self.cfc4_snd_stage = 3;
        }
        if (elapsed >= CFC4_PREFIRE_CLICK4_TIME && self.cfc4_snd_stage < 4)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM);
            self.cfc4_snd_stage = 4;
        }
        if (elapsed >= CFC4_PREFIRE_CLICK5_TIME && self.cfc4_snd_stage < 5)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM);
            self.cfc4_snd_stage = 5;
        }

        if (elapsed >= CFC4_PREFIRE_DURATION)
        {
            // Commit point reached — transition to WS_SPECIAL (fire anim).
            self.weaponstate    = WS_SPECIAL;
            self.weaponframe    = CFC4_SEQ_FIRE;
            self.wep_anim_start = time;
            self.cfc4_snd_stage = 0;
        }
    }
    else if (self.weaponstate == WS_SPECIAL)
    {
        // FIRE phase — non-cancellable.  When elapsed >= fire duration,
        // commit the plant and exit.
        if (elapsed >= CFC4_FIRE_DURATION)
            W_CFC4PlantCommit();
    }
};

// Returns TRUE if `pos` (the planter's origin) lies inside any
// func_bomb_target volume on the map.  Walks the entity list — only
// runs when mp_plantanywhere is OFF, so the cost only matters at
// plant time anyway.  Returns FALSE if no bomb_target entities exist.
float(vector pos) C4_PosInBombTarget =
{
    entity bt = find(world, classname, "func_bomb_target");
    while (bt)
    {
        // AABB containment test against the brush's absolute bounds
        // (set by setmodel("*N") in the spawn function below).
        if (pos_x >= bt.absmin_x && pos_x <= bt.absmax_x
            && pos_y >= bt.absmin_y && pos_y <= bt.absmax_y
            && pos_z >= bt.absmin_z && pos_z <= bt.absmax_z)
            return TRUE;
        bt = find(bt, classname, "func_bomb_target");
    }
    return FALSE;
};

// Returns TRUE if any func_bomb_target entity exists on the map.
// Used to allow plant-anywhere on maps without bomb_targets even when
// mp_plantanywhere is off — so a TDM map without bombsites doesn't
// silently deny plants.
float() C4_MapHasBombTargets =
{
    return (find(world, classname, "func_bomb_target") != world);
};

void() W_CFC4Fire =
{
    if (Weapon_SprintBlocksFire()) return;
    if (Weapon_LowerBlocksFire()) return;
    // No mag / dryfire — utility-style.  Just gate on cooldown + idle.
    if (self.weaponstate != WS_IDLE)
        return;
    if (time < self.attack_finished)
        return;
    if (self.ammo_cfc4 <= 0)
        return;

    // Plant-location gate.  Three cases:
    //   1. mp_plantanywhere 1 → allow plant anywhere (testing).
    //   2. mp_plantanywhere 0 + map has func_bomb_target → must be
    //      standing inside one.
    //   3. mp_plantanywhere 0 + map has none → allow anywhere
    //      (avoids silently-denying plant on maps without bombsites).
    if (!cvar("mp_plantanywhere"))
    {
        if (C4_MapHasBombTargets() && !C4_PosInBombTarget(self.origin))
        {
            // Could pop a HUD warning here; keep silent for now.
            return;
        }
    }

    self.weaponstate    = WS_FIRE;
    self.wep_action_id += 1;
    self.wep_anim_start = time;
    self.weaponframe    = CFC4_SEQ_PREFIRE;
    self.wep_nextframe  = time + CFC4_FRAME_INTERVAL;
    self.cfc4_snd_stage = 0;
};

void() W_CFC4Equip =
{
    W_StandardEquipSetup(CFC4_VIEWMODEL, CFC4_DISPLAY_NAME, CFC4_SEQ_SELECT,
        CFC4_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CFC4Fire;
    self.reload   = __NULL__;
    self.wepframe = W_CFC4Frame;
    self.shoot    = __NULL__;
    self.cfc4_snd_stage = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

void() W_CFC4Drop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_cfc4 = self.ammo_cfc4;
    self.ammo_cfc4 = 0;

    setmodel(tgt, CFC4_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname     = "weapon_cfc4";
    tgt.solid         = SOLID_NOT;
    tgt.movetype      = MOVETYPE_TOSS;
    tgt.weapon        = WEP_CFC4;
    tgt.weapon_slot   = SLOT_UTILITY;
    tgt.weap_draw     = W_CFC4Equip;
    tgt.weap_drop_func = W_CFC4Drop;
    tgt.pickupcopy    = W_CFC4PickupCopy;
    tgt.touch         = weapon_touch;
    tgt.think         = weapon_become_solid;
    tgt.nextthink     = time + 0.7;
};

void() weapon_cfc4 =
{
    setmodel(self, CFC4_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname    = "weapon_cfc4";
    self.solid        = SOLID_TRIGGER;
    self.movetype     = MOVETYPE_TOSS;
    self.weapon       = WEP_CFC4;
    self.weapon_slot  = SLOT_UTILITY;
    self.weap_draw    = W_CFC4Equip;
    self.weap_drop_func = W_CFC4Drop;
    self.pickupcopy   = W_CFC4PickupCopy;
    self.touch        = weapon_touch;
    self.ammo_cfc4    = 1;
    W_RegisterMapWeapon(weapon_cfc4);
};

// func_bomb_target — invisible brush volume marking a bombsite.  When
// mp_plantanywhere is 0, the planter must be standing inside one of
// these to commit a plant (see W_CFC4Fire).  Map authors place these
// as brushwork in their editor; we just hook the AABB so the check
// is a cheap component-wise compare instead of a full BSP probe.
//
// SOLID_NOT so the brush doesn't block players, and EF_NODRAW so it
// stays invisible.  We don't need a touch function — the plant logic
// pulls the entity list directly.
void() func_bomb_target =
{
    setmodel(self, self.model);   // bind absmin/absmax to the brush bbox
    self.effects |= EF_NODRAW;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};

// ============================================================
//  PLANTED BOMB ENTITY
// ============================================================

// SendEntity payload (CSQC parser in cl_c4.qc reads this layout):
//   byte  CSQC_ENT_C4
//   coord ×3 origin
//   angle ×3 angles            (ground-align: pitch/yaw/roll match the surface)
//   byte  beep_serial          (CSQC pulses dlight on serial change)
//   byte  defuse_state         (0 = no defuse, 1 = defuse in progress)
float(entity playerent, float changedflags) c4_planted_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_C4);
    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);
    WriteAngle(MSG_ENTITY, self.angles_x);
    WriteAngle(MSG_ENTITY, self.angles_y);
    WriteAngle(MSG_ENTITY, self.angles_z);
    WriteByte(MSG_ENTITY, self.c4_beep_serial & 255);
    WriteByte(MSG_ENTITY, (self.enemy != world) ? 1 : 0);
    return TRUE;
};

void() C4_PlantedDetonate =
{
    // Big radius blast.  W_RadiusExplode internally sets
    // sv_in_radius_explosion so func_breakable damage actually applies.
    // Map-side info_map_parameters can override the radius via the
    // `bombradius` key (FGD: 100..2048, default 500).  When the
    // entity isn't placed, map_c4_radius stays at 0 and we fall back
    // to the weapon's compile-time default.
    float r = (map_c4_radius > 0) ? map_c4_radius : CFC4_RADIUS;
    W_RadiusExplode(self.origin, r,
        CFC4_PEAK_DAMAGE, CFC4_MIN_DAMAGE,
        CFC4_PUSH_FORCE, CFC4_PUSH_UPLIFT, self.owner);

    sound(self, CHAN_VOICE, CFC4_SND_EXPLODE, 1, ATTN_NONE);

    // Visual fireball — dedicated CSQC event so the sprite path
    // and scale are independent of the smaller grenade-explode FX.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_C4_EXPLODE);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z);
    multicast(self.origin, MULTICAST_PVS);

    // Fire the `target` chain on every func_bomb_target volume that
    // contains the bomb's origin.  Lets mappers wire scripted
    // destruction (collapsing func_breakables, opening func_doors,
    // etc.) to a successful detonation by pointing the bombsite at
    // the entities that should react.  Standard Quake trigger model:
    // each ent matching `targetname == bt.target` gets `.use()` called,
    // which for func_breakable runs the break path the same way as a
    // damage kill or a manual trigger.
    //
    // Activator is the planter so kill credit and Trigger_UseTargets-
    // dependent gamemode hooks see the right player.
    {
        entity bt = find(world, classname, "func_bomb_target");
        while (bt)
        {
            if (bt.target != "" && bt.target != "0"
                && self.origin_x >= bt.absmin_x && self.origin_x <= bt.absmax_x
                && self.origin_y >= bt.absmin_y && self.origin_y <= bt.absmax_y
                && self.origin_z >= bt.absmin_z && self.origin_z <= bt.absmax_z)
            {
                entity oldself      = self;
                entity oldactivator = activator;
                self      = bt;
                activator = oldself.owner;
                Trigger_UseTargets(self, activator);
                self      = oldself;
                activator = oldactivator;
            }
            bt = find(bt, classname, "func_bomb_target");
        }
    }

    // Round-end gate: only triggers in Defuse gamemode.
    if (cvar("sv_gamemode") == GAMEMODE_DEFUSE)
        Defuse_TriggerRoundEnd();   // RED wins — see body below

    remove(self);
};

void(entity defuser) C4_PlantedDefuseComplete =
{
    sound(self, CHAN_VOICE, CFC4_SND_DISARM, 1, ATTN_NORM);

    if (cvar("sv_gamemode") == GAMEMODE_DEFUSE)
    {
        // BLUE wins — set the round_winning_team via the helper.
        // Actual team assignment happens inside Defuse_TriggerRoundEnd
        // looking at WHO defused us (defuser's team wins).
        round_winning_team = defuser.player_team;   // captures real winner
        Defuse_TriggerRoundEnd();
    }

    remove(self);
};

void() C4_PlantedThink =
{
    // 1. Detonation
    if (time >= self.c4_explode_time)
    {
        C4_PlantedDetonate();
        return;
    }

    // 2. Beep tick — two phases.  Above CFC4_FINAL_PHASE_DURATION
    //    timeleft, beep on the accelerating ramp.  Below it, fall
    //    silent and emit the choreographed final-2-beep sequence.
    float timeleft = self.c4_explode_time - time;

    if (timeleft > CFC4_FINAL_PHASE_DURATION)
    {
        // Normal ramped beep.  Interval uses exponential decay
        //   gap = MAX * (MIN/MAX) ^ (1 - ramp)
        // which gives a constant doubling-rate (each step of `ramp`
        // halves/doubles the gap by the same proportion) so the
        // acceleration feels smooth perceptually instead of the
        // sudden mid-game drop a polynomial curve produces.
        // Pitch ramps linearly 100 → 110 alongside it.
        if (time >= self.c4_next_beep_time)
        {
            float ramp = bound(0, timeleft / CFC4_FUSE_TIME, 1);
            float pitch = 100 + (1 - ramp) * 10;
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM, pitch);
            self.c4_last_beep_time = time;
            self.c4_beep_serial = (self.c4_beep_serial + 1) & 255;
            self.SendFlags |= 1;   // CSQC dlight pulse repaint

            float ratio = CFC4_BEEP_INTERVAL_MIN / CFC4_BEEP_INTERVAL_MAX;
            float interval = CFC4_BEEP_INTERVAL_MAX * pow(ratio, 1 - ramp);
            self.c4_next_beep_time = time + interval;
        }
    }
    else
    {
        // Final-phase choreography: silence, then beep #1, beep #2,
        // then explode.  Anchored to c4_explode_time so the timing is
        // exact regardless of frame jitter.  Plays at the same vol +
        // attenuation as the routine ramp beeps so the climax cue is
        // audible — the silence gap before them already provides the
        // "something's different" punctuation.
        if (self.c4_final_beep_stage < 1
            && timeleft <= CFC4_FINAL_BEEP1_OFFSET)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM, 110);
            self.c4_last_beep_time = time;
            self.c4_beep_serial = (self.c4_beep_serial + 1) & 255;
            self.SendFlags |= 1;
            self.c4_final_beep_stage = 1;
        }
        if (self.c4_final_beep_stage < 2
            && timeleft <= CFC4_FINAL_BEEP2_OFFSET)
        {
            sound(self, CHAN_AUTO, CFC4_SND_BEEP, 1, ATTN_NORM, 110);
            self.c4_last_beep_time = time;
            self.c4_beep_serial = (self.c4_beep_serial + 1) & 255;
            self.SendFlags |= 1;
            self.c4_final_beep_stage = 2;
        }
    }

    // 3. Defuse tick — `self.enemy` is set per-frame by the player-side
    //    poll (C4_TickDefuseInteraction).  If still set + still valid,
    //    advance progress.  Otherwise reset.  Player-side poll clears
    //    enemy on look-away or release; check here is just a safety net
    //    against stale references.
    entity defuser = self.enemy;
    float dbg = cvar("sv_debug_c4");
    float defuser_valid = FALSE;
    if (defuser != world
        && defuser.classname == "player"
        && defuser.health > 0
        && defuser.player_team != self.c4_planter_team
        && (defuser.cmd_last_buttons & CFC4_BTN_USE))
    {
        defuser_valid = TRUE;
    }
    else if (dbg && defuser != world)
    {
        dprint(sprintf("[c4-bomb] defuser invalid: alive=%g team=%g held=%g\n",
            (defuser.health > 0) ? 1 : 0,
            defuser.player_team,
            (defuser.cmd_last_buttons & CFC4_BTN_USE) ? 1 : 0));
    }

    if (defuser_valid)
    {
        self.c4_defuse_progress += 0.05;   // tick interval below
        if (dbg)
            dprint(sprintf("[c4-bomb] tick progress=%.3f / %.1f\n",
                self.c4_defuse_progress, CFC4_DEFUSE_TIME));
        if (self.c4_defuse_progress >= CFC4_DEFUSE_TIME)
        {
            C4_PlantedDefuseComplete(defuser);
            return;
        }
    }
    else
    {
        self.c4_defuse_progress = 0;
        self.enemy = world;
    }

    self.nextthink = time + 0.05;
};

// ============================================================
//  DEFUSE INTERACTION — per-frame +use poll, called from PlayerPreThink
// ============================================================

void(entity player) C4_TickDefuseInteraction =
{
    // Always reset the per-client stat at the start — only the active
    // defuser will write nonzero below.  Keeps the bar hidden for
    // non-defusers (HUD gates on > 0).
    player.defuse_progress_stat = 0;

    float dbg = cvar("sv_debug_c4");

    // Cheap early-outs first.  Use input_buttons here (live current
    // command's button bits) rather than cmd_last_buttons (which is
    // last tick's data — fine during the bomb's think but stale here).
    // PM_BTN_USE (bit 7, value 128) is set continuously while +use is
    // held — see shared/sh_pmove.qc:45 + client/cl_player.qc:352.
    if (!(input_buttons & CFC4_BTN_USE))
        return;
    if (player.health <= 0)
        return;

    // Find the bomb the player is targeting.  Two-pass approach
    // mirroring SV_PlayerTryUse: a small forward tracebox first
    // (catches direct aim), then a cone-search fallback over
    // findradius hits (catches "looking near" cases — important
    // because the bomb's bbox is tiny (16×16×8) and sits on the
    // floor; the standard trace path tends to clip world geometry
    // before reaching it).
    makevectors(player.v_angle);
    vector start = player.origin + player.view_ofs;
    vector end   = start + v_forward * 96;

    entity bomb = world;

    // Pass 1 — direct trace.  Match SV_PlayerTryUse's 16×16×16 cube
    // so a near-miss aim still registers, then fall through to the
    // cone search if the trace clipped world before reaching the bomb.
    tracebox(start, '-8 -8 -8', '8 8 8', end, MOVE_NORMAL, player);
    if (trace_ent.classname == "planted_c4")
        bomb = trace_ent;

    // Pass 2 — cone fallback (within ~96 qu, dot >= 0.6 = ~53° half-cone).
    if (bomb == world)
    {
        float best_dot = 0.6;
        entity e = findradius(start, 96);
        while (e)
        {
            if (e.classname == "planted_c4")
            {
                vector to_bomb = e.origin - start;
                float d = vlen(to_bomb);
                if (d > 0)
                {
                    float dot = (to_bomb * (1.0 / d)) * v_forward;
                    if (dot > best_dot)
                    {
                        best_dot = dot;
                        bomb = e;
                    }
                }
            }
            e = e.chain;
        }
    }

    if (dbg)
        dprint(sprintf("[c4-defuse] btn-held bomb='%s' trace_frac=%.2f trace_ent='%s'\n",
            (bomb != world) ? "FOUND" : "miss",
            trace_fraction, trace_ent.classname));

    if (bomb == world)
        return;

    // Planter team can't defuse own bomb.  Uses the team snapshot
    // taken at plant time, not bomb.owner.player_team — the latter
    // would follow the planter's team if they swap teams via the menu.
    if (bomb.c4_planter_team == player.player_team)
    {
        if (dbg)
            dprint(sprintf("[c4-defuse] same-team gate (planter-at-plant %g, defuser %g)\n",
                bomb.c4_planter_team, player.player_team));
        return;
    }
    // Someone else mid-defuse — don't steal it.
    if (bomb.enemy != world && bomb.enemy != player)
        return;

    // Claim defuser status.  Bomb's think advances c4_defuse_progress.
    bomb.enemy = player;

    // Update per-player stat for HUD bar.  defuse_progress_stat is a
    // .float field auto-networked via clientstat() (declared in
    // sv_customdefs.qc); only this player's client receives this value.
    player.defuse_progress_stat = bomb.c4_defuse_progress;

    if (dbg)
        dprint(sprintf("[c4-defuse] CLAIMED progress=%.3f stat=%.3f\n",
            bomb.c4_defuse_progress, player.defuse_progress_stat));
};

// ============================================================
//  DEFUSE GAMEMODE — round-start C4 assignment + round-end trigger
// ============================================================

// Round-end trigger — sets round_winning_team based on context and
// flips round_phase via the existing elimination flow.  Caller fills
// round_winning_team for blue-wins; this function fills it for red
// (the planter team) when the bomb explodes uncontested.
void() Defuse_TriggerRoundEnd =
{
    if (round_phase != ROUND_PHASE_ACTIVE)
        return;   // already ending — don't double-trigger

    // If round_winning_team wasn't set by the caller (defuse-complete
    // path sets it to the defuser's team), this is the explode path
    // and red wins.
    if (round_winning_team == 0)
        round_winning_team = TEAM_RED;

    // Increment team score + flip phase.  Mirrors the elimination
    // path in sv_main.qc:776-816.
    if (round_winning_team == TEAM_RED)
        red_team_score += 1;
    else if (round_winning_team == TEAM_BLUE)
        blue_team_score += 1;

    round_phase = ROUND_PHASE_ROUND_END;
    round_restart_time = time + cvar("mp_roundrestartdelay");
};

// Walk player chain, gather alive red-team players, pick one at random,
// give them the C4 in utility slot.  If no live reds exist, set the
// pending flag so the next red to spawn picks it up.
void() Defuse_AssignBombAtRoundStart =
{
    if (cvar("sv_gamemode") != GAMEMODE_DEFUSE)
        return;

    sv_defuse_pending_red_pickup = 0;   // clear stale flag

    // First pass — count alive red players.
    float n = 0;
    entity p = player_chain_head;
    while (p)
    {
        if (p.player_team == TEAM_RED && p.health > 0)
            n += 1;
        p = p.player_chain_next;
    }

    if (n == 0)
    {
        // No live reds — first red to spawn gets the bomb.
        sv_defuse_pending_red_pickup = 1;
        return;
    }

    // Second pass — pick the Nth alive red.
    float pick_idx = floor(random() * n);
    float i = 0;
    entity chosen = world;
    p = player_chain_head;
    while (p)
    {
        if (p.player_team == TEAM_RED && p.health > 0)
        {
            if (i == pick_idx)
            {
                chosen = p;
                break;
            }
            i += 1;
        }
        p = p.player_chain_next;
    }
    if (chosen == world)
        return;   // race-condition safety

    // C4 lives in ammo_cfc4 only — not in slot_utility.  impulse 5
    // reads ammo_cfc4 directly to gate the select; equip happens in
    // W_TryEquipUtility's WEP_CFC4 branch.
    chosen.ammo_cfc4 = 1;
};

#endif // SSQC

// ============================================================
//  CLIENT — predict + display + drop-clear
// ============================================================

#ifdef CSQC

float csqc_cfc4_snd_stage;
float csqc_cfc4_snd_action;

// Idle-loop anchor — same pattern as butterfly.  The proxy serializes
// wep_anim_start as elapsed-since-anim-start and the receiver
// reconstructs it as `cltime - elapsed`, which means in steady-state
// idle the value keeps drifting.  We capture cltime on the
// non-idle → idle edge and feed the renderer a fresh "0 → growing"
// frame1time via csqc_viewmodel_sequence_time_override so the idle
// loop always restarts from frame 0 every time we land back here.
float csqc_cfc4_idle_anchor;
float csqc_cfc4_prev_seen_state;

// Client predict — same shape as the rifles' predict, but the held C4
// has no fire-sound / hit-sound to mirror; sounds (pullout, plant) are
// timed-event broadcasts the server fires that arrive via normal sound
// replication.  All we need is the cancel-on-release in WS_FIRE so the
// client's predicted state matches.
void() CSQC_PredictCFC4Command =
{
    float elapsed;

    if (predicted_player.wep_action_id != csqc_cfc4_snd_action)
    {
        csqc_cfc4_snd_action = predicted_player.wep_action_id;
        csqc_cfc4_snd_stage  = 0;
    }

    // Initial press → enter prefire.
    if ((input_buttons & 1)
        && self.weaponstate == WS_IDLE
        && csqc_pred_time >= self.attack_finished
        && self.ammo_cfc4 > 0)
    {
        self.weaponstate    = WS_FIRE;
        self.wep_action_id += 1;
        self.wep_anim_start = csqc_pred_time;
        self.weaponframe    = CFC4_SEQ_PREFIRE;
        CSQC_MarkPendingWeaponAck();
    }

    // Cancel on release during prefire.
    if (self.weaponstate == WS_FIRE && !(input_buttons & 1))
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (elapsed < CFC4_PREFIRE_DURATION)
        {
            self.weaponstate   = WS_IDLE;
            self.wep_anim_start = 0;
            self.weaponframe   = CFC4_SEQ_IDLE;
        }
    }

    // Transition to commit (WS_SPECIAL) when prefire elapsed + button held.
    // Also fire predicted arming clicks at the model's $sequence event
    // timings — same elapsed moments as the SSQC W_CFC4Frame so the
    // dedup window suppresses the server echo.
    if (self.weaponstate == WS_FIRE && (input_buttons & 1))
    {
        elapsed = csqc_pred_time - self.wep_anim_start;

        if (!pm_suppress_sounds)
        {
            // Each click both plays the localsound AND timestamps the
            // planter-flash for the per-frame red dlight pulse on the
            // local player (CSQC_C4_DrawPlanterFlash).
            if (csqc_cfc4_snd_stage < 1 && elapsed >= CFC4_PREFIRE_CLICK1_TIME)
            { localsound(CFC4_SND_BEEP); CSQC_RecordPredictedAutoSound(); csqc_cfc4_planter_flash_time = cltime; csqc_cfc4_snd_stage = 1; }
            if (csqc_cfc4_snd_stage < 2 && elapsed >= CFC4_PREFIRE_CLICK2_TIME)
            { localsound(CFC4_SND_BEEP); CSQC_RecordPredictedAutoSound(); csqc_cfc4_planter_flash_time = cltime; csqc_cfc4_snd_stage = 2; }
            if (csqc_cfc4_snd_stage < 3 && elapsed >= CFC4_PREFIRE_CLICK3_TIME)
            { localsound(CFC4_SND_BEEP); CSQC_RecordPredictedAutoSound(); csqc_cfc4_planter_flash_time = cltime; csqc_cfc4_snd_stage = 3; }
            if (csqc_cfc4_snd_stage < 4 && elapsed >= CFC4_PREFIRE_CLICK4_TIME)
            { localsound(CFC4_SND_BEEP); CSQC_RecordPredictedAutoSound(); csqc_cfc4_planter_flash_time = cltime; csqc_cfc4_snd_stage = 4; }
            if (csqc_cfc4_snd_stage < 5 && elapsed >= CFC4_PREFIRE_CLICK5_TIME)
            { localsound(CFC4_SND_BEEP); CSQC_RecordPredictedAutoSound(); csqc_cfc4_planter_flash_time = cltime; csqc_cfc4_snd_stage = 5; }
        }

        if (elapsed >= CFC4_PREFIRE_DURATION)
        {
            self.weaponstate    = WS_SPECIAL;
            self.wep_anim_start = csqc_pred_time;
            self.weaponframe    = CFC4_SEQ_FIRE;
            csqc_cfc4_snd_stage = 0;
        }
    }

    // After the fire anim, we don't predict the bomb spawn — server
    // is authoritative for that, and the snapshot will reset our state.
    if (self.weaponstate == WS_SPECIAL)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (elapsed >= CFC4_FIRE_DURATION)
        {
            self.weaponstate   = WS_IDLE;
            self.wep_anim_start = 0;
            self.weaponframe   = CFC4_SEQ_IDLE;
        }
    }
};

float(float elapsed) CSQC_CFC4DisplayFrame =
{
    float ws = predicted_player.weaponstate;

    // Capture cltime on the non-idle → idle edge so the renderer below
    // can hand the engine a fresh "0 → growing" sequence time on every
    // entry to idle.  Display runs once per render frame, so
    // prev_seen_state correctly tracks last-frame state.
    if (ws == WS_IDLE && csqc_cfc4_prev_seen_state != WS_IDLE)
        csqc_cfc4_idle_anchor = cltime;
    csqc_cfc4_prev_seen_state = ws;

    if (ws == WS_DRAW)
        return CFC4_SEQ_SELECT;
    if (ws == WS_FIRE)
        return CFC4_SEQ_PREFIRE;
    if (ws == WS_SPECIAL)
        return CFC4_SEQ_FIRE;

    // Idle — override frame1time to a wrapped (cltime - anchor) so the
    // idle loop restarts from frame 0 the moment we land here AND
    // continues looping past its natural end.  The model's idle_0
    // sequence isn't flagged `loop` in its $sequence declaration, so
    // the engine would otherwise clamp at the last frame and freeze.
    // Manual wrap to the seq's reported duration gives the equivalent
    // of a loop flag without an art-side change.
    float idle_dur = SH_SeqDuration(CFC4_VIEWMODEL, CFC4_SEQ_IDLE, 2.0);
    float t = cltime - csqc_cfc4_idle_anchor;
    if (idle_dur > 0)
        t = t - floor(t / idle_dur) * idle_dur;
    csqc_viewmodel_sequence_time_override = TRUE;
    csqc_viewmodel_sequence_time = max(0, t);
    return CFC4_SEQ_IDLE;
};

void() CSQC_CFC4DropClear =
{
    self.ammo_cfc4 = 0;
};

void() CSQC_CFC4Equip =
{
    self.weapon_name         = CFC4_DISPLAY_NAME;
    self.weapon_viewmodel    = CFC4_VIEWMODEL;
    self.weapon_worldmodel   = CFC4_WORLDMODEL;
    self.weapon_deploy_sound = CFC4_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictCFC4Command;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_CFC4DisplayFrame;
    self.csqc_drop_clear     = CSQC_CFC4DropClear;
    self.weapon_uses_sequences = TRUE;
    self.weapon_viewmodel_flip = TRUE;
};

#endif // CSQC
