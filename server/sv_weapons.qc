// ============================================================
//  server/sv_weapons.qc  -  Core weapon system
//  Damage helpers, weapon pickup touch, weapon slot management.
// ============================================================

// Forward declarations
void(entity player) PM_SyncPredictionProxy;  // defined in sv_player.qc
void(entity player) Player_VisualProxy_DetachAsCorpse;  // defined in sv_player.qc
void() W_DeagleEquip;         // defined in wpn_deagle.qc
void() W_DeagleDrop;          // defined in wpn_deagle.qc
void() W_KnifeEquip;
void() W_KnifeDrop;
void() W_AK47Equip;
void() W_AK47Drop;
void() W_M4A1Equip;
void() W_M4A1Drop;
void() W_FlakShotgunEquip;
void() W_FlakShotgunDrop;
void() W_PistolEquip;
void() W_PistolDrop;
void() W_ScoutEquip;
void() W_ScoutDrop;
void() W_357Equip;
void() W_357Drop;
void() W_WrenchEquip;
void() W_WrenchDrop;
void() W_M249Equip;
void() W_M249Drop;
void() W_AWPEquip;
void() W_AWPDrop;
void() W_98KEquip;
void() W_98KDrop;
void() W_CrowbarEquip;
void() W_CrowbarDrop;
void() W_ShotgunEquip;
void() W_ShotgunDrop;
void() W_M3Equip;
void() W_M3Drop;
void() W_MP5Equip;
void() W_MP5Drop;
void() W_CrossbowEquip;
void() W_CrossbowDrop;
void() W_GLEquip;
void() W_GLDrop;
void() W_RebarEquip;
void() W_RebarDrop;
void() W_GaussEquip;
void() W_GaussDrop;
void() W_GlockEquip;
void() W_GlockDrop;
void() W_G3SG1Equip;
void() W_G3SG1Drop;
void() W_HLSMGEquip;
void() W_HLSMGDrop;
void() W_RPGEquip;
void() W_RPGDrop;
void() W_HLGrenadeEquip;
void() W_HLGrenadeDrop;
void() W_HLGlockEquip;
void() W_HLGlockDrop;
void() W_EgonEquip;
void() W_EgonDrop;
void() W_CSUSPEquip;
void() W_CSUSPDrop;
void() weapon_csusp;
void() weapon_deagle;
void() weapon_m4a1;
void() weapon_ak47;
void() weapon_pistol;
void() weapon_flakshotgun;
void() weapon_scout;
void() weapon_357;
void() weapon_wrench;
void() weapon_m249;
void() weapon_csawp;
void() weapon_dod98k;
void() weapon_hlcrowbar;
void() weapon_hlshotgun;
void() weapon_csm3;
void() weapon_csmp5;
void() weapon_crossbow;
void() weapon_grenadelauncher;
void() weapon_rebar;
void() weapon_gauss;
void() weapon_glock;
void() weapon_g3sg1;
void() weapon_hlsmg;
void() weapon_hlrpg;
void() weapon_hlgrenade;
void() weapon_hlglock;
void() weapon_hlegon;
void() PlayerSpawn;           // defined in sv_player.qc
void(float) W_SelectWeapon;   // defined later in this file
void() weapon_become_solid;   // defined later in this file
void() weapon_settle_think;   // defined later in this file
float(entity, float) dropped_weapon_SendEntity;  // defined later in this file
void() W_DropAllWeaponsOnDeath;  // defined later in this file

// Global set by W_DropCurrentWeapon before calling the slot drop function.
// The drop function reads this to know which entity to populate.
entity weapon_drop_target;

// Per-entity fail-safe: even if a dropped weapon is perched on a fragile
// slope and never quite stops bouncing, force it to settle by this time
// so we don't keep polling forever.
.float weapon_settle_deadline;

// Absolute server time at which a dropped weapon transitions from the
// toss phase (SOLID_NOT, players can't grab it) to the settled-trigger
// phase.  Set to (spawn_time + 0.7) when the drop is created.  Driven
// by weapon_become_solid's dual-phase logic — while time < this value
// the function just bumps SendFlags and reschedules; once crossed it
// finalises the solid state and hands off to weapon_settle_think.
.float weapon_solid_time;

// ============================================================
//  Map weapon registration — call from weapon_*() spawn functions
//  Records origin + spawn function so the weapon can be recreated on round reset.
// ============================================================

float sv_debug_weapon_spawning;   // TRUE during debug weapon spawn — skips map registration

void(void() spawn_func) W_RegisterMapWeapon =
{
    if (sv_debug_weapon_spawning)
        return;

    // Record the spec (origin, angles, spawn function) on the entity up
    // front — even if mp_nomapweapons is currently on.  Keeping the
    // entity alive (just hidden) means flipping the cvar off later can
    // re-run map_weapon_spawn to bring the weapon back exactly where the
    // mapper placed it.  If we instead remove()'d, the spawn_func pointer
    // would be lost and the weapon could never respawn until a map change.
    if (!self.map_weapon)
    {
        self.map_weapon_origin = self.origin;
        self.map_weapon_angles = self.angles;
    }

    self.map_weapon = TRUE;
    self.map_weapon_spawn = spawn_func;

    // mp_nomapweapons: hide the entity (no model, no collision, no
    // CSQC replication, no think).  The bookkeeping above still stands
    // so W_RespawnMapWeapons can revive us on round restart when the
    // cvar is off.
    if (cvar("mp_nomapweapons") > 0)
    {
        setmodel(self, "");
        self.modelindex = 0;
        self.solid      = SOLID_NOT;
        self.movetype   = MOVETYPE_NONE;
        self.SendEntity = __NULL__;
        self.SendFlags  = 0;
        self.think      = __NULL__;
        self.nextthink  = 0;
        return;
    }

    // Snap to the floor at spawn time. W_RespawnMapWeapons does the
    // same on round restart, which is why round-2+ weapons appeared
    // grounded while the round-1 (initial map load) ones floated.
    // Fallback velocity if droptofloor fails (e.g. mapper placed in a
    // void) — matches the W_RespawnMapWeapons fallback pattern.
    self.velocity = '0 0 -100';
    if (!droptofloor())
        self.velocity = '0 0 -200';

    // Enable CSQC replication for pickup prediction. Unlike player-
    // dropped weapons, map weapons are pickup-ready immediately, so we
    // wire SendEntity here rather than in weapon_become_solid.
    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = dropped_weapon_SendEntity;
    self.SendFlags = 1;

    // Run settle_think to bump SendFlags every 0.2s while the engine
    // TOSS physics still has residual motion (from droptofloor's
    // fallback velocity or if it failed). Once motion stops, settle
    // aligns angles to the floor normal and halts the think.
    self.weapon_settle_deadline = time + 10;
    self.think     = weapon_settle_think;
    self.nextthink = time + 0.2;
};

// Respawn all map weapons — called from RoundRestart
void() W_RespawnMapWeapons =
{
    entity e, next, saved;
    float  strip_map_weapons = (cvar("mp_nomapweapons") > 0);

    e = nextent(world);
    while (e)
    {
        next = nextent(e);

        if (e.classname != "player" && e.classname != "pm_csqc_proxy"
            && e.weapon && e.weapon != WEP_NONE)
        {
            if (e.map_weapon)
            {
                saved = self;
                self = e;
                if (strip_map_weapons)
                {
                    // mp_nomapweapons on — hide the entity but keep all
                    // map_weapon bookkeeping (origin/angles/spawn_func)
                    // intact so a later round can revive it verbatim.
                    // Mirrors the hide path in W_RegisterMapWeapon.
                    setmodel(self, "");
                    self.modelindex = 0;
                    self.solid      = SOLID_NOT;
                    self.movetype   = MOVETYPE_NONE;
                    self.SendEntity = __NULL__;
                    self.SendFlags  = 0;
                    self.think      = __NULL__;
                    self.nextthink  = 0;
                }
                else
                {
                    // Reset to original state.  Works for both "was live"
                    // and "was hidden last round" — the nested
                    // W_RegisterMapWeapon call inside map_weapon_spawn
                    // sees the cvar is off and re-wires model/SendEntity/
                    // think exactly like first-time spawn.
                    setorigin(self, self.map_weapon_origin);
                    self.angles = self.map_weapon_angles;
                    self.map_weapon_spawn();     // re-runs weapon_ak47() etc.
                    // Ensure weapon falls to the ground after respawn.
                    // The spawn sets MOVETYPE_TOSS; give it a real downward
                    // velocity so it visibly drops and settles.
                    self.velocity = '0 0 -100';
                    if (!droptofloor())
                        self.velocity = '0 0 -200';
                }
                self = saved;
            }
            else
            {
                // Remove dropped weapons
                remove(e);
            }
        }

        e = next;
    }
};

// ============================================================
//  W_SetCrosshairProfile
//  Called by every weapon equip function to declare its crosshair
//  parameters.  The engine auto-networks the fields to the client
//  via clientstat() so the crosshair reacts on the next server frame.
//
//  show_crosshair: TRUE = show crosshair (guns); FALSE = hide (knife)
// ============================================================

void() W_ClearZoom =
{
    self.zoomstage = 0;
    self.sv_zoomstage = 0;
};

void(float basespread, float movespread, float fullspeed,
     float gapscale, float show_crosshair) W_SetCrosshairProfile =
{
    self.sv_crosshair_basespread = basespread;
    self.sv_crosshair_movespread = movespread;
    self.sv_crosshair_fullspeed  = fullspeed;
    self.sv_crosshair_gapscale   = gapscale;
    self.sv_crosshair_disabled   = !show_crosshair;
};

// ============================================================
//  Hitgroup system — bone-based damage multipliers
//  Uses MOVE_HITMODEL to trace against HLMDL hitboxes.
//  trace_bone_id is 1-based (0 = unknown).
// ============================================================

// W_BoneToHitgroup + W_HitgroupDamageMultiplier moved to shared/sh_weapon_logic.qc
// so CSQC can call them too (needed for predicted-death's lethality math).
// They're pure functions of trace_ent + bone_id — work identically on either side.

string(float hitgroup) W_HitgroupName =
{
    switch (hitgroup)
    {
    case HITGROUP_HEAD:     return "head";
    case HITGROUP_CHEST:    return "chest";
    case HITGROUP_STOMACH:  return "stomach";
    case HITGROUP_LEFTARM:  return "left arm";
    case HITGROUP_RIGHTARM: return "right arm";
    case HITGROUP_LEFTLEG:  return "left leg";
    case HITGROUP_RIGHTLEG: return "right leg";
    default:                return "body";
    }
};

// Temporarily expand every alive player's bbox by sv_hitbox_expand so weapon
// traces (MOVE_HITMODEL) can reach outstretched limbs.  Movement is
// unaffected: pmove uses the PM_MINS/PM_MAXS constants directly, not
// self.mins/self.maxs — so player-vs-player collision stays at the
// true movement hull.
//
// Z is expanded too (was X+Y only).  Without it, ducking players —
// whose duck-hull caps at PM_DUCK_MAXS_z = 18u above origin — had any
// head-bone above that height culled before MOVE_HITMODEL even reached
// the per-bone test.  cl_debug_hbexpand 1 made this visible.  Bigger
// bbox is purely an early-out / cull volume; the actual hit decision
// is per-bone, so expanding can only add forgiveness, never produce
// false hits above/below the real hitboxes.
//
// Must be paired with W_PlayersRestoreHitboxes after the trace(s).
// Lag comp still works because we're expanding the real player entity
// (not a separate proxy); MOVE_LAGGED rewinds origin and the expanded
// bbox moves with it.
//
// Expand/restore use delta math (read current mins/maxs, shift, write back)
// so we don't need to know the normal vs ducking hull values here.
void() W_PlayersExpandHitboxes =
{
    float expand = cvar("sv_hitbox_expand");
    if (expand <= 0) return;

    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead && p.solid == SOLID_SLIDEBOX)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x -= expand; mn_y -= expand; mn_z -= expand;
            mx_x += expand; mx_y += expand; mx_z += expand;
            setsize(p, mn, mx);
        }
        p = p.player_chain_next;
    }
};

void() W_PlayersRestoreHitboxes =
{
    float expand = cvar("sv_hitbox_expand");
    if (expand <= 0) return;

    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead && p.solid == SOLID_SLIDEBOX)
        {
            vector mn = p.mins;
            vector mx = p.maxs;
            mn_x += expand; mn_y += expand; mn_z += expand;
            mx_x -= expand; mx_y -= expand; mx_z -= expand;
            setsize(p, mn, mx);
        }
        p = p.player_chain_next;
    }
};

// Send the server's view of a target's hitbox state to the shooter.
// The client creates a ghost entity from this and draws orange hitbox wireframes.
// Mode 1 = per-shot snapshot (this function). Mode 2 = continuous, handled
// in sv_main.qc's StartFrame. Wire format is identical so the client parser
// is a single path.
void(entity target) W_SendServerHitboxes =
{
    if (cvar("sv_debug_hitboxes") != 1)
        return;
    if (!target || target.classname != "player")
        return;

    msg_entity = self;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_SERVER_HITBOXES);
    WriteByte(MSG_ONE, num_for_edict(target));
    WriteShort(MSG_ONE, target.modelindex);
    WriteCoord(MSG_ONE, target.origin_x);
    WriteCoord(MSG_ONE, target.origin_y);
    WriteCoord(MSG_ONE, target.origin_z);
    WriteFloat(MSG_ONE, target.angles_x);
    WriteFloat(MSG_ONE, target.angles_y);
    WriteFloat(MSG_ONE, target.angles_z);
    WriteByte(MSG_ONE, target.frame);
    WriteByte(MSG_ONE, target.baseframe);
    WriteByte(MSG_ONE, target.basebone);
    WriteFloat(MSG_ONE, target.frame1time);
    WriteFloat(MSG_ONE, target.baseframe1time);
    WriteFloat(MSG_ONE, target.subblendfrac);
    WriteFloat(MSG_ONE, target.subblend2frac);
    WriteFloat(MSG_ONE, target.bonecontrol1);
    WriteFloat(MSG_ONE, target.bonecontrol2);
    WriteFloat(MSG_ONE, target.bonecontrol3);
    WriteFloat(MSG_ONE, target.bonecontrol4);
    WriteByte(MSG_ONE, 1); // mode: 1 = per-shot snapshot
};

// ============================================================
//  W_WeaponTraceLine
//  Lag-compensated traceline wrapper used by melee and hitscan.
// ============================================================

void(vector src, vector end) W_WeaponTraceLine =
{
    // No MOVE_LAGGED: our QC ring buffer (sv_lagcomp.qc) has already
    // rewound every other player to the shooter's view-time before
    // this trace runs. Passing the engine flag would trigger a second,
    // independent rewind on top of ours.
    Lagcomp_TraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);
};

// ============================================================
//  SpawnImpactLight / PlayerModelPlayPrimaryAttack
//  Stub implementations — extend later for visual effects and
//  player animation events.
// ============================================================

void(vector pos) SpawnImpactLight =
{
    // placeholder: add a dynamic light or particle burst here
};

// Inspect trace_ent and return an IMPACT_MAT_* code so CSQC can pick the
// right particle effect per surface. Players → flesh, func_breakable →
// material from .style, anything else → default (concrete-dust look).
float(entity hit) W_ClassifyImpactMaterial =
{
    if (hit && hit.classname == "player")
        return IMPACT_MAT_FLESH;
    if (hit && hit.classname == "func_breakable")
    {
        float s = hit.style;
        if (s == BREAKABLE_FLESH)                                         return IMPACT_MAT_FLESH;
        if (s == BREAKABLE_GLASS)                                         return IMPACT_MAT_GLASS;
        if (s == BREAKABLE_WOOD)                                          return IMPACT_MAT_WOOD;
        if (s == BREAKABLE_METAL || s == BREAKABLE_MACHINE
                                 || s == BREAKABLE_CIRCUIT)               return IMPACT_MAT_METAL;
    }
    // Physics props — sparks + metal ric, no hole decal. The hole
    // spawn is already blocked by CSQC_SpawnBulletHole's
    // `solid != SOLID_BSP` guard (phys props are SOLID_PHYSICS_BOX).
    if (hit && (hit.classname == "phys_barrel" || hit.classname == "phys_can"))
        return IMPACT_MAT_METAL;
    return IMPACT_MAT_DEFAULT;
};

// Send bullet impact effect to all players EXCEPT the shooter.
// The shooter sees their own predicted impact instantly.
void(vector pos) W_ImpactEffect =
{
    if (pointcontents(pos + trace_plane_normal * -2) == CONTENT_SKY)
        return;

    float mat = W_ClassifyImpactMaterial(trace_ent);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            // Normal is a unit vector (components in [-1,+1]); quantise to
            // a signed byte biased by 127 to save 9 B/event over WriteCoord.
            WriteByte(MSG_ONE, bound(0, rint(127 + trace_plane_normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + trace_plane_normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + trace_plane_normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            // Target entnum so remote clients can attach bullet-hole
            // decals to the correct func_breakable / BSP entity and
            // remove them on CSQC_EVENT_BRUSH_DESTROY. 0 = world /
            // non-BSP hit (client treats as stationary world decal).
            WriteShort(MSG_ONE, num_for_edict(trace_ent));
        }
        p = p.player_chain_next;
    }
};

// Impact effect sent to all OTHER players, with the material classified
// from the current trace_ent. The shooter already predicted the first-hit
// ric via CSQC_BulletImpact; for post-penetration and exit impacts CSQC
// can't predict, so in those cases the shooter simply gets no ric for the
// follow-up hits — still better than a ping-delayed echo layered on top
// of their predicted entry sound.
void(vector pos, vector normal) W_ImpactEffectAll =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    float mat = W_ClassifyImpactMaterial(trace_ent);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            WriteShort(MSG_ONE, num_for_edict(trace_ent));   // target entnum for decal attach
        }
        p = p.player_chain_next;
    }
};

// Same as W_ImpactEffectAll but with an explicit material code, bypassing
// the auto-classifier. Lets the caller upgrade FLESH → FLESH_LETHAL on
// killing blows and headshots so the lethal blood-splash variant fires.
void(vector pos, vector normal, float mat) W_ImpactEffectAllMat =
{
    if (pointcontents(pos + normal * -2) == CONTENT_SKY)
        return;

    // Skip the shooter — their CSQC_PredictFireWeapon path already ran
    // CSQC_BulletImpact which plays the ric sound at the impact point.
    // Without this skip the attacker hears a ping-delayed echo.
    entity p = player_chain_head;
    while (p)
    {
        if (p != self)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_IMPACT);
            WriteCoord(MSG_ONE, pos_x);
            WriteCoord(MSG_ONE, pos_y);
            WriteCoord(MSG_ONE, pos_z);
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_x * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_y * 127), 255));
            WriteByte(MSG_ONE, bound(0, rint(127 + normal_z * 127), 255));
            WriteByte(MSG_ONE, mat);
            WriteShort(MSG_ONE, num_for_edict(trace_ent));   // target entnum for decal attach
        }
        p = p.player_chain_next;
    }
};

// Send a positioned sound via multicast. Respects dimension_send,
// unlike sound() which bypasses dimension masking.
void(vector pos, string snd) W_MulticastSound =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_POINTSOUND);
    WriteCoord(MSG_MULTICAST, pos_x);
    WriteCoord(MSG_MULTICAST, pos_y);
    WriteCoord(MSG_MULTICAST, pos_z);
    WriteString(MSG_MULTICAST, snd);
    multicast(pos, MULTICAST_PHS);
};

// Send shell casing eject to all players in PVS.
// The shooter's client deduplicates against its own predicted casing.
void(float shell_type, vector origin_offset, vector base_vel, vector base_avel) W_ShellEffect =
{

    // Global shell adjustments: push forward, raise, adjust ejection velocity
    origin_offset_x += 4;
    origin_offset_z += 1;
    base_vel_y += 20;
    base_vel_z += 10;

    makevectors(self.v_angle);

    vector org = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);

    vector vel = self.velocity
        + (v_forward * base_vel_x)
        + (v_right * base_vel_y)
        + (v_up * base_vel_z);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_SHELL);
            WriteByte(MSG_ONE, shell_type);
            WriteCoord(MSG_ONE, org_x);
            WriteCoord(MSG_ONE, org_y);
            WriteCoord(MSG_ONE, org_z);
            WriteCoord(MSG_ONE, vel_x);
            WriteCoord(MSG_ONE, vel_y);
            WriteCoord(MSG_ONE, vel_z);
            WriteCoord(MSG_ONE, base_avel_x);
            WriteCoord(MSG_ONE, base_avel_y);
            WriteCoord(MSG_ONE, base_avel_z);
        }
        p = p.player_chain_next;
    }
};

// Send magazine drop to all players in PVS.
// The shooter's client deduplicates against its own predicted mag.
void(float mag_type, vector origin_offset, vector base_vel) W_MagDropEffect =
{
    // Lower mag drop origin on player
    origin_offset_z -= 4;

    makevectors(self.v_angle);

    vector org = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);

    vector vel = self.velocity
        + (v_forward * base_vel_x)
        + (v_right * base_vel_y)
        + (v_up * base_vel_z);

    entity p = player_chain_head;
    while (p)
    {
        if (p != self)
        {
            msg_entity = p;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_MAGDROP);
            WriteByte(MSG_ONE, mag_type);
            WriteCoord(MSG_ONE, org_x);
            WriteCoord(MSG_ONE, org_y);
            WriteCoord(MSG_ONE, org_z);
            WriteCoord(MSG_ONE, vel_x);
            WriteCoord(MSG_ONE, vel_y);
            WriteCoord(MSG_ONE, vel_z);
        }
        p = p.player_chain_next;
    }
};

void() PlayerModelPlayPrimaryAttack =
{
    // placeholder: trigger player model attack animation here
};

// ============================================================
//  Damage helpers  (referenced by NewQuake/weapons/damage.qc)
// ============================================================

float(entity target) W_CanDamageTarget =
{
    if (target == world)
        return FALSE;
    if (target.health <= 0)
        return FALSE;
    if (target.classname == "player")
        return TRUE;
    if (target.takedamage != DAMAGE_YES)
        return FALSE;
    return TRUE;
};

void(float attacker_slot, float victim_slot, float cause, float weapon, float headshot) SV_SendKillFeed =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_KILLFEED);
    WriteByte(MSG_MULTICAST, attacker_slot);
    WriteByte(MSG_MULTICAST, victim_slot);
    WriteByte(MSG_MULTICAST, cause);
    WriteByte(MSG_MULTICAST, weapon);
    WriteByte(MSG_MULTICAST, headshot);
    multicast('0 0 0', MULTICAST_ALL);
};

void(entity attacker, entity victim) PlayerKilled =
{
    victim.deaths = victim.deaths + 1;

    // Kill-feed broadcast — attacker may be non-player (world / env_hurt)
    // which we surface as KILLFEED_NO_ATTACKER.  Headshot flag is latched
    // on the victim by W_BoneToHitgroup during the killing hitscan.
    float kf_cause;
    float kf_atk_slot = (attacker.classname == "player")
        ? num_for_edict(attacker) - 1
        : KILLFEED_NO_ATTACKER;
    float kf_vic_slot = num_for_edict(victim) - 1;
    if (attacker == victim || attacker.classname != "player")
        kf_cause = KILL_CAUSE_SUICIDE;
    else if (!Gamemode_HasUnifiedTeams()
             && attacker.player_team != TEAM_NONE
             && attacker.player_team == victim.player_team)
        kf_cause = KILL_CAUSE_FRIENDLYFIRE;
    else
        kf_cause = KILL_CAUSE_WEAPON;
    SV_SendKillFeed(kf_atk_slot, kf_vic_slot, kf_cause, attacker.weapon,
                    (victim.death_hitgroup == HITGROUP_HEAD) ? 1 : 0);

    if (attacker.classname == "player")
    {
        if (attacker == victim)
            attacker.frags = attacker.frags - 1;
        else
            attacker.frags = attacker.frags + 1;

        PlayerRefreshScoreboardInfo(attacker);
        logfrag(attacker, victim);
    }

    // Deferred death — body stays visible for death cam, respawn/spectate
    // handled in StartFrame after mp_respawndelay expires.
    victim.is_dead = TRUE;
    // Refresh AFTER is_dead so the scoreboard sees the new dead state.
    PlayerRefreshScoreboardInfo(victim);
    victim.death_time = time;
    victim.solid = SOLID_NOT;
    victim.health = 0;
    victim.velocity = '0 0 0';

    // Play death animation + scatter carried weapons, all with self = victim
    {
        entity saved;
        saved = self;
        self = victim;
        SH_PlayerAnim_Death();
        W_DropAllWeaponsOnDeath();
        self = saved;
    }

    // Strip weapons so dead player can't switch
    victim.weapon = WEP_NONE;
    victim.weaponmodel = "";
    victim.weaponframe = 0;

    // Stop any looping weapon sounds (e.g. gauss charge)
    sound(victim, CHAN_WEAPON, "sounds/null.wav", 1, ATTN_NORM);
    victim.weaponstate = WS_IDLE;

    // Detach the visual proxy as a corpse — the body persists on the
    // ground for the rest of the round (cleaned up by RoundRestart's
    // corpse sweep). Works in both TDM (PlayerSpawn's Ensure spawns a
    // fresh proxy at the respawn point) and Elimination (PlayerJoinSpectate
    // sees player_visual_proxy == world and skips its remove).
    Player_VisualProxy_DetachAsCorpse(victim);
};

// ============================================================
//  Damage report (cl_playerdamage death-screen panel)
//
//  32×32 sparse matrix of (attacker, target) damage totals + hit
//  counts, accumulated per-life. On death we walk the victim's row
//  (Given) and column (Taken) and ship the result as a single
//  CSQC_EVENT_DAMAGE_REPORT to the dying player only. Cleared
//  per-player on PlayerSpawn so each life starts fresh.
//
//  Index = attacker_slot0 * 32 + target_slot0  (slot0 = 0..31).
// ============================================================
const float DR_MAX_PLAYERS = 32;
const float DR_REPORT_CAP  = 16;   // entries per side on the wire

float dr_dmg [DR_MAX_PLAYERS * DR_MAX_PLAYERS];
float dr_hits[DR_MAX_PLAYERS * DR_MAX_PLAYERS];

void(float slot0) DamageReport_ClearForPlayer =
{
    if (slot0 < 0 || slot0 >= DR_MAX_PLAYERS) return;
    float i;
    for (i = 0; i < DR_MAX_PLAYERS; i = i + 1)
    {
        // row: damage this player dealt to others
        dr_dmg [slot0 * DR_MAX_PLAYERS + i] = 0;
        dr_hits[slot0 * DR_MAX_PLAYERS + i] = 0;
        // column: damage this player received from others
        dr_dmg [i * DR_MAX_PLAYERS + slot0] = 0;
        dr_hits[i * DR_MAX_PLAYERS + slot0] = 0;
    }
};

void(entity attacker, entity target, float damage) DamageReport_Record =
{
    if (!attacker || !target) return;
    if (attacker == target) return;
    if (attacker.classname != "player") return;
    if (target.classname   != "player") return;

    float a = num_for_edict(attacker) - 1;
    float t = num_for_edict(target)   - 1;
    if (a < 0 || a >= DR_MAX_PLAYERS) return;
    if (t < 0 || t >= DR_MAX_PLAYERS) return;

    float idx = a * DR_MAX_PLAYERS + t;
    dr_dmg [idx] = dr_dmg [idx] + damage;
    dr_hits[idx] = dr_hits[idx] + 1;
};

// Walk the victim's row (Given) and column (Taken) and ship the
// report as a single CSQC event to the victim.
void(entity victim) DamageReport_Send =
{
    if (!victim || victim.classname != "player") return;
    float v = num_for_edict(victim) - 1;
    if (v < 0 || v >= DR_MAX_PLAYERS) return;

    msg_entity = victim;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_REPORT);

    // ---- Given list (victim damaged whom) ----
    float given_count = 0;
    float i;
    for (i = 0; i < DR_MAX_PLAYERS; i = i + 1)
    {
        if (dr_dmg[v * DR_MAX_PLAYERS + i] > 0)
            given_count = given_count + 1;
    }
    if (given_count > DR_REPORT_CAP) given_count = DR_REPORT_CAP;
    WriteByte(MSG_ONE, given_count);

    float written = 0;
    for (i = 0; i < DR_MAX_PLAYERS && written < given_count; i = i + 1)
    {
        float idx = v * DR_MAX_PLAYERS + i;
        if (dr_dmg[idx] <= 0) continue;
        entity tgt = edict_num(i + 1);
        float hp   = (tgt && tgt.classname == "player") ? tgt.health : 0;
        WriteByte (MSG_ONE, i + 1);                                // 1-based slot
        WriteShort(MSG_ONE, bound(0, rint(dr_dmg[idx]), 32767));
        WriteByte (MSG_ONE, bound(0, dr_hits[idx], 255));
        WriteByte (MSG_ONE, bound(0, rint(hp), 255));
        written = written + 1;
    }

    // ---- Taken list (who damaged victim) ----
    float taken_count = 0;
    for (i = 0; i < DR_MAX_PLAYERS; i = i + 1)
    {
        if (dr_dmg[i * DR_MAX_PLAYERS + v] > 0)
            taken_count = taken_count + 1;
    }
    if (taken_count > DR_REPORT_CAP) taken_count = DR_REPORT_CAP;
    WriteByte(MSG_ONE, taken_count);

    written = 0;
    for (i = 0; i < DR_MAX_PLAYERS && written < taken_count; i = i + 1)
    {
        float idx = i * DR_MAX_PLAYERS + v;
        if (dr_dmg[idx] <= 0) continue;
        entity atk = edict_num(i + 1);
        float hp   = (atk && atk.classname == "player") ? atk.health : 0;
        WriteByte (MSG_ONE, i + 1);
        WriteShort(MSG_ONE, bound(0, rint(dr_dmg[idx]), 32767));
        WriteByte (MSG_ONE, bound(0, dr_hits[idx], 255));
        WriteByte (MSG_ONE, bound(0, rint(hp), 255));
        written = written + 1;
    }
};

float(entity attacker, entity target, float damage) W_ApplyDamage =
{
    entity saved;
    entity old_activator;

    if (!W_CanDamageTarget(target))
        return 0;

    // Friendlyfire check: block teammate damage if disabled.
    // Unified-team modes (FFA + Bhop) bypass entirely — every player
    // is fair game regardless of the backend team value (which exists
    // only so admin-switching back to a team mode lands players on a
    // valid team).
    if (!Gamemode_HasUnifiedTeams()
        && attacker.classname == "player" && target.classname == "player"
        && attacker != target
        && attacker.player_team == target.player_team
        && attacker.player_team != TEAM_NONE
        && !cvar("mp_friendlyfire"))
        return 0;

    if (damage > target.health)
        damage = target.health;

    target.health       = target.health - damage;
    target.dmg_inflictor = attacker;

    // Damage report — record (attacker, target, damage) for the
    // death-screen "Given/Taken" panel. Skips self-damage and
    // non-player attackers (world / fall damage) inside the helper.
    DamageReport_Record(attacker, target, damage);

    // Dedup anchor for sv_trust_clienthits — the hitclaim handler checks
    // these fields to avoid double-damaging the same target when both
    // server-auth and client-claim hit land in the same shot.
    if (attacker)
    {
        attacker.last_damaged_target = target;
        attacker.last_damaged_time   = time;
    }

    // Send pain flash only to the victim
    if (target.classname == "player")
    {
        msg_entity = target;
        WriteByte(MSG_ONE, SVC_CGAMEPACKET);
        WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_FLASH);
        WriteByte(MSG_ONE, bound(1, damage, 255));
    }

    // Hitmarker: server-confirmed hit on any damageable.
    // When sv_trust_clienthits >= 1 AND target is a player, the
    // attacker's CSQC already played the marker locally on the
    // predicted hit (sh_weapon_logic.qc), so suppress the server-side
    // emit to avoid the marker firing twice — once on the predicted
    // trace, again when the server's confirmation packet round-trips
    // back ~ping ms later.  Breakable / phys-prop / world hits keep
    // firing the server marker because the client doesn't predict
    // hitmarkers for non-player targets.
    if (attacker.classname == "player")
    {
        float trust = cvar("sv_trust_clienthits");
        float client_owns_marker = (target.classname == "player" && trust >= 1);
        if (!client_owns_marker)
        {
            msg_entity = attacker;
            WriteByte(MSG_ONE, SVC_CGAMEPACKET);
            WriteByte(MSG_ONE, CSQC_EVENT_HITMARKER);
        }
    }

    if (target.health <= 0 && target.classname == "player")
    {
        // Headshot kill → broadcast CSQC_EVENT_PLAYER_GIBS so every client
        // spawns flesh chunks + blood ("the head explodes").  Trigger is
        // hitgroup-based, not damage-based: any lethal headshot gibs,
        // regardless of weapon power.  Body-shot kills, even with high
        // damage, do not gib — they play the standard death animation.
        // death_hitgroup is set by every damage source before this
        // function is called (hitscan paths, hitclaim handler, shotgun
        // pellet paths) so the hitgroup of the actual killing blow is
        // available here.
        if (target.death_hitgroup == HITGROUP_HEAD && attacker)
        {
            vector gib_dir = target.origin - attacker.origin;
            if (vlen(gib_dir) > 0)
                gib_dir = normalize(gib_dir);
            else
                gib_dir = '0 0 1';

            // Gib count scales with damage so a tiny pistol headshot gibs
            // less dramatically than an AWP headshot. 4 minimum, 12 cap.
            float gib_count = bound(4, 4 + damage / 25, 12);

            WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
            WriteByte(MSG_MULTICAST, CSQC_EVENT_PLAYER_GIBS);
            WriteCoord(MSG_MULTICAST, target.origin_x);
            WriteCoord(MSG_MULTICAST, target.origin_y);
            WriteCoord(MSG_MULTICAST, target.origin_z + 24);  // center of mass
            WriteCoord(MSG_MULTICAST, gib_dir_x);
            WriteCoord(MSG_MULTICAST, gib_dir_y);
            WriteCoord(MSG_MULTICAST, gib_dir_z);
            WriteByte(MSG_MULTICAST, gib_count);
            WriteShort(MSG_MULTICAST, bound(0, damage, 32767));
            // Victim slot — lets the attacker's CSQC suppress this gib
            // spawn when cl_predict_death already fired for that proxy
            // (vis_pred_gibs_at_time within the staleness window).
            // Without this, the predicted gibs and the server's authoritative
            // gibs visibly double up at high ping.
            WriteByte(MSG_MULTICAST, num_for_edict(target));
            multicast(target.origin, MULTICAST_PVS);

            // Suppress the corpse visual — the player exploded, there's no body.
            target.modelindex = 0;
            if (target.player_visual_proxy)
                target.player_visual_proxy.modelindex = 0;
        }

        PlayerKilled(attacker, target);

        // Death-screen damage report — send to the dying player
        // before their slot resets on respawn. Sent via MSG_ONE
        // (victim only). cl_playerdamage gates client display.
        DamageReport_Send(target);

        return damage;
    }

    // Non-player entity killed: fire its .use function so buttons/triggers activate.
    // Set activator = attacker so the target chain knows who pulled the trigger.
    if (target.health <= 0 && target.use)
    {
        saved         = self;
        old_activator = activator;
        self          = target;
        activator     = attacker;
        self.use();
        self          = saved;
        activator     = old_activator;
        return damage;
    }

    if (target.health > 0 && target.on_damaged)
    {
        saved = self;
        self  = target;
        self.on_damaged();
        self  = saved;
    }

    if (target.health <= 0 && target.on_killed)
    {
        saved = self;
        self  = target;
        self.on_killed();
        self  = saved;
    }

    return damage;
};

// ============================================================
//  Weapon become solid  -  deferred think on dropped weapons
//  Prevents the dropper from immediately re-picking up the weapon.
// ============================================================

// Dropped-weapon CSQC replication — body lives in server/sv_player.qc
// so it can reference the per-weapon mag_*/ammo_* fields (declared in
// the sh_wpn_*.qc files, which compile AFTER this file). Forward
// declaration is at the top of this file near weapon_become_solid.

// Shared in-flight send interval for dropped weapons + projectiles.
// Reads sv_toss_tickrate (Hz, default 20, clamped 5..100) and returns
// the seconds-per-tick value used as nextthink offsets. Centralised so
// admins tune one cvar to control every airborne entity's send rate.
float() Toss_NextThinkInterval =
{
    return 1.0 / bound(5, cvar("sv_toss_tickrate"), 100);
};

// Shared CSQC SendEntity for every server-spawned projectile (HL grenade,
// GL grenade, RPG rocket, crossbow bolt). Returning FALSE for the shooter
// hides the entity from them — they see only their CSQC-predicted fake.
// Other PVS clients receive origin + velocity + avelocity; the CSQC
// parser (cl_projectiles.qc) routes through cl_tosssmooth.qc for extrap +
// smooth, so visible flight stays smooth between server samples.
//
// Model + gravity factor are derived from proj_type via
// Projectile_TypeModel / Projectile_TypeGravity (shared/sh_weapons.qc),
// so we don't burn bytes on the wire for either.
float(entity playerent, float changedflags) projectile_SendEntity =
{
    if (playerent == self.owner)
        return FALSE;

    WriteByte(MSG_ENTITY, CSQC_ENT_PROJECTILE);
    WriteByte(MSG_ENTITY, self.proj_type);
    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);
    WriteCoord(MSG_ENTITY, self.velocity_x);
    WriteCoord(MSG_ENTITY, self.velocity_y);
    WriteCoord(MSG_ENTITY, self.velocity_z);
    WriteCoord(MSG_ENTITY, self.avelocity_x);
    WriteCoord(MSG_ENTITY, self.avelocity_y);
    WriteCoord(MSG_ENTITY, self.avelocity_z);
    return TRUE;
};

void() weapon_become_solid =
{
    // Bump SendFlags on every call regardless of phase.  During the toss
    // phase this drives the CSQC position update — rate is sv_toss_tickrate
    // (default 40 Hz) so observers see smooth physics instead of the
    // weapon freezing until weapon_settle_think starts pulsing.
    self.SendFlags |= 1;

    if (time < self.weapon_solid_time)
    {
        // Toss phase — poll at sv_toss_tickrate so CSQC gets a fresh
        // origin + velocity as the TOSS physics carries the drop through
        // the air. Faster send rate → less per-snapshot snap to absorb in
        // the CSQC smoothing layer.
        self.nextthink = time + Toss_NextThinkInterval();
        return;
    }

    // +0.7 s crossed: finalise the transition.  Flip solid so the
    // dropper (and everyone else) can now touch for pickup, unhide
    // from the dropper, and hand off to weapon_settle_think which
    // will watch for motion to stop and then align to the floor.
    self.solid = SOLID_TRIGGER;
    self.nodrawtoclient = world;
    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = dropped_weapon_SendEntity;  // idempotent; safe re-assert

    // 3 s deadline (was 10 s). Most weapons settle below the 30 qu/s
    // threshold within a second of landing; the rest used to ride out
    // a 10 s deadline rolling on slight inclines, leaving them visibly
    // "alive" long after they should have stopped. weapon_settle_think
    // also damps residual motion below 100 qu/s to encourage faster
    // convergence within this window.
    self.weapon_settle_deadline = time + 3;
    self.think = weapon_settle_think;
    self.nextthink = time + Toss_NextThinkInterval();
};

// Polled every 0.2s once the weapon is solid.  Waits until motion drops
// below a threshold (or the 10s deadline hits), then traces down for the
// floor normal and aligns the model flat on the surface.  No further
// think is scheduled afterward — the pickup remains a static trigger.
void() weapon_settle_think =
{
    vector flat_vel;
    vector floor_normal;
    float yaw;

    // Push a fresh CSQC snapshot on every poll tick so the client's
    // dropped-weapon entity tracks the server's falling/bouncing
    // origin. Without this the CSQC copy would freeze at whatever
    // position existed when SendEntity was first set (mid-toss for
    // player drops, spawn-placed origin for map weapons).
    self.SendFlags |= 1;

    flat_vel = self.velocity;
    flat_vel_z = 0;
    if ((fabs(self.velocity_z) > 30 || vlen(flat_vel) > 30)
        && time < self.weapon_settle_deadline)
    {
        // Strong damping once motion is moderate — encourages a fast
        // final settle so the weapon doesn't ride out the 3 s deadline
        // rolling/sliding at low speed. Skipped while still actively
        // bouncing (|vel| > 200) so the natural arc isn't squashed.
        if (vlen(self.velocity) < 200)
        {
            self.velocity  = self.velocity  * 0.65;
            self.avelocity = self.avelocity * 0.65;
        }

        // Still moving — keep ticking at sv_toss_tickrate so the CSQC
        // smoothing layer always has fresh samples to extrapolate from.
        self.nextthink = time + Toss_NextThinkInterval();
        return;
    }

    // Trace down for the floor normal — fall back to flat if we're in the
    // air (mid-bounce at deadline) so we still get a sane orientation.
    floor_normal = '0 0 1';
    traceline(self.origin, self.origin - '0 0 32', TRUE, self);
    if (trace_fraction < 1)
        floor_normal = trace_plane_normal;

    yaw = self.angles_y;
    if (floor_normal_z > 0.99)
    {
        self.angles = [0, yaw, 0];
    }
    else
    {
        // Sloped surface — pitch/roll to match using the same math as
        // CSQC_ShellSettle in cl_shells.qc.
        vector fwd, rt;
        makevectors([0, yaw, 0]);
        fwd = v_forward;
        rt = v_right;
        self.angles_x = -asin(floor_normal * fwd) * (180.0 / M_PI);
        self.angles_z = asin(floor_normal * rt) * (180.0 / M_PI);
        self.angles_y = yaw;
    }

    self.movetype = MOVETYPE_NONE;
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.think = __NULL__;
    self.nextthink = 0;
};


// ============================================================
//  Weapon touch  -  called when a player walks over a pickup
// ============================================================

void() weapon_touch =
{
    entity player = other;
    entity pickup = self;
    entity saved;
    float  slot;

    if (player.classname != "player")
        return;

    // Team-select players cycle through map cameras with PM_MOVETYPE_NONE
    // and no team yet.  They shouldn't pick up anything — otherwise the
    // camera player silently grabs weapons near the camera points (e.g.
    // the Scout on bloodassault spawns within touch range of a team-
    // select camera).
    if (player.player_team == TEAM_NONE || player.is_dead)
        return;

    slot = pickup.weapon_slot;

    // Reject if player already has a weapon in this slot — must drop first
    if (slot == SLOT_PRIMARY   && player.slot_primary)   return;
    if (slot == SLOT_SECONDARY && player.slot_secondary) return;
    if (slot == SLOT_MELEE     && player.slot_melee)     return;
    if (slot == SLOT_UTILITY   && player.slot_utility)   return;

    // Copy ammo from world entity to player (self = pickup for pickupcopy)
    saved = self;
    self = pickup;
    if (self.pickupcopy)
        self.pickupcopy(player);
    self = saved;

    // Register weapon in the correct player slot
    if (slot == SLOT_PRIMARY)
    {
        player.slot_primary       = pickup.weapon;
        player.slot_primary_equip = pickup.weap_draw;
        player.slot_primary_drop  = pickup.weap_drop_func;
    }
    else if (slot == SLOT_SECONDARY)
    {
        player.slot_secondary       = pickup.weapon;
        player.slot_secondary_equip = pickup.weap_draw;
        player.slot_secondary_drop  = pickup.weap_drop_func;
    }
    else if (slot == SLOT_MELEE)
    {
        player.slot_melee       = pickup.weapon;
        player.slot_melee_equip = pickup.weap_draw;
        player.slot_melee_drop  = pickup.weap_drop_func;
    }
    else if (slot == SLOT_UTILITY)
    {
        player.slot_utility       = pickup.weapon;
        player.slot_utility_equip = pickup.weap_draw;
        player.slot_utility_drop  = pickup.weap_drop_func;
    }

    // Auto-equip if this is a better weapon than what we're holding.
    // Primary > Secondary > Melee.
    {
        float should_equip = FALSE;

        if (player.weapon == WEP_NONE)
            should_equip = TRUE;
        else if (slot == SLOT_PRIMARY)
            should_equip = TRUE;   // primary is always best
        else if (slot == SLOT_SECONDARY && !player.slot_primary)
            should_equip = TRUE;   // secondary is best if no primary

        if (should_equip)
        {
            saved = self;
            self  = player;
            W_SelectWeapon(pickup.weapon);
            self = saved;
        }
    }

    // Route the pickup confirm sound through a CSQC multicast event
    // so the pickup-er's client can skip it (they already played the
    // sound locally via CSQC_PredictPickupWeapon). Without this skip,
    // 0-ping listen servers produce an audible echo — standard Quake
    // `sound()` has no exclude-client mode.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_WEAPON_PICKUP_SOUND);
    WriteByte(MSG_MULTICAST, num_for_edict(player));
    WriteCoord(MSG_MULTICAST, player.origin_x);
    WriteCoord(MSG_MULTICAST, player.origin_y);
    WriteCoord(MSG_MULTICAST, player.origin_z);
    multicast(player.origin, MULTICAST_PVS);

    // Sync proxy immediately so the client receives correct ammo values
    PM_SyncPredictionProxy(player);

    // Map weapons are hidden instead of removed so they can respawn on round reset
    if (pickup.map_weapon)
    {
        pickup.solid = SOLID_NOT;
        pickup.movetype = MOVETYPE_NONE;
        setmodel(pickup, "");
        pickup.touch = __NULL__;
        // Force a SendEntity re-fire so the CSQC copy receives the
        // empty model and hides locally. Without this, FTE's delta
        // compression sometimes skips the resend after setmodel(""),
        // leaving a ghost pickup on the client (visible, can be
        // walked over again, but slot-occupied so no re-pickup).
        pickup.SendFlags |= 1;
    }
    else
    {
        remove(pickup);
    }
};

// ============================================================
//  Weapon bindings management
// ============================================================

void() W_ClearWeaponBindings =
{
    self.weaponmodel    = "";
    self.weaponframe    = 0;
    self.weaponstate    = WS_IDLE;
    self.wep_nextframe  = 0;
    self.wep_anim_start = 0;
    self.attack_finished = 0;
    self.fire           = __NULL__;
    self.reload         = __NULL__;
    self.wepframe       = __NULL__;
    W_ClearZoom();
};

// Equip the weapon that matches self.weapon, using the supplied function.
void(float slot_weapon, void() slot_equip) W_TryEquipSlot =
{
    if (self.weapon != slot_weapon || !slot_equip)
        return;
    W_ClearWeaponBindings();
    slot_equip();   // sets weaponmodel, fire, reload, wepframe, initial frame/state
};

void() W_ChangeWeapon =
{
    W_TryEquipSlot(self.slot_primary,   self.slot_primary_equip);
    W_TryEquipSlot(self.slot_secondary, self.slot_secondary_equip);
    W_TryEquipSlot(self.slot_melee,     self.slot_melee_equip);
    W_TryEquipSlot(self.slot_utility,   self.slot_utility_equip);
};

void(float new_weapon) W_SelectWeapon =
{
    float cur = self.weapon;

    if (new_weapon == WEP_NONE || new_weapon == cur)
        return;

    if (self.slot_primary   != new_weapon &&
        self.slot_secondary != new_weapon &&
        self.slot_melee     != new_weapon &&
        self.slot_utility   != new_weapon)
        return;

    if (cur != WEP_NONE)
        self.previous_weapon = cur;

    if (cvar("sv_debug_wepswap"))
    {
        dprint(sprintf("[SV wepswap] frame=%g  %g→%g  origin=%v  velocity=%v  speed=%.1f\n",
            time, cur, new_weapon, self.origin, self.velocity, vlen(self.velocity)));
        Drift_Dump("SV");
    }

    // Snapshot current effective speed factor before the weapon change,
    // then reset blend progress to 0 — PM_ReadMovevars advances it per
    // pmove tick.  Mirrors CSQC_PredictSelectWeapon.
    self.pm_weapon_prev_factor    = Weapon_SpeedFactor_Smooth();
    self.pm_weapon_blend_progress = 0;

    self.weapon = new_weapon;
    W_ChangeWeapon();
};

// ============================================================
//  Weapon cycling
// ============================================================

void() W_SelectNextWeapon =
{
    if (self.weapon == self.slot_primary)
    {
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.weapon == self.slot_utility)
    {
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        return;
    }
    // No weapon equipped - pick first available
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
};

void() W_SelectPrevWeapon =
{
    if (self.weapon == self.slot_primary)
    {
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        return;
    }
    if (self.weapon == self.slot_secondary)
    {
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        return;
    }
    if (self.weapon == self.slot_melee)
    {
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
        return;
    }
    if (self.weapon == self.slot_utility)
    {
        if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
        if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
        if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
        return;
    }
    // No weapon - pick last available
    if (self.slot_utility)   { W_SelectWeapon(self.slot_utility);   return; }
    if (self.slot_melee)     { W_SelectWeapon(self.slot_melee);     return; }
    if (self.slot_secondary) { W_SelectWeapon(self.slot_secondary); return; }
    if (self.slot_primary)   { W_SelectWeapon(self.slot_primary);   return; }
};

void() W_SelectLastWeapon =
{
    if (self.previous_weapon == WEP_NONE)
        return;
    if (self.previous_weapon == self.weapon)
        return;

    // Make sure we still have the previous weapon
    if (self.slot_primary   != self.previous_weapon &&
        self.slot_secondary != self.previous_weapon &&
        self.slot_melee     != self.previous_weapon &&
        self.slot_utility   != self.previous_weapon)
        return;

    W_SelectWeapon(self.previous_weapon);
};

// ============================================================
//  Drop current weapon
// ============================================================

void() W_DropCurrentWeapon =
{
    void() drop_func;
    entity drop_ent;
    float  cur;

    cur = self.weapon;
    if (cur == WEP_NONE)
        return;

    drop_func = __NULL__;
    if (cur == self.slot_primary   && self.slot_primary_drop)   drop_func = self.slot_primary_drop;
    if (cur == self.slot_secondary && self.slot_secondary_drop) drop_func = self.slot_secondary_drop;
    if (cur == self.slot_melee     && self.slot_melee_drop)     drop_func = self.slot_melee_drop;
    if (cur == self.slot_utility   && self.slot_utility_drop)   drop_func = self.slot_utility_drop;

    if (!drop_func)
        return;

    // Spawn the world entity, toss it forward from view
    drop_ent = spawn();
    makevectors(self.v_angle);
    setorigin(drop_ent, self.origin + self.view_ofs + v_forward * 24);
    drop_ent.velocity = self.velocity + v_forward * 200 + '0 0 80';

    weapon_drop_target = drop_ent;
    drop_func();          // populates drop_ent (ammo, model, solid, touch, etc.)
    weapon_drop_target = world;

    // Wire CSQC replication IMMEDIATELY rather than waiting for
    // weapon_become_solid at +0.7s.  If we let the engine do
    // standard replication during the toss phase and then bolt
    // SendEntity on at +0.7s, observers see BOTH the engine-side
    // flying entity AND the new CSQC entity simultaneously — the
    // "double drop" bug.  Map weapons avoid this by wiring
    // SendEntity at spawn (W_RegisterMapWeapon); death drops do
    // the same in W_DropAllWeaponsOnDeath; this matches.
    // weapon_become_solid at +0.7s still fires to flip solidity
    // (the re-wiring of SendEntity it does is idempotent).
    drop_ent.pvsflags = PVSF_NOREMOVE;
    drop_ent.SendEntity = dropped_weapon_SendEntity;
    drop_ent.SendFlags = 1;

    // Hide from dropper — their client-side fake drop covers the visual.
    // weapon_become_solid fires at +0.7s; we unhide at +1.5s after that.
    drop_ent.nodrawtoclient = self;

    // Override the drop_func's think schedule so weapon_become_solid
    // runs at 20 Hz from spawn.  Its dual-phase logic bumps SendFlags
    // each call so CSQC observers see the toss animate smoothly, then
    // at +0.7 s it finalises solidity and hands off to
    // weapon_settle_think (also at 20 Hz).  Stores the solidify
    // threshold separately so the function can tell which phase
    // it's in without relying on tick counting.
    drop_ent.weapon_solid_time = time + 0.7;
    drop_ent.think = weapon_become_solid;   // idempotent
    drop_ent.nextthink = time + 0.05;

    // Clear the vacated slot
    if (cur == self.slot_primary)
    {
        self.slot_primary       = WEP_NONE;
        self.slot_primary_equip = __NULL__;
        self.slot_primary_drop  = __NULL__;
    }
    else if (cur == self.slot_secondary)
    {
        self.slot_secondary       = WEP_NONE;
        self.slot_secondary_equip = __NULL__;
        self.slot_secondary_drop  = __NULL__;
    }
    else if (cur == self.slot_melee)
    {
        self.slot_melee       = WEP_NONE;
        self.slot_melee_equip = __NULL__;
        self.slot_melee_drop  = __NULL__;
    }
    else if (cur == self.slot_utility)
    {
        self.slot_utility       = WEP_NONE;
        self.slot_utility_equip = __NULL__;
        self.slot_utility_drop  = __NULL__;
    }

    self.weapon = WEP_NONE;
    W_ClearWeaponBindings();
    W_SelectNextWeapon();
};

// ============================================================
//  Drop every inventory slot in random directions (on death)
// ============================================================
void() W_DropAllWeaponsOnDeath =
{
    float slot_idx;
    void() drop_func;
    float slot_wep;
    entity drop_ent;
    float yaw, pitch;

    for (slot_idx = 0; slot_idx < 4; slot_idx++)
    {
        drop_func = __NULL__;
        slot_wep = 0;
        if (slot_idx == 0)      { slot_wep = self.slot_primary;   drop_func = self.slot_primary_drop; }
        else if (slot_idx == 1) { slot_wep = self.slot_secondary; drop_func = self.slot_secondary_drop; }
        else if (slot_idx == 2) { slot_wep = self.slot_melee;     drop_func = self.slot_melee_drop; }
        else if (slot_idx == 3) { slot_wep = self.slot_utility;   drop_func = self.slot_utility_drop; }

        if (!slot_wep || !drop_func)
            continue;

        drop_ent = spawn();

        yaw   = random() * 360;
        pitch = -40 + random() * 20;   // upward-ish toss
        makevectors([pitch, yaw, 0]);

        setorigin(drop_ent, self.origin + self.view_ofs * 0.5 + v_forward * 8);
        drop_ent.velocity = self.velocity + v_forward * (150 + random() * 150) + [0, 0, 100 + random() * 120];
        drop_ent.avelocity = [random() * 600 - 300, random() * 600 - 300, random() * 600 - 300];

        weapon_drop_target = drop_ent;
        drop_func();
        weapon_drop_target = world;

        // Wire CSQC replication IMMEDIATELY rather than waiting for
        // weapon_become_solid at +0.7s.  If we let the engine do
        // standard replication during the toss phase and then bolt
        // SendEntity on at +0.7s, observers see BOTH the engine-side
        // flying entity AND the new CSQC entity simultaneously — the
        // "double drop" bug.  Map weapons avoid this by wiring
        // SendEntity at spawn (W_RegisterMapWeapon); we do the same
        // here so death drops never have an engine-standard phase.
        // weapon_become_solid at +0.7s still fires to flip solidity
        // (the re-wiring of SendEntity it does is idempotent).
        drop_ent.pvsflags = PVSF_NOREMOVE;
        drop_ent.SendEntity = dropped_weapon_SendEntity;
        drop_ent.SendFlags = 1;

        // Hide from dropper during the 0.7s toss phase — matches
        // W_DropCurrentWeapon.  With SendEntity already wired above,
        // nodrawtoclient still has the intended effect: it stops the
        // CSQC replication from being sent to the dropper until
        // weapon_become_solid clears it back to world at +0.7s.  The
        // dropper instead sees the CSQC fake-drop visual fired by
        // CSQC_EVENT_DEATH_DROP below.
        drop_ent.nodrawtoclient = self;

        // Override the drop_func's think schedule so weapon_become_solid
        // runs at 20 Hz from spawn — its dual-phase logic bumps
        // SendFlags each call so the CSQC-replicated toss animates
        // smoothly for observers, instead of freezing until +0.7 s.
        drop_ent.weapon_solid_time = time + 0.7;
        drop_ent.think = weapon_become_solid;  // idempotent
        drop_ent.nextthink = time + 0.05;

        // Unicast the victim a CSQC fake-drop event so they see the
        // scatter visually during the 0.7s window.  Matching the
        // server's rng origin+velocity keeps the toss arc in sync
        // with where the real pickup settles, so the fake→real
        // swap at +0.7s doesn't jump visibly.
        msg_entity = self;
        WriteByte(MSG_ONE, SVC_CGAMEPACKET);
        WriteByte(MSG_ONE, CSQC_EVENT_DEATH_DROP);
        WriteByte(MSG_ONE, slot_wep);
        WriteByte(MSG_ONE, drop_ent.weapon_slot);
        WriteCoord(MSG_ONE, drop_ent.origin_x);
        WriteCoord(MSG_ONE, drop_ent.origin_y);
        WriteCoord(MSG_ONE, drop_ent.origin_z);
        WriteCoord(MSG_ONE, drop_ent.velocity_x);
        WriteCoord(MSG_ONE, drop_ent.velocity_y);
        WriteCoord(MSG_ONE, drop_ent.velocity_z);
        WriteString(MSG_ONE, drop_ent.model);

        if (slot_idx == 0)      { self.slot_primary   = WEP_NONE; self.slot_primary_equip   = __NULL__; self.slot_primary_drop   = __NULL__; }
        else if (slot_idx == 1) { self.slot_secondary = WEP_NONE; self.slot_secondary_equip = __NULL__; self.slot_secondary_drop = __NULL__; }
        else if (slot_idx == 2) { self.slot_melee     = WEP_NONE; self.slot_melee_equip     = __NULL__; self.slot_melee_drop     = __NULL__; }
        else if (slot_idx == 3) { self.slot_utility   = WEP_NONE; self.slot_utility_equip   = __NULL__; self.slot_utility_drop   = __NULL__; }
    }
};

// ============================================================
//  Impulse dispatch  -  call from CheckImpulses in sv_player.qc
//  Handles weapon impulses only; zeros self.impulse for those it claims.
// ============================================================

void() W_CheckImpulses =
{
    if (!self.impulse)
        return;

    switch (self.impulse)
    {
    case WEAPON_IMPULSE_PRIMARY:   // Select primary slot
        if (self.slot_primary) W_SelectWeapon(self.slot_primary);
        break;
    case WEAPON_IMPULSE_SECONDARY:   // Select secondary slot
        if (self.slot_secondary) W_SelectWeapon(self.slot_secondary);
        break;
    case WEAPON_IMPULSE_MELEE:   // Select melee slot
        if (self.slot_melee) W_SelectWeapon(self.slot_melee);
        break;
    case 4:   // Utility slot
        if (self.slot_utility) W_SelectWeapon(self.slot_utility);
        break;
    case WEAPON_IMPULSE_DROP:   // Drop current weapon
        W_DropCurrentWeapon();
        break;
    case WEAPON_IMPULSE_RELOAD:   // Reload
        if (self.reload) self.reload();
        break;
    case WEAPON_IMPULSE_SPECIAL:  // Weapon-specific action (menu "Weapon Special")
        if (self.special) self.special();
        break;
    case WEAPON_IMPULSE_NEXT:  // Next weapon (bind mwheelup "impulse 12")
        W_SelectNextWeapon();
        break;
    case WEAPON_IMPULSE_PREV:  // Previous weapon (bind mwheeldown "impulse 13")
        W_SelectPrevWeapon();
        break;
    case WEAPON_IMPULSE_LASTINV:  // Last inventory (bind q "impulse 14")
        W_SelectLastWeapon();
        break;
    default:
        return;   // not a weapon impulse, leave self.impulse intact
    }
    self.impulse = 0;
};

// ============================================================
//  Per-command weapon frame  -  call from PlayerPreThink
// ============================================================

.float prev_weaponstate_anim;  // tracks weaponstate for player anim dispatch

void() W_WeaponFrame =
{
    float prev_state = self.prev_weaponstate_anim;

    // Check fire button (attack_finished debounce)
    if (self.button0 && time >= self.attack_finished)
    {
        if (self.fire)
            self.fire();
    }

    // Check alt-fire button
    if (self.button1 && time >= self.attack_finished)
    {
        if (self.altfire)
            self.altfire();
    }
    else if (!self.button1 && self.altrelease)
    {
        self.altrelease();
    }

    // Advance weapon animation on schedule
    if (self.wep_nextframe > 0 && time >= self.wep_nextframe)
    {
        if (self.wepframe)
            self.wepframe();
    }

    // Trigger player body animation on ANY entry into FIRE or RELOAD.
    // Uses wep_action_id to detect re-fires even without a state transition
    // (e.g. melees that set WS_FIRE directly without SH_StandardTryFire).
    if (self.wep_action_id != self.prev_weaponstate_anim)
    {
        float family = W_GetPlayerAnimFamily(self.weapon);
        float crouching = (self.flags & FL_DUCKING) != 0;
        float mdlidx = self.player_visual_proxy ? self.player_visual_proxy.modelindex : 0;

        if (self.weaponstate == WS_FIRE)
            SH_PlayerAnim_PlayTop(SH_GetShootAnim(mdlidx, family, crouching), 0.3);
        else if (self.weaponstate == WS_RELOAD)
            SH_PlayerAnim_PlayTop(SH_GetReloadAnim(mdlidx, family, crouching), 3.0);

        self.prev_weaponstate_anim = self.wep_action_id;
    }
};
