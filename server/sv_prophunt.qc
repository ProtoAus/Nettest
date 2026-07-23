// ============================================================================
//  PROP HUNT (GAMEMODE_PROPHUNT) — server-side mode logic
// ============================================================================
//  RED = SEEKERS, BLUE = HIDERS.  The round-freeze phase is the HIDE phase:
//  hiders run free while seekers are locked + blindfolded (the per-team gate
//  lives in SH_RoundFreezeLocksPlayer, sh_pmove.qc, mirrored by CSQC
//  prediction).  Win flow rides the standard elimination machinery in
//  sv_main.qc (all hiders dead -> RED; all seekers dead -> BLUE; round timer
//  expiry -> BLUE).
//
//  This file compiles AFTER sv_player.qc (needs PlayerApplyTeamColours /
//  PlayerRefreshScoreboardInfo) and BEFORE sv_main.qc (which calls
//  PropHunt_ShuffleTeams from RoundRestart).  Hooks that live in files
//  compiling EARLIER (sv_use.qc possession, sv_weapons.qc reload/heal,
//  sh_weapon_standard.qc missfire) reach us via forward declarations in
//  sv_customdefs.qc.
// ============================================================================

// --- Team shuffle -----------------------------------------------------------
// Called at the TOP of RoundRestart (before the respawn loop, so spawns and
// loadouts see the final teams).  Fisher-Yates over every teamed player, then
// deal ~1 seeker per (mp_ph_ratio + 1) players: 5 players -> 1v4, 10 -> 2v8.
// Assigns player_team DIRECTLY (PlayerJoinTeam would bump death counters and
// queue restarts); colours/scoreboard refreshed per player.  Self-gates on the
// gamemode so the RoundRestart call site stays unconditional.
void() PropHunt_ShuffleTeams =
{
	if (cvar("sv_gamemode") != GAMEMODE_PROPHUNT)
		return;

	entity pool[32];
	float count = 0;
	entity e = player_chain_head;
	while (e && count < 32)
	{
		if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
		{
			pool[count] = e;
			count = count + 1;
		}
		e = e.player_chain_next;
	}
	if (count < 2)
		return;	// solo warmup — leave the team alone

	float i, j;
	entity tmp;
	for (i = count - 1; i > 0; i = i - 1)
	{
		j = floor(random() * (i + 1));
		if (j > i) j = i;	// random() can return exactly 1.0
		tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp;
	}

	float ratio = cvar("mp_ph_ratio");
	if (ratio < 1) ratio = 1;
	float seekers = floor(count / (ratio + 1));
	if (seekers < 1) seekers = 1;
	if (seekers >= count) seekers = count - 1;

	for (i = 0; i < count; i = i + 1)
	{
		entity pl = pool[i];
		float want = (i < seekers) ? TEAM_RED : TEAM_BLUE;
		if (pl.player_team != want)
		{
			pl.player_team = want;
			entity saved = self;
			self = pl;
			PlayerApplyTeamColours();
			self = saved;
			PlayerRefreshScoreboardInfo(pl);
		}
	}

	bprint(PRINT_HIGH, sprintf("Prop Hunt: %g seeker%s vs %g hider%s\n",
		seekers, (seekers == 1) ? "" : "s",
		count - seekers, (count - seekers == 1) ? "" : "s"));
};

// --- Predicates -------------------------------------------------------------

float(entity pl) PropHunt_IsHider =
{
	return cvar("sv_gamemode") == GAMEMODE_PROPHUNT && pl.player_team == TEAM_BLUE;
};

// The prop_* classname whitelist (sv_props.qc spawn aliases; prop_car
// deliberately excluded — it has its own systems).
float(entity e) PropHunt_IsPropClassname =
{
	string cn = e.classname;
	if (cn == "prop_static" || cn == "prop_static_override"
	 || cn == "prop_dynamic" || cn == "prop_dynamic_override"
	 || cn == "prop_physics" || cn == "prop_physics_override"
	 || cn == "prop_physics_multiplayer" || cn == "prop_sphere"
	 || cn == "prop_ragdoll")
		return TRUE;
	return FALSE;
};

// Is this entity a prop a hider may copy?  Rejects held props and degenerate
// bboxes on top of the classname whitelist.  (prop_detail is SOLID_NOT so the
// possess trace can never select it anyway.)
float(entity e) PropHunt_IsPossessableProp =
{
	if (!e || e == world)
		return FALSE;
	if (e.modelindex == 0 || e.model == "")
		return FALSE;
	if (e.carried_by != world)
		return FALSE;	// somebody is holding it
	if (e.maxs == e.mins)
		return FALSE;	// degenerate bbox
	return PropHunt_IsPropClassname(e);
};

// --- Seeker missfire --------------------------------------------------------
// Called from INSIDE PhysProp_TryPushFromTrace (the one chokepoint every
// weapon's prop-hit branch reaches — standard hitscan, custom pellet loops,
// melee — for BOTH static and physics props).  Reflects a fraction of the
// weapon damage onto the seeker.  The time gate collapses one blast's pellets
// / one bullet's penetration chain (all land the same frame) into a single
// punish, while consecutive trigger pulls each reflect.  Returns TRUE when a
// reflect was applied.
float(entity att, entity hit, float damage) PropHunt_Missfire =
{
	if (cvar("sv_gamemode") != GAMEMODE_PROPHUNT)
		return FALSE;
	if (att.classname != "player" || att.player_team != TEAM_RED || att.is_dead)
		return FALSE;
	if (!PropHunt_IsPropClassname(hit))
		return FALSE;	// walls/breakables/weapon drops are free misses
	if (time < att.ph_missfire_gate_time)
		return FALSE;	// this blast already punished

	float dmg = damage * cvar("mp_ph_missfire_scale");
	if (dmg <= 0)
		return FALSE;

	att.ph_missfire_gate_time = time + 0.05;
	att.death_hitgroup = HITGROUP_GENERIC;
	W_ApplyDamage(att, att, dmg);	// attacker==target passes the FF gate; suicide ends via PlayerKilled
	return TRUE;
};

// --- Disguise lifecycle -----------------------------------------------------

// Zero every disguise field and restore the standing player hull/mesh.  Called
// from PlayerSpawn (covers round restarts — everyone respawns through it),
// PlayerJoinSpectate and ClientDisconnect.  Cheap no-op when undisguised.
void(entity pl) PropHunt_ClearDisguise =
{
	if (!pl.ph_disguise_modelindex && !pl.ph_hull_height && !pl.ph_maxhealth)
		return;
	pl.ph_disguise_modelindex = 0;
	pl.ph_hull_halfxy   = 0;
	pl.ph_hull_minz     = 0;
	pl.ph_hull_height   = 0;
	pl.ph_yaw_locked    = 0;
	pl.ph_locked_yaw    = 0;
	pl.ph_maxhealth     = 0;
	pl.ph_disguise_scale = 0;
	pl.ph_disguise_skin  = 0;
	// Restore the player mesh for MOVE_HITMODEL and the standing hull.
	// (PlayerSpawn re-applies its own model+hull right after; this keeps
	// mid-round exits — spectate/disconnect — sane too.)
	if (pl.player_visual_proxy != world && pl.player_visual_proxy.model != "")
		setmodel(pl, pl.player_visual_proxy.model);
	SetHitboxSize(pl, PM_MINS, PM_MAXS);
};

// Become a copy of `prop`.  Server-quantizes the hull to the wire format and
// then USES ONLY the dequantized values itself, so client prediction (fed the
// same bytes) computes a bit-identical hull.  Hull is PROP-PIVOT-RELATIVE: the
// player origin becomes the prop pivot (feet-planted shift), so the rendered
// prop, the MOVE_HITMODEL mesh and the collision hull all coincide.
void(entity pl, entity prop) PropHunt_Possess =
{
	// -- quantize (wire format: 3 bytes) --
	float halfxy = max(max(fabs(prop.mins_x), fabs(prop.maxs_x)),
	                   max(fabs(prop.mins_y), fabs(prop.maxs_y)));
	halfxy = bound(1, ceil(halfxy), 16);	// never wider than the standing hull
	float minz   = bound(-64, floor(prop.mins_z), 63);
	float height = bound(4, ceil(prop.maxs_z - prop.mins_z), 72);

	// -- HP from prop volume; health FRACTION preserved across re-possess so
	//    switching props can never heal you --
	vector psize = prop.maxs - prop.mins;
	float vol = psize_x * psize_y * psize_z;
	float new_max = bound(1, rint(vol / 1000 * cvar("mp_ph_hpscale")), cvar("mp_ph_maxhp"));
	float frac;
	if (pl.ph_maxhealth > 0)
		frac = bound(0, pl.health / pl.ph_maxhealth, 1);
	else
		frac = bound(0, pl.health / 100, 1);
	float new_hp = max(1, ceil(frac * new_max));

	// -- feet-planted origin shift + room check BEFORE mutating any state --
	vector nmins, nmaxs, norg;
	nmins_x = -halfxy;  nmins_y = -halfxy;  nmins_z = minz;
	nmaxs_x = halfxy;   nmaxs_y = halfxy;   nmaxs_z = minz + height;
	float cur_minz = (pl.ph_hull_height > 0) ? pl.ph_hull_minz : PM_MINS_z;
	norg = pl.origin;
	norg_z = (pl.origin_z + cur_minz) - minz;	// keep feet at the same world Z
	// The source prop doesn't block its own possession (you're stood beside it).
	float saved_solid = prop.solid;
	prop.solid = SOLID_NOT;
	tracebox(norg, nmins, nmaxs, norg, MOVE_NORMAL, pl);
	prop.solid = saved_solid;
	if (trace_startsolid)
	{
		sprint(pl, PRINT_HIGH, "Not enough room to become that prop here.\n");
		return;
	}

	// -- commit --
	pl.ph_disguise_modelindex = prop.modelindex;
	pl.ph_hull_halfxy    = halfxy;
	pl.ph_hull_minz      = minz;
	pl.ph_hull_height    = height;
	pl.ph_disguise_scale = (prop.scale > 0) ? prop.scale : 1;
	pl.ph_disguise_skin  = prop.skin;
	pl.ph_maxhealth      = new_max;
	pl.health            = new_hp;
	if (pl.ph_yaw_locked)
		pl.ph_locked_yaw = pl.v_angle_y;	// keep the lock, re-latch to the current view

	setorigin(pl, norg);
	// MOVE_HITMODEL mesh = the prop's model (server hitscan refines against the
	// prop, not player bones).  setmodel RESETS mins/maxs — restore the hull
	// immediately (PlayerApplyModel precedent).  The player entity itself stays
	// invisible (alpha=-1 + drawonlytoclient from PlayerSpawn).
	setmodel(pl, prop.model);
	SetHitboxSize(pl, nmins, nmaxs);

	sprint(pl, PRINT_HIGH, sprintf("Disguised! (%g HP)\n", new_hp));
};

// +use hook (SV_PlayerTryUse, sv_use.qc).  TRUE = consumed the use.
// Traces from the hider's eye and possesses a valid prop; a non-prop hit
// returns FALSE so doors/buttons still work.
float(entity pl) PropHunt_TryPossess =
{
	if (!PropHunt_IsHider(pl))
		return FALSE;
	if (pl.is_dead)
		return FALSE;
	if (round_phase != ROUND_PHASE_FREEZE && round_phase != ROUND_PHASE_ACTIVE)
		return FALSE;

	if (pl.carried_prop != world)
		Carry_Drop(pl);	// hands free first (shouldn't happen — hiders can't grab)

	makevectors(pl.v_angle);
	vector src = pl.origin + pl.view_ofs;
	traceline(src, src + v_forward * cvar("mp_ph_possess_dist"), MOVE_NORMAL, pl);
	if (!PropHunt_IsPossessableProp(trace_ent))
		return FALSE;

	PropHunt_Possess(pl, trace_ent);
	return TRUE;	// consumed even if the room-check refused (don't shove the prop)
};

// impulse-6 hook (W_CheckImpulses, sv_weapons.qc).  TRUE = consumed.
float(entity pl) PropHunt_ToggleYawLock =
{
	if (!PropHunt_IsHider(pl))
		return FALSE;
	if (!pl.ph_disguise_modelindex)
		return FALSE;
	if (pl.ph_yaw_locked)
	{
		pl.ph_yaw_locked = 0;
		sprint(pl, PRINT_HIGH, "Prop rotation UNLOCKED.\n");
	}
	else
	{
		pl.ph_yaw_locked = 1;
		pl.ph_locked_yaw = pl.v_angle_y;
		sprint(pl, PRINT_HIGH, "Prop rotation LOCKED.\n");
	}
	return TRUE;
};

// --- Prop-corpse removal ----------------------------------------------------

// A killed disguised hider SHATTERS: W_ApplyDamage broadcasts the player-gib
// burst, and the prop copy must vanish with them instead of lying around as a
// frozen prop corpse (an obvious double next to the still-standing original).
// Called from PlayerKilled right after Player_VisualProxy_DetachAsCorpse, so it
// operates on the freshly detached victim.last_corpse.
//
// Instant networked removal, NOT VisProxy_RetireCorpse: the CoD body-sink would
// slide a crate through the floor over a second, and the corpse must disappear
// under the gib burst.  PVSF_NOREMOVE must be dropped BEFORE the remove or the
// engine never sends CSQC_Ent_Remove and the prop ghosts on clients until the
// edict slot is reused (same trap VisProxy_RetireCorpse documents).
void(entity victim) PropHunt_RemovePropCorpse =
{
	entity c = victim.last_corpse;
	if (!c || c.classname != "player_visual_proxy" || !c.vis_is_corpse)
		return;
	if (c.vis_sinking)
		return;			// already mid-retire elsewhere — don't double-process
	c.vis_sinking = TRUE;	// idempotency latch: RetireCorpse (respawn / round sweep) now skips it
	c.pvsflags    = 0;	// drop NOREMOVE so the remove networks
	c.think       = SUB_Remove;
	c.nextthink   = time + 0.1;
	victim.last_corpse = world;	// PlayerSpawn's previous-body retire has nothing left to do
};
