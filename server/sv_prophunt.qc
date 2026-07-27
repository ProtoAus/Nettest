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

// TRUE when this player is a hider who must stay WEAPONLESS (mp_ph_hider_noweapons).
// Hiders already spawn empty — PlayerSpawn pins the Prop Hunt loadout to WEP_NONE for
// BLUE (sv_player.qc) — but nothing stopped one walking over a dead seeker's dropped
// rifle, or +use'ing a map-placed gun, and shooting back.  This is the gate that keeps
// "hiders hide, seekers shoot" actually true.  Blocks BOTH pickup paths (weapon_touch
// covers walk-over and, via SV_TryWeaponPickup, +use) and BOTH server fire entry points
// (the autonomous W_WeaponFrame path and the client-driven `cs` notification).
// Server-authoritative only: CSQC may still predict a shot for the pathological case of
// an already-armed hider, but the server simply won't fire it.  Not worth a new movevar
// for a case the pickup block above already makes unreachable.
float(entity pl) PropHunt_HiderNoWeapons =
{
	if (!PropHunt_IsHider(pl))
		return FALSE;
	return cvar("mp_ph_hider_noweapons") != 0;
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
	pl.ph_rel_fwd       = '0 0 0';
	pl.ph_rel_up        = '0 0 0';
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
	// Fresh prop = fresh UPRIGHT pose.  Basis is in the carry frame (yaw0 = v_angle_y +
	// 180, the convention CarryRot_SpinBasis's mouse axes are documented against).  fwd =
	// '-1 0 0' so an upright pose composes to angles_y = v_angle_y — i.e. IDENTICAL to the
	// old flat disguise facing (no visual regression), with '0 0 1' up.
	pl.ph_rel_fwd = '-1 0 0';
	pl.ph_rel_up  = '0 0 1';
	if (pl.ph_yaw_locked)
		pl.ph_locked_yaw = pl.v_angle_y;	// keep the lock, re-latch the frozen frame yaw to the current view

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

	// Already carrying a prop?  This +use is a drop / door-open, not a possess — return FALSE
	// so SV_PlayerTryUse's carry logic (which handles both) runs.  You can't swap disguise
	// while your hands are full; drop first.
	if (pl.carried_prop != world)
		return FALSE;

	makevectors(pl.v_angle);
	vector src = pl.origin + pl.view_ofs;
	traceline(src, src + v_forward * cvar("mp_ph_possess_dist"), MOVE_NORMAL, pl);

	// While ALREADY disguised, a +use aimed at a prop of THE SAME MODEL as your disguise
	// PICKS IT UP (HL2 carry) instead of re-possessing — so you can lug a matching prop
	// around to build cover / blend into a moved cluster ("pick up the same prop as you").
	// A DIFFERENT model still falls through to swap your disguise below.  NOTE: only
	// prop_physics with an active ODE body is carriable (Carry_IsCarriable); a same-model
	// STATIC prop has no body to grab, so it re-possesses (harmless, same model), and a
	// non-prop falls through to doors/buttons.
	if (pl.ph_disguise_modelindex
	    && trace_ent.modelindex == pl.ph_disguise_modelindex
	    && Carry_IsCarriable(trace_ent))
	{
		Carry_TryGrab(pl, trace_ent);
		return TRUE;	// consumed (a refused grab just does nothing — don't shove the prop)
	}

	if (!PropHunt_IsPossessableProp(trace_ent))
		return FALSE;

	PropHunt_Possess(pl, trace_ent);
	return TRUE;	// consumed even if the room-check refused (don't shove the prop)
};

// Toggle the prop's rotation lock with NO SNAP (fixes "unlock jumps the prop to the
// camera").  LOCK freezes the current world orientation (the basis is unchanged, the
// frame yaw is frozen at the current view).  UNLOCK re-anchors: re-express the basis in
// the LIVE view frame so the world orientation is IDENTICAL at the instant of unlock,
// after which it resumes yaw-following from exactly where it was.
// `live_yaw` is the client's view yaw at the toggle instant (the client passes its own so
// server and client re-anchor to the SAME frame — v_angle_y can differ by a command's latency).
void(entity pl, float live_yaw) PropHunt_ToggleLock =
{
	if (pl.ph_yaw_locked)
	{
		float lyaw0 = pl.ph_locked_yaw + 180;	// the frozen frame
		float vyaw0 = live_yaw + 180;			// the live frame
		vector wF = CarryRot_FromFrame(pl.ph_rel_fwd, lyaw0);	// pose -> world
		vector wU = CarryRot_FromFrame(pl.ph_rel_up,  lyaw0);
		pl.ph_rel_fwd = CarryRot_ToFrame(wF, vyaw0);			// world -> live frame
		pl.ph_rel_up  = CarryRot_ToFrame(wU, vyaw0);
		pl.ph_yaw_locked = 0;
		sprint(pl, PRINT_HIGH, "Prop rotation UNLOCKED.\n");
	}
	else
	{
		pl.ph_yaw_locked = 1;
		pl.ph_locked_yaw = live_yaw;	// freeze the frame; the basis is already the shown pose
		sprint(pl, PRINT_HIGH, "Prop rotation LOCKED.\n");
	}
};

// impulse-6 FALLBACK for clients without the CSQC gesture module (cl_prophunt_rotate.qc
// consumes the reload key and drives the CSEv_ handlers below instead).  TRUE = consumed.
float(entity pl) PropHunt_ToggleYawLock =
{
	if (!PropHunt_IsHider(pl))
		return FALSE;
	if (!pl.ph_disguise_modelindex)
		return FALSE;
	PropHunt_ToggleLock(pl, pl.v_angle_y);	// no client module -> use the server's own yaw
	return TRUE;
};

// impulse-7 (Weapon Special) DECLOAK: a disguised hider voluntarily drops the disguise —
// smoke poof + back to the human player model/hull (so you can reposition, then re-possess a
// better prop).  Room-checked so you can't decloak into geometry that only the smaller prop
// hull fit.  TRUE = consumed the impulse (so it never falls through to a real weapon special).
float(entity pl) PropHunt_TryDecloak =
{
	if (!PropHunt_IsHider(pl))       return FALSE;
	if (!pl.ph_disguise_modelindex)  return FALSE;
	if (pl.is_dead)                  return FALSE;

	// Feet-planted origin for the STANDING hull — the reverse of the possess shift
	// (sv_prophunt.qc:207): keep the hull bottom at the same world Z as the prop's bottom.
	vector norg = pl.origin;
	norg_z = (pl.origin_z + pl.ph_hull_minz) - PM_MINS_z;

	// The standing hull must FIT at that origin, or decloaking would jam you into a wall.
	tracebox(norg, PM_MINS, PM_MAXS, norg, MOVE_NORMAL, pl);
	if (trace_startsolid)
	{
		sprint(pl, PRINT_HIGH, "No room to decloak here.\n");
		return TRUE;	// consumed — refused, but don't fall through (a hider has no weapon)
	}

	// COMMITTED (room check passed).  Release any carried prop only NOW, so a REFUSED decloak
	// above stays a true no-op instead of stripping the prop the hider was lugging.
	if (pl.carried_prop != world)
		Carry_Drop(pl);	// don't keep lugging a picked-up prop after turning human

	// Smoke poof at the prop hull centre BEFORE clearing the disguise (ClearDisguise zeroes the
	// hull).  Same CSQC_EVENT_PROP_DECLOAK the death decloak uses (sv_player.qc:~1156).
	float poof_z = pl.origin_z + pl.ph_hull_minz + pl.ph_hull_height * 0.5;
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_PROP_DECLOAK);
	WriteCoord(MSG_MULTICAST, pl.origin_x);
	WriteCoord(MSG_MULTICAST, pl.origin_y);
	WriteCoord(MSG_MULTICAST, poof_z);
	WriteByte(MSG_MULTICAST, bound(4, pl.ph_hull_height, 72));
	multicast(pl.origin, MULTICAST_PVS);

	setorigin(pl, norg);
	PropHunt_ClearDisguise(pl);	// restores the human mesh + standing hull
	sprint(pl, PRINT_HIGH, "Decloaked.\n");
	return TRUE;
};

// --- CSQC rotation gesture handlers (sendevent from cl_prophunt_rotate.qc) ---------
// self = the sending client's player.  All gated to a live disguised hider.

// Hold-R free rotate: `a` is the FRAME basis expressed as angles (client sends
// CarryRot_Angles(fwd,up)); `yaw0` is the CLIENT's frozen frame yaw (v_angle_y at hold-
// start).  Store both and COMMIT (world-absolute) so the pose PERSISTS after release.
// CRITICAL: freeze ph_locked_yaw = the SENT yaw0, NOT self.v_angle_y — the client keeps
// re-sending this same state for ~0.4s after release (settle window) while the view is
// already free, so latching the live server yaw would drift the pose away from what the
// client renders (permanent local-vs-remote divergence).  NaN-hardened + rate-limited.
void(vector a, float yaw0) CSEv_proprot_vf =
{
	if (!self.ph_disguise_modelindex) return;
	if (self.is_dead)                 return;
	if (!PropHunt_IsHider(self))      return;

	float maxrate = cvar("sv_carry_rot_maxrate");
	if (maxrate < 1) maxrate = 1;
	if (time < self.ph_rot_next) return;
	self.ph_rot_next = time + (1 / maxrate);

	if (!(fabs(a_x) <= 720))    return;
	if (!(fabs(a_y) <= 720))    return;
	if (!(fabs(a_z) <= 720))    return;
	if (!(fabs(yaw0) <= 100000)) return;	// NaN-safe (fails every ordered test)
	CarryRot_Axes(a);
	CarryRot_Ortho(crot_X, crot_Z);
	if (!(crot_oF * crot_oF > 0.5)) return;
	if (!(crot_oU * crot_oU > 0.5)) return;

	self.ph_rel_fwd    = crot_oF;
	self.ph_rel_up     = crot_oU;
	self.ph_yaw_locked = 1;			// posing commits (world-absolute)
	self.ph_locked_yaw = yaw0;		// the client's frozen frame — keeps both sides in lockstep
};

// Discrete gestures: mode 1 = tap-R lock toggle, mode 2 = double-tap reset to upright/loose.
// `frame_yaw` is the client's view yaw at the gesture instant (used by the lock re-anchor
// so server + client anchor to the same frame; ignored by reset).
void(float mode, float frame_yaw) CSEv_propgest_ff =
{
	if (!self.ph_disguise_modelindex) return;
	if (self.is_dead)                 return;
	if (!PropHunt_IsHider(self))      return;
	if (!(fabs(frame_yaw) <= 100000)) return;	// NaN-safe

	if (mode == 1)
		PropHunt_ToggleLock(self, frame_yaw);
	else if (mode == 2)
	{
		self.ph_rel_fwd    = '-1 0 0';
		self.ph_rel_up     = '0 0 1';
		self.ph_yaw_locked = 0;				// upright, yaw resumes following the view
		sprint(self, PRINT_HIGH, "Prop rotation RESET.\n");
	}
};
