// ==========================================================================
//  cl_ragdoll.qc — CLIENT-SIDE Box3D ragdoll test spawner (dev/cheat)
//
//  Drives an FTE skeletal ragdoll in csqc_world via the EXPLICIT `skel_ragupdate`
//  builtin.  This deliberately does NOT rely on the engine's packet-entity auto-path.
//
//  *** WHY THE RAGDOLL FILE IS NAMED `.rag`, NOT `<model>.doll` ***
//  The engine AUTO-LOADS a sibling named exactly `<model>.doll` into `mod->dollinfo`
//  (gl_model.c "%s.doll"), and then cl_ents.c auto-instances + SIMULATES that doll for
//  EVERY live entity using the model (rag_updatedeltaent) — i.e. every live PLAYER
//  collapses into a limp ragdoll on spawn and the client crashes.  We never want that;
//  we drive ragdolls explicitly.  The ONE shared doll is RAGDOLL_DOLL_PATH
//  (models/player/humanoid.rag — binds by bone name, serves every humanoid IQM; the
//  auto-loader misses it, dollinfo stays NULL).  Do NOT rename it to `.doll`.
//
//  `skel_ragupdate(e,"doll <path>",0)` loads the doll ON DEMAND (rag_loaddoll -> FS_LoadFile,
//  any extension) and PRINTS any parse / "rigid body system not enabled" error — so this
//  both WORKS and DIAGNOSES.  csqc_world already has the Box3D rbe + the static BSP floor,
//  so the limbs fall and rest.  This is the same machinery a corpse ragdoll (Phase 3) will
//  use — the corpse is a CSQC proxy driven explicitly, not a packet entity.
//
//  Console (CLIENT, not `cmd`):
//    spawnragdoll   - drop a leet ragdoll on the floor ahead (collapses in place)
//    throwragdoll   - launch one from the eye in the aim direction (cl_ragdoll_throwspeed)
//    killragdolls   - remove them all
//    r_showragdoll 1 - (engine cvar) draw the collision bodies + joint-anchor gizmos for tuning
// ==========================================================================

.entity rag_next;		// intrusive list of spawned test ragdolls (killragdolls cleanup)
entity   rag_head;

// Per-frame: derive the simulated bone matrices (the engine steps csqc_world.rbe +
// rag_doallanimations in CSQC_RunThreads; the empty dollcmd just reads that back into the
// skeleton) then submit the entity for drawing with its ragdoll pose.  skel_ragupdate also draws
// the r_showragdoll gizmos (now nodepthtest = through the mesh); at r_showragdoll>=2 we ghost the
// model so those gizmos are unobstructed.
float() Killcam_Active;		// defined in cl_killcam.qc (compiles later); fwd-decl to gate the ragdoll below
// Player-model brightness cap (cl_teamtint.qc, compiles AFTER this file) — apply the SAME r_playermodels_maxlight
// rolloff the live player proxies use, so a ragdoll under bright lighting doesn't blow out.
float(vector pos, float cap_byte, float knee_frac) CSQC_MaxlightScale;

float() CSQC_RagdollTest_Predraw =
{
	// The killcam is a rewind-replay that reconstructs the ALIVE scene (it re-poses the victim to its
	// pre-death standing pose).  This ragdoll lives in the PRESENT, so drawing it over the replay shows you
	// "already dead as a ragdoll".  Hide it while a replay is active (killcam is local-death only, and the
	// replay already masks every other present-time effect); the engine keeps stepping the doll, so it
	// reappears settled once the replay ends.
	if (Killcam_Active() && !self.vis_kc_ragdoll)	// the killcam's OWN doll renders; dev/other dolls hide
	{
		self.alpha = -1;
		return PREDRAW_NEXT;
	}
	skel_ragupdate(self, "", 0);
	self.alpha = (cvar("r_showragdoll") >= 2) ? 0.25 : 1;	// 2 = translucent ghost for tuning
	// Cap the brightness like the player proxies (CSQC_ApplyTeamTints only walks player_visual_proxy, so it
	// never reaches this ragdoll).  The doll flops, so sample getlight at its live origin each frame.
	self.colormod = '1 1 1' * CSQC_MaxlightScale(self.origin, cvar("r_playermodels_maxlight"), cvar("r_maxlight_softknee"));
	BlobShadow_Emit(self);   // ground blob under the flopping doll
	addentity(self);
	return PREDRAW_NEXT;
};

// Shared spawner used by spawnragdoll (floor drop), throwragdoll (aimed launch), and the death
// corpse ragdoll.  Does NOT manage the rag_head list — the caller does (test spawns list; death
// corpses are owned by their proxy instead).
//   org        = ground point (seatfloor) or the exact spawn origin (else)
//   seatfloor  = TRUE  -> seat the model's real bottom ~2u above org (a resting drop)
//                FALSE -> place the entity origin exactly at org (thrown / at the death location)
//   vel/avel   = linear/angular velocity to launch with; MUST be set before skel_ragupdate("doll")
//                so the engine seeds every limb (World_*_RagCreateBody).
//   modelpath  = the IQM player model (the doll is the shared RAGDOLL_DOLL_PATH — binds by bone name).
//   posesrc    = OPTIONAL corpse proxy to inherit the death pose + facing from (world = none).  When set, the
//                ragdoll's skeleton is CLONED from the corpse's live skeleton (skel_copybones) so the doll (with
//                `spawnpose current`) starts in the exact pose the player was in when shot, and r.angles is set
//                to the corpse's facing.  world = build the model's default pose facing yaw 0 (the test spawns).
// Returns the ragdoll entity, or world on failure.
// Quick-test hack: when non-empty, CSQC_RagdollSpawnAt loads THIS doll instead of the shared
// RAGDOLL_DOLL_PATH (for models whose bone names the humanoid doll can't bind, e.g. the
// Ratslayer soldier).  Set before the call, clear after.
string rag_doll_override;

entity(vector org, float seatfloor, vector vel, vector avel, string modelpath, entity posesrc) CSQC_RagdollSpawnAt =
{
	entity r = spawn();
	r.classname = "csqc_ragdoll_test";
	setmodel(r, modelpath);
	if (!r.modelindex)
	{
		print(sprintf("^1ragdoll: %s failed to load\n", modelpath));
		remove(r);
		return world;
	}
	// CSQC setmodel fills r.mins/r.maxs from the real IQM bounds (csqc_setmodel); the model origin isn't
	// at the feet, so a floor drop seats the lowest mesh point ~2u above the ground (no half-burying).
	if (seatfloor)
		setorigin(r, org + '0 0 1' * (2 - r.mins_z));
	else
		setorigin(r, org);
	// Face the way the corpse faced (the movement-facing lives in the entity yaw; the torso is already
	// counter-twisted in the cloned bones) — else the ragdoll spawns facing yaw 0 = "the wrong direction".
	r.angles    = posesrc ? posesrc.angles : '0 0 0';
	r.drawmask  = MASK_ENGINE;
	// Inherit the corpse's skin variant + colormap so the ragdoll matches the body (else skin 0 / no colormap).
	r.colormap  = posesrc ? posesrc.colormap : 0;
	r.skin      = posesrc ? posesrc.skin : 0;
	r.velocity  = vel;		// seeded into the limbs by RagCreateBody (engine patch)
	r.avelocity = avel;

	r.skeletonindex = skel_create(r.modelindex);
	if (!r.skeletonindex)
	{
		print("^1ragdoll: skel_create failed\n");
		remove(r);
		return world;
	}
	// Seed the skeleton with the DEATH POSE: clone the corpse's live skeleton (which at kill time still holds
	// the last ALIVE rendered pose — mid-run etc., incl. the spine/aim deform), so with `spawnpose current` the
	// doll instanciates in that pose.  No corpse (test spawns) -> the model's own default pose.  skel_copybones
	// (0,0) copies ALL bones between the two same-model skeletons.
	if (posesrc && posesrc.skeletonindex)
		skel_copybones(r.skeletonindex, posesrc.skeletonindex, 0, 0);
	else
		skel_build(r.skeletonindex, r, r.modelindex, 0, 0, -1);
	skel_ragupdate(r, strcat("doll ", (rag_doll_override != "") ? rag_doll_override : RAGDOLL_DOLL_PATH), 0);

	r.predraw = CSQC_RagdollTest_Predraw;
	return r;
};

// DEATH ragdoll: spawn a client ragdoll at a dead player's corpse proxy, flung along the shot
// direction (+ the corpse's death-moment velocity).  Called from the proxy predraw; the returned
// entity is stored on the proxy (vis_ragdoll_ent) and torn down when the proxy is removed.
entity(entity corpse, vector shotdir) CSQC_SpawnCorpseRagdoll =
{
	float impulse = cvar("cl_ragdoll_death_impulse");
	if (impulse <= 0) impulse = 220;			// tunable knockback along the shot

	vector vel  = corpse.velocity + shotdir * impulse;
	vector avel = '0 0 0';
	// a GENTLE tumble about a horizontal axis perpendicular to the shot (skip if the shot is ~vertical).
	// Kept modest (was 110) so the fresh doll doesn't over-spin as it flops out of the reference pose.
	vector spinaxis = crossproduct(shotdir, '0 0 1');
	if (vlen(spinaxis) > 0.1)
		avel = normalize(spinaxis) * 50;

	return CSQC_RagdollSpawnAt(corpse.origin, FALSE, vel, avel, corpse.model, corpse);
};

void() CSQC_SpawnRagdollTest =
{
	entity r;
	vector eye, fwd, ahead, ground;

	eye = (vector)getproperty(VF_ORIGIN);
	makevectors((vector)getproperty(VF_CL_VIEWANGLES));
	fwd = v_forward; fwd_z = 0;
	if (vlen(fwd) < 0.001) fwd = '1 0 0';
	fwd = normalize(fwd);

	// ~96u ahead of the eye, then drop to the floor
	traceline(eye, eye + fwd * 96, MOVE_NORMAL, world);
	ahead = trace_endpos;
	traceline(ahead + '0 0 32', ahead - '0 0 4096', MOVE_NORMAL, world);
	ground = trace_endpos;

	r = CSQC_RagdollSpawnAt(ground, TRUE, '0 0 0', '0 0 0', "models/player/leet/leet.iqm", world);
	if (r)
	{
		r.rag_next = rag_head; rag_head = r;	// test spawns live in the killragdolls list
		print("spawnragdoll: client ragdoll spawned (run skel_info to inspect)\n");
	}
};

void() CSQC_ThrowRagdollTest =
{
	entity r;
	vector eye, aim;
	float speed;

	eye = (vector)getproperty(VF_ORIGIN);
	makevectors((vector)getproperty(VF_CL_VIEWANGLES));
	aim = v_forward;

	speed = cvar("cl_ragdoll_throwspeed");
	if (speed <= 0) speed = 500;		// tunable: set cl_ragdoll_throwspeed <n>

	// spawn ~24u in front of the eye at ~chest height, launch forward + a small lob + a tumble
	r = CSQC_RagdollSpawnAt(eye + aim * 24 + '0 0 -8', FALSE,
	                        aim * speed + '0 0 140', v_right * 220, "models/player/leet/leet.iqm", world);
	if (r)
	{
		r.rag_next = rag_head; rag_head = r;
		print(sprintf("throwragdoll: launched at %g u/s\n", speed));
	}
};

// QUICK TEST: `throwsoldier` — same launch as throwragdoll but with the Ratslayer soldier
// (models/Ratslayer/soldier.md5mesh) and its OWN generated doll (the soldier's bones —
// Hip/UpperLeg_L/... — don't exist in the shared humanoid.rag, so it needs its own file).
// Uses the doll's shipped filename directly: the <model>.doll auto-load trap only bites live
// SERVER entities using the model, and only this locally-spawned test ent uses it.
void() CSQC_ThrowSoldierTest =
{
	entity r;
	vector eye, aim;
	float speed;

	eye = (vector)getproperty(VF_ORIGIN);
	makevectors((vector)getproperty(VF_CL_VIEWANGLES));
	aim = v_forward;

	speed = cvar("cl_ragdoll_throwspeed");
	if (speed <= 0) speed = 500;

	rag_doll_override = "models/Ratslayer/soldier.md5mesh.doll";
	r = CSQC_RagdollSpawnAt(eye + aim * 24 + '0 0 -8', FALSE,
	                        aim * speed + '0 0 140', v_right * 220, "models/Ratslayer/soldier.md5mesh", world);
	rag_doll_override = "";
	if (r)
	{
		r.rag_next = rag_head; rag_head = r;	// killragdolls cleans these up too
		print(sprintf("throwsoldier: launched at %g u/s\n", speed));
	}
};

void() CSQC_KillRagdolls =
{
	entity r, n;
	float cnt = 0;
	for (r = rag_head; r; r = n)
	{
		n = r.rag_next;
		// Teardown order matters: skel_delete only MARKS the object dead and defers freeing the
		// rbe bodies to the next R_ClearScene, leaving a NULL-model doll that rag_doallanimations
		// (every physics tic) + the predraw would deref -> crash.  So stop the predraw, then
		// "cleardoll" to run rag_uninstanciate NOW (destroys every Box3D body+joint), THEN delete.
		r.predraw = __NULL__;
		if (r.skeletonindex)
		{
			skel_ragupdate(r, "cleardoll", 0);
			skel_delete(r.skeletonindex);
		}
		remove(r);
		cnt = cnt + 1;
	}
	rag_head = world;
	print(sprintf("spawnragdoll: removed %g test ragdoll(s)\n", cnt));
};

// --- death-ragdoll DEFERRED cleanup ---------------------------------------------------------------
// A corpse's ragdoll must NOT be torn down inside CSQC_Ent_Remove: that runs during the entity-delta
// NETWORK PARSE, and even a deferred drain at the start of CSQC_UpdateView still crashed — freeing rbe
// bodies + remove()-ing an entity while the render/scene machinery is active is re-entrant.
//
// The safe phase is a THINK on the ragdoll itself.  CSQC entity thinks fire in World_Physics_Frame
// (pr_csqc.c), which runs immediately AFTER the frame's rbe RunFrame and BEFORE the next tick's
// rag_doallanimations — so the freed bodies are never stepped again, and it is NOT inside the render.
// (The mod already relies on CSQC thinks for cleanup: glass gibs, bullet-impact sprites, C4.)
//
// CSQC_Ent_Remove (cl_main.qc) detaches the ragdoll from its corpse proxy, stops it drawing, and points
// its .think here with nextthink = time; this frees it on the next physics tick — the same cleardoll ->
// skel_delete -> remove order the killragdolls console command uses, just from a safe phase.
void() CSQC_RagdollFreeThink =
{
	if (self.skeletonindex)
	{
		skel_ragupdate(self, "cleardoll", 0);	// free the Box3D bodies (cleardoll before delete)
		skel_delete(self.skeletonindex);
		self.skeletonindex = 0;
	}
	remove(self);
};
