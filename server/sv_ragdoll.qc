// ==========================================================================
//  sv_ragdoll.qc — SERVER-SIDE authoritative death ragdolls (Phase 1)
//
//  On a weapon/FF kill the SERVER spawns a `corpse_ragdoll` edict, runs the
//  Box3D doll in sv.world (the engine steps it every physics frame:
//  rag_doallanimations + rbe->RunFrame), and networks the flopping bones to
//  EVERY client via UF_BONEDATA — so all players + spectators see the SAME
//  ragdoll (unlike the old client-side cosmetic one).  It is SOLID (on its own
//  RAGDOLL_DIM dimension so the main bullet/movement traces PASS THROUGH it,
//  CS-style) and can be shoved by bullets (Ragdoll_TryShove).
//
//  *** ENGINE PREREQUISITES (see ENGINE_PATCHES.md P90) ***
//    - sv_ents.c networks SKEL_ABSOLUTE (ragdoll) bones — REQUIRES `.basebone = -1`
//      on the edict or the writer never emits them.
//    - PF_skel_ragedit gained `impulse`/`impulsebody` dollcmds (the shove/throw).
//
//  *** NEVER name a doll `<model>.doll` *** — the engine auto-ragdolls every live
//  player using that model + crashes.  We use `.rag` + explicit skel_ragupdate.
//
//  LIFECYCLE: the ragdoll is owned by the dead player's corpse proxy
//  (corpse.sv_ragdoll_ent = r).  It is torn down from VisProxy_RetireCorpse
//  (sv_main.qc) — the single retire path for the mp_deadbodies cap, respawn, and
//  RoundRestart — so it shares the corpse's lifecycle with no separate cap.
//
//  PHASE-1a LIMITATION (flagged): the animated corpse proxy is NOT yet hidden, so
//  the frozen death-anim body + the flopping ragdoll DOUBLE-DRAW.  Hiding the
//  corpse mesh (needs a networked proxy flag so the killcam can still re-pose it)
//  + applying r_playermodels_maxlight to the server ragdoll's render are Phase-1b.
// ==========================================================================

.entity rag_owner;			// corpse_ragdoll -> the corpse proxy that owns it (mirror of sv_ragdoll_ent)

// Alive-pose capture: PlayerKilled stashes the victim's LAST ALIVE framestate here
// BEFORE SH_PlayerAnim_Death overwrites it, so the ragdoll starts in the pose the
// player was shot in (mid-run etc.), matching the old client behaviour.
float rag_cap_frame;
float rag_cap_baseframe;
float rag_cap_basebone;

void(entity p) Ragdoll_CaptureAlivePose =
{
	rag_cap_frame    = p.frame;
	rag_cap_baseframe = p.baseframe;
	rag_cap_basebone = p.basebone;
};

// Free a server ragdoll in the mandatory order (cleardoll frees the rbe bodies NOW;
// skel_delete alone defers that and rag_doallanimations would deref a dead doll -> crash).
void(entity rd) Ragdoll_Free =
{
	if (!rd || rd.classname != "corpse_ragdoll")
		return;
	if (rd.skeletonindex)
	{
		skel_ragupdate(rd, "cleardoll", 0);
		skel_delete(rd.skeletonindex);
		rd.skeletonindex = 0;
	}
	if (rd.rag_owner)
	{
		rd.rag_owner.sv_ragdoll_ent = world;
		rd.rag_owner.vps_hide_ragdoll = FALSE;		// un-hide the proxy mesh (correctness; the corpse is usually retiring anyway)
		rd.rag_owner.SendFlags |= VP_SF_IDENTITY;
	}
	// if a player is gravity-gunning this corpse when it retires (mp_deadbodies cap), release them cleanly.
	if (rd.rag_carrier)
	{
		rd.rag_carrier.carried_ragdoll = world;
		rd.rag_carrier.pm_carrying = FALSE;
		rd.rag_carrier = world;
	}
	remove(rd);
};

// Per-frame: derive the simulated bone matrices out of the rbe into the skeleton so
// sv_ents.c can network them.  The engine steps the doll itself; we only read it back.
void() Ragdoll_Think =
{
	if (!self.skeletonindex)
	{
		remove(self);
		return;
	}
	skel_ragupdate(self, "", 0);		// derive rbe bodies -> skeleton (networked by sv_ents.c)

	// Re-center the edict onto the doll so it FOLLOWS it (a gravity-gunned or far-slid doll leaves the fixed
	// death origin — the entity-relative networked bones would blow past the ±511u quantizer clamp = stretch,
	// and PVS would use the wrong origin).  Read the pelvis WORLD pos; if it drifted, move the edict there and
	// RE-DERIVE vs the new origin (origin +D, bones -D => same world pose, no visible jump).  Gated on >4u so a
	// settled doll skips the extra derive.
	if (self.rag_pelvis_tag)
	{
		vector pw = gettaginfo(self, self.rag_pelvis_tag);
		if (vlen(pw - self.origin) > 4)
		{
			setorigin(self, pw);
			skel_ragupdate(self, "", 0);	// re-derive vs the NEW origin so the networked bones stay small
		}
	}

	// Tighten the bbox to the live doll each frame.  A FIXED box pinned to the spawn origin let the shove
	// traceline hit a NEIGHBOURING doll's oversized box (world.c keeps the closest broadphase entry) and
	// never tracked the fallen body.  gettaginfo(self,i) gives each bone's WORLD position (applies the
	// yaw-only entity transform); setsize wants mins/maxs RELATIVE to the (fixed) origin.
	float nb = skel_get_numbones(self.skeletonindex);
	if (nb >= 1)
	{
		vector wmin = '999999 999999 999999';
		vector wmax = '-999999 -999999 -999999';
		float i;
		for (i = 1; i <= nb; i = i + 1)
		{
			vector w = gettaginfo(self, i);		// world org of bone i (reads self.skeletonindex, derived above)
			if (w_x < wmin_x) wmin_x = w_x;  if (w_x > wmax_x) wmax_x = w_x;
			if (w_y < wmin_y) wmin_y = w_y;  if (w_y > wmax_y) wmax_y = w_y;
			if (w_z < wmin_z) wmin_z = w_z;  if (w_z > wmax_z) wmax_z = w_z;
		}
		// gettaginfo gives bone JOINTS; leaf-bone HITBOXES extend past them (head skull ~9.5u, feet ~10.75u
		// above/beyond the joint).  Pad generously so the broadphase box fully CONTAINS every hitbox — safe
		// because the shove is MOVE_HITMODEL (per-bone), so a big box never causes a wrong-doll hit.
		vector pad = '16 16 16';
		setsize(self, wmin - pad - self.origin, wmax + pad - self.origin);
	}

	self.nextthink = time;
};

// Generic corpse_ragdoll construction — the edict + Box3D doll, shared by the death path and the
// `throwragdoll` test spawner.  Builds the pose from the passed framestate, seeds the throw momentum,
// instanciates the shared RAGDOLL_DOLL_PATH doll (binds by bone name — one file for every humanoid
// IQM), and starts Ragdoll_Think.  Does NOT attach an owner/hide-flag (the death path does that after).
// Returns the ragdoll (world on any failure).  `mdlpath` MUST be a humanoid IQM ("Bip01" skeleton);
// `angles_yaw` should be YAW-ONLY (pitch/roll fold into r_meshpitch/emat -> client/server mismatch).
// Params are prefixed p_* where they'd shadow the same-named entity FIELD.
entity(string mdlpath, vector org, vector angles_yaw, vector vel, vector avel, float p_frame, float p_baseframe, float p_basebone, float p_skin, float p_colormap) Ragdoll_SpawnCore =
{
	if (!checkbuiltin(skel_ragupdate))	// engine without ragdoll support
		return world;

	entity oldself = self;
	entity r = spawn();
	r.classname = "corpse_ragdoll";
	setmodel(r, mdlpath);
	if (!r.modelindex)
	{
		remove(r);
		return world;
	}
	r.skin     = p_skin;
	r.colormap = p_colormap;
	setorigin(r, org);
	r.angles   = angles_yaw;

	r.solid           = SOLID_BBOX;
	r.movetype        = MOVETYPE_NONE;			// the rbe drives the limbs; the edict origin is fixed
	// CRITICAL: geomtype NONE so the Box3D rbe does NOT build a static collision body from this edict's bbox.
	// A SOLID_BBOX edict otherwise defaults to GEOMTYPE_BOX (com_phys_box3d.c:332) and gets a static rbe body
	// that is RE-CREATED whenever the bbox changes — and the per-frame tight-AABB setsize (Ragdoll_Think) made
	// the doll's OWN dynamic limbs collide with that ever-moving box → ejected → the ragdoll drifts off the map.
	// The edict stays SOLID_BBOX for the QC shove traceline (World_Move, not the rbe); the doll's own limb
	// bodies still collide with the world/floor + players (they're separate rbe bodies, unaffected).
	r.geomtype        = GEOMTYPE_NONE;
	r.pvsflags        = PVSF_NOREMOVE;
	r.dimension_solid = RAGDOLL_DIM;			// pass-through: main bullet/movement traces skip it
	r.dimension_hit   = RAGDOLL_DIM;
	// initial box; Ragdoll_Think tightens it to the live bones each frame (for the shove trace only).
	setsize(r, '-40 -40 -72', '40 40 40');

	// seed the throw momentum BEFORE instancing (rag_instanciate reads .velocity/.avelocity
	// to fling every limb; must be set first).
	r.velocity  = vel;
	r.avelocity = avel;

	r.skeletonindex = skel_create(r.modelindex);
	if (!r.skeletonindex)
	{
		remove(r);
		return world;
	}
	// Build the pose from the passed framestate (split legs/torso like the live player), then set
	// basebone = -1 so sv_ents.c networks the (absolute) ragdoll bones.
	self = r;
	r.frame     = p_frame;
	r.baseframe = p_baseframe;
	r.basebone  = p_basebone;
	SH_PlayerAnim_BuildPoseSkeleton(r.skeletonindex);
	self = oldself;
	r.basebone = -1;						// REQUIRED: the SKEL_ABSOLUTE bone-network branch is gated on basebone < 0

	skel_ragupdate(r, strcat("doll ", RAGDOLL_DOLL_PATH), 0);	// instanciate the doll at the pose (spawnpose current)

	r.rag_pelvis_tag = gettagindex(r, "Bip01 Pelvis");	// cached (model-constant) — the doll centroid for re-center + gravgun hold

	r.think    = Ragdoll_Think;
	r.nextthink = time;
	return r;
};

// Spawn the authoritative ragdoll from a just-created corpse.  Called from PlayerKilled
// AFTER Player_VisualProxy_DetachAsCorpse (so `corpse` = victim.last_corpse) but BEFORE
// victim.velocity is zeroed.
void(entity attacker, entity victim) Ragdoll_SpawnFromDeath =
{
	entity corpse = victim.last_corpse;
	if (!corpse || corpse.classname != "player_visual_proxy")
		return;
	if (!cvar("sv_ragdoll_enable"))
		return;

	// IQM only (the .rag dolls bind IQM skeletons; sini.mdl etc. have no skeleton).
	string mdl = corpse.model;
	float ml = strlen(mdl);
	if (ml < 4 || substring(strtolower(mdl), ml - 4, 4) != ".iqm")
		return;

	// shot direction (fallback: attacker->victim, as the old client path used).
	vector shotdir = '0 0 0';
	if (attacker && attacker != victim && attacker.classname == "player")
	{
		shotdir = victim.origin - attacker.origin;
		shotdir_z = shotdir_z * 0.5;
		if (vlen(shotdir) > 0.1) shotdir = normalize(shotdir); else shotdir = '0 0 0';
	}

	float impulse = cvar("sv_ragdoll_death_impulse");
	if (impulse <= 0) impulse = 220;
	vector vel = victim.velocity + shotdir * impulse;
	vector avel = '0 0 0';
	vector spinaxis = crossproduct(shotdir, '0 0 1');
	if (vlen(spinaxis) > 0.1) avel = normalize(spinaxis) * 50;

	entity r = Ragdoll_SpawnCore(mdl, corpse.origin, [0, corpse.angles_y, 0], vel, avel,
	                             rag_cap_frame, rag_cap_baseframe, rag_cap_basebone,
	                             corpse.skin, corpse.colormap);
	if (!r)
		return;

	// own it via the corpse so VisProxy_RetireCorpse tears it down with the corpse.
	r.rag_owner = corpse;
	corpse.sv_ragdoll_ent = r;

	// hide the corpse proxy's animated mesh (the ragdoll renders in its place) — networked flag,
	// re-dirtied so the corpse re-sends its IDENTITY section (Sync no longer runs on a corpse).
	corpse.vps_hide_ragdoll = TRUE;
	corpse.SendFlags |= VP_SF_IDENTITY;
};

// `cmd throwragdollsv` (mp_cheats) test spawner — fling a standalone leet ragdoll from the player's aim.
// No corpse owner + no hide flag, so nothing retires it via the mp_deadbodies cap; it persists until
// `cmd killragdollssv` (Ragdoll_SweepAll) or a round restart.  Uses the player's LIVE framestate so the
// doll starts in a plausible pose on the shared IQM skeleton.
void(entity player) Ragdoll_SpawnTest =
{
	if (!player)
		return;
	makevectors(player.v_angle);
	float sp = cvar("sv_ragdoll_throwspeed");
	if (sp <= 0) sp = 700;
	vector vel  = v_forward * sp + player.velocity + '0 0 140';
	vector avel = crossproduct(v_forward, '0 0 1') * 120;
	Ragdoll_SpawnCore("models/player/leet/leet.iqm", player.origin + player.view_ofs,
	                  [0, player.v_angle_y, 0], vel, avel,
	                  player.frame, player.baseframe, player.basebone,
	                  player.skin, player.colormap);
};

// Map the struck hitgroup (trace_surface_id from a MOVE_HITMODEL hit) to the .rag doll body it should
// shove.  Hitgroup can't tell upper vs lower limb, but `impulsebody` drags the child limb along the joint,
// so a forearm hit shoving "luparm" still looks right.  "" = unknown -> caller falls back to whole-doll.
string(float hitgroup) Ragdoll_HitgroupBody =
{
	if (hitgroup == HITGROUP_HEAD)     return "head";
	if (hitgroup == HITGROUP_CHEST)    return "chest";
	if (hitgroup == HITGROUP_STOMACH)  return "pelvis";
	if (hitgroup == HITGROUP_LEFTARM)  return "luparm";
	if (hitgroup == HITGROUP_RIGHTARM) return "ruparm";
	if (hitgroup == HITGROUP_LEFTLEG)  return "lthigh";
	if (hitgroup == HITGROUP_RIGHTLEG) return "rthigh";
	return "";
};

// Bullet shove: a shot that PASSED THROUGH a corpse (they're on RAGDOLL_DIM) still pushes it.
// Called from the hitscan sites with the shot segment; does its OWN MOVE_HITMODEL trace on RAGDOLL_DIM
// (so it ignores walls/players AND hits the per-bone hitboxes, not the coarse box — a shot BETWEEN limbs
// misses and doesn't shove), clipped to where the shot actually stopped.  Saves/restores the caller's
// trace globals so it doesn't disturb the surrounding hit processing.
void(vector src, vector shotend, vector dir, float damage) Ragdoll_TryShove =
{
	if (!cvar("sv_ragdoll_enable"))
		return;
	// stash the caller's trace results (MOVE_HITMODEL also clobbers the surface/bone ids)
	vector s_endpos = trace_endpos;
	entity s_ent    = trace_ent;
	vector s_norm   = trace_plane_normal;
	float  s_frac   = trace_fraction;
	float  s_surf   = trace_surface_id;
	float  s_bone   = trace_bone_id;

	float saved_dh = self.dimension_hit;
	self.dimension_hit = RAGDOLL_DIM;			// hit ONLY ragdolls along the segment
	traceline(src, shotend, MOVE_NORMAL | MOVE_HITMODEL, self);	// per-bone hitbox hit, not the coarse bbox
	self.dimension_hit = saved_dh;

	if (trace_ent.classname == "corpse_ragdoll" && trace_ent.skeletonindex)
	{
		float force = cvar("sv_ragdoll_hit_force");
		if (force <= 0) force = 3;
		vector v = dir * (damage * force);
		// per-limb: shove the SPECIFIC limb struck (the rest follows via the joints); fall back to the
		// whole doll if the hitgroup is unknown or the body name isn't in this doll.
		string body = Ragdoll_HitgroupBody(trace_surface_id);
		float  did  = 0;
		if (body != "")
			did = skel_ragupdate(trace_ent, sprintf("impulsebody %s %v", body, v), 0);
		if (!did)
			skel_ragupdate(trace_ent, sprintf("impulse %v", v), 0);
	}

	// restore
	trace_endpos       = s_endpos;
	trace_ent          = s_ent;
	trace_plane_normal = s_norm;
	trace_fraction     = s_frac;
	trace_surface_id   = s_surf;
	trace_bone_id      = s_bone;
};

// Backstop sweep (RoundRestart) — free any corpse_ragdoll still alive.
void() Ragdoll_SweepAll =
{
	entity e, n;
	for (e = findchain(classname, "corpse_ragdoll"); e; e = n)
	{
		n = e.chain;
		Ragdoll_Free(e);
	}
};

// ==========================================================================
//  GRAVITY-GUN carry (Phase 2).  Parallel to the prop Carry_ system: a doll is
//  a multi-body thing, so instead of servoing a single prop.velocity we servo
//  the PELVIS body toward the hold point (impulsebody) and let the other limbs
//  dangle.  Setting player.pm_carrying reuses the CLIENT gravgun viewmodel/throw
//  prediction with no new networking (see sh_wpn_gravitygun.qc / cl_player.qc).
// ==========================================================================

// Grab: latch the ragdoll onto the player.  Called from W_GravGunFire after the prop grab finds nothing.
float(entity player, entity rd) Ragdoll_TryGrab =
{
	if (!rd || rd.classname != "corpse_ragdoll" || !rd.skeletonindex)
		return FALSE;
	if (rd.rag_carrier)			// someone else already holds it
		return FALSE;
	rd.rag_carrier      = player;
	player.carried_ragdoll = rd;
	player.pm_carrying  = TRUE;		// drives the client viewmodel/throw prediction
	return TRUE;
};

// Release without a throw — unlatch; the doll keeps its momentum + gravity.
void(entity player) Ragdoll_CarryDrop =
{
	entity rd = player.carried_ragdoll;
	if (rd)
		rd.rag_carrier = world;
	player.carried_ragdoll = world;
	player.pm_carrying = FALSE;
};

// Throw — launch the WHOLE doll along the aim (+ the player's velocity), then unlatch (flops on landing).
void(entity player) Ragdoll_CarryThrow =
{
	entity rd = player.carried_ragdoll;
	if (rd && rd.classname == "corpse_ragdoll" && rd.skeletonindex)
	{
		makevectors(player.v_angle);
		vector throwvel = v_forward * cvar("sv_gravgun_throw_speed") + player.velocity;
		skel_ragupdate(rd, sprintf("impulse %v", throwvel), 0);
	}
	Ragdoll_CarryDrop(player);
};

// Per-frame hold servo (from PlayerPreThink).  Mirrors Carry_Tick's hold point + velocity servo, but drives
// the pelvis body so the limbs dangle.
void(entity player) Ragdoll_CarryTick =
{
	entity rd = player.carried_ragdoll;
	if (!rd)
		return;
	if (rd.classname != "corpse_ragdoll" || !rd.skeletonindex)	// retired mid-carry
	{
		Ragdoll_CarryDrop(player);
		return;
	}

	// hold point in front of the eye (compute BEFORE gettaginfo, which overwrites v_forward).
	makevectors(player.v_angle);
	vector eye  = player.origin + player.view_ofs;
	vector hold = eye + v_forward * cvar("sv_carry_hold_dist") + '0 0 1' * cvar("sv_carry_hold_z");
	// minimal wall-clip: don't drive the hold point into geometry.
	traceline(eye, hold, MOVE_NOMONSTERS, player);
	if (trace_fraction < 1)
		hold = trace_endpos + trace_plane_normal * 8;

	// current doll centre = the pelvis WORLD position.
	vector center = rd.rag_pelvis_tag ? gettaginfo(rd, rd.rag_pelvis_tag) : rd.origin;

	float ft = frametime; if (ft <= 0) ft = 0.013;
	vector desired = (hold - center) * (1 / ft);
	float maxsp = cvar("sv_carry_max_speed");
	if (maxsp > 0 && vlen(desired) > maxsp)
		desired = normalize(desired) * maxsp;

	// servo the pelvis (limbs dangle); fall back to whole-doll if the body name doesn't resolve.
	float did = skel_ragupdate(rd, sprintf("impulsebody pelvis %v", desired), 0);
	if (!did)
		skel_ragupdate(rd, sprintf("impulse %v", desired), 0);
};

// ==========================================================================
//  GRAVITY-GUN black hole (+attack2) — the pull/blast also acts on corpse
//  ragdolls.  The prop black hole (GravGun_PullTowards / GravGun_BlastFrom)
//  gates on movetype == MOVETYPE_PHYSICS + physics_addforce, so it skips the
//  MOVETYPE_NONE multi-body doll.  These parallel passes drive the doll via
//  the impulse/impulsebody dollcmds instead.  Only FREE (un-grabbed) dolls are
//  affected — a doll you're carrying (rag_carrier set) is left to Ragdoll_CarryTick.
// ==========================================================================

// Per-tick pull while spinning: suck each free corpse ragdoll in `radius` toward `center` by servoing
// its PELVIS (limbs dangle behind).  A proportional servo (velocity toward centre scaled by distance,
// capped) eases them in.  Called from W_GravGun_PullTick after GravGun_PullTowards.
void(vector center, float radius) Ragdoll_PullTick =
{
	if (!cvar("sv_ragdoll_enable") || radius <= 0)
		return;
	float cap = cvar("sv_gravgun_ragdoll_pull_speed");
	if (cap <= 0) cap = 600;

	entity e = findradius(center, radius);
	while (e)
	{
		if (e.classname == "corpse_ragdoll" && e.skeletonindex && e.rag_carrier == world)
		{
			vector pw = e.rag_pelvis_tag ? gettaginfo(e, e.rag_pelvis_tag) : e.origin;
			// STIFF servo, same math as Ragdoll_CarryTick: command the velocity that closes the
			// whole gap in ONE frame, capped.  A proportional velocity=distance servo was far too
			// weak — the pelvis velocity is re-SET each tick but the other 10 limb bodies keep
			// integrating gravity and drag the doll down through the joints, so it sagged hard
			// toward the floor ("massive downward force").  gap/frametime dominates that coupling
			// exactly like the carry hold does; the cap keeps the approach speed sane.
			float ft = frametime; if (ft <= 0) ft = 0.013;
			vector desired = (center - pw) * (1 / ft);
			if (vlen(desired) > cap) desired = normalize(desired) * cap;
			float did = skel_ragupdate(e, sprintf("impulsebody pelvis %v", desired), 0);
			if (!did)
				skel_ragupdate(e, sprintf("impulse %v", desired), 0);
		}
		e = e.chain;
	}
};

// Release blast: fling each free corpse ragdoll in `radius` OUTWARD from `center` (+ upward bias),
// mirroring GravGun_BlastFrom for props.  Whole-doll impulse so the body launches as one and flops.
// Called from the +attack2 falling edge in W_GravGun_HeldTick.
void(vector center, float radius, float speed) Ragdoll_BlastFrom =
{
	if (!cvar("sv_ragdoll_enable") || radius <= 0 || speed <= 0)
		return;

	entity e = findradius(center, radius);
	while (e)
	{
		if (e.classname == "corpse_ragdoll" && e.skeletonindex && e.rag_carrier == world)
		{
			vector pw = e.rag_pelvis_tag ? gettaginfo(e, e.rag_pelvis_tag) : e.origin;
			vector dir = pw - center;
			float dist = vlen(dir);
			if (dist < 1) { dir = '0 0 1'; dist = 1; }	// dead-centre → straight up
			dir = dir * (1 / dist);
			dir_z += 0.35;								// upward bias so they lift off the floor
			dir = normalize(dir);
			skel_ragupdate(e, sprintf("impulse %v", dir * speed), 0);
		}
		e = e.chain;
	}
};
