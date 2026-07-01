//
// server/sv_props.qc — Source/HL2 entity-lump prop spawn functions
//
// On Source maps the console used to print
//     Couldn't find spawn function for prop_static / prop_dynamic / prop_physics
// because the mod had no QC spawn function for these classnames, so the engine
// dropped the entity and the prop never appeared.  (The *gamelump* static props
// the HL2 plugin batches are a separate path; THESE are the placed entity-lump
// props.)  This file adds the spawn functions for "basic compatibility":
//
//   static / dynamic group  -> render the model + a SOLID box (model bounds).
//   physics group           -> ODE rigid box + +use carry (like the cabinet).
//
// Source .mdl loads through the STANDARD model path (precache_model + setmodel —
// loader registered at plugins/hl2/mod_hl2.c), but it is render-mesh only (no
// .phy collision hull), so ALL collision here is a box derived from the model's
// authored bounds.  Everything else is reused verbatim from the unified PhysObj
// + carry + CSQC-mirror systems (sv_physprop.qc) — see [[unified-physobj-system]].
//
// Reused (all defined in earlier-compiled files, so no forward decls needed):
//   BrushSync_ApplyRenderKeys  (sv_brushsync.qc) rendermode/amt/color -> fx
//   PhysObj_Setup / PhysObj_Think (sv_physprop.qc) unified ODE rigid body
//   phys_files_Send            (sv_physprop.qc) MODEL-AGNOSTIC CSQC solid mirror
//

// ---------------------------------------------------------------------------
// Shared model + render-key + angle setup.  Mirrors cycler.qc:114-171 and the
// env_sprite .vmt guard (sv_env_sprite.qc:123).  Returns FALSE (and removes
// self) when there is no usable model so callers can early-out.
// ---------------------------------------------------------------------------
float() Props_SetupModel =
{
	// Master off-switch for ALL Source prop_* entities. Reload a map with
	// sv_props_enable 0 to spawn NONE of them — the clean A/B test for whether the
	// props are behind instability / RAM growth on a prop-dense Source map.
	if (!cvar("sv_props_enable"))
	{
		remove(self);
		return FALSE;
	}

	if (!self.model || self.model == "")
	{
		dprint(sprintf("%s: no model set, removing\n", self.classname));
		remove(self);
		return FALSE;
	}

	// A Source ".vmt" is a MATERIAL (sprite), not a model.  Feeding it to the
	// model loader builds a dummy and historically crashed the sprite path —
	// reject it exactly like env_sprite does.
	if (substring(self.model, strlen(self.model) - 4, 4) == ".vmt")
	{
		dprint(sprintf("%s: refusing .vmt material '%s' as a model, removing\n",
		               self.classname, self.model));
		remove(self);
		return FALSE;
	}

	// FTE's QW setmodel does NOT copy the model's bounding box to the entity by default:
	// for QuakeWorld progs it leaves self.mins/maxs at ZERO (pr_cmds.c PF_setmodel gates the
	// size transfer on `progstype != PROG_QW || sv_gameplayfix_setmodelsize_qw`). That made
	// the degenerate guard below fire and shrink a full IQM/MD3 prop to the +-16 fallback
	// cube -- the tiny broadphase box that let the player walk INTO the model in every
	// sv_prop_collision mode. Enable the real-box transfer so setmodel hands us the TRUE
	// model bounds (131x250x122 for the van, not +-16). The mod setsizes its own entities
	// explicitly, so this global is safe.
	cvar_set("sv_gameplayfix_setmodelsize_qw", "1");
	cvar_set("sv_gameplayfix_setmodelrealbox", "1");

	precache_model(self.model);
	setmodel(self, self.model);      // now copies the real model bounds -> self.mins/maxs
	if (cvar("sv_debug_physprops"))
		dprint(sprintf("%s: '%s' model bbox %v .. %v\n", self.classname, self.model, self.mins, self.maxs));

	// GoldSrc/Source .mdl studiomodels carry NO usable hull: these props are
	// actually GoldSrc v10 .mdl (magic IDST, ver 10), loaded by the engine's
	// GoldSrc loader (gl_hlmdl.c) which NEVER assigns mod->mins/maxs (the v10
	// header bbox fields are unread and zero on disk anyway). So setmodel leaves
	// self.mins == self.maxs == '0 0 0' — a ZERO box. ODE then skips body
	// creation (com_phys_ode.c: DotProduct(geomsize)==0 -> no dCreateBox), so a
	// physics prop never falls and just floats; and a zero box is non-solid, so
	// the +use grab traceline never hits it. The cabinet (sv_physprop.qc:794) and
	// barrel (:274) sidestep this by hand-tuning setsize instead of trusting the
	// model bounds — do the same here with a sensible fallback cube.
	if ((self.maxs_x - self.mins_x) < 1 ||
	    (self.maxs_y - self.mins_y) < 1 ||
	    (self.maxs_z - self.mins_z) < 1)
	{
		local float ph = cvar("sv_props_default_halfsize");
		if (ph < 1)
			ph = 16;                                  // default 32-unit cube
		// feet-on-floor box (mins_z 0), matching the cabinet's convention and the
		// usual Source prop model origin at the base, so a dropped prop rests on
		// the ground rather than half-buried.
		setsize(self, '-1 -1 0' * ph, '1 1 2' * ph);
		if (cvar("sv_debug_physprops"))
			dprint(sprintf("%s: model '%s' has a degenerate bbox; using fallback cube +-%g\n",
			               self.classname, self.model, ph));
	}

	// rendermode / renderamt / rendercolor -> .alpha / .colormod / .effects
	BrushSync_ApplyRenderKeys();

	// HL `angle KEY` single-axis compass shortcut -> angles_y (yaw).
	if (self.angles == '0 0 0' && self.angle != 0)
	{
		self.angles_y = self.angle;
		self.angle    = 0;
	}

	return TRUE;
};

// ---------------------------------------------------------------------------
// Static / dynamic scenery: render + SOLID_BBOX (axis-aligned box from model
// bounds).  prop_dynamic renders a static rest pose (no animation driver) per
// the "non-physics scenery" decision; an animated variant could later hook
// cycler_think (cycler.qc:92).
//
// Client collision: the mod's predicted CSQC pmove + CSQC bullet traces only
// see CSQC-LOCAL solids, never engine-replicated entities — so without a mirror
// the local player rubber-bands on (and shoots through) a server-only solid.
// We reuse the cabinet's model-agnostic CSQC sender (phys_files_Send): with
// velocity 0 and not-carried it streams a STATIONARY solid box the client
// rebuilds locally as a SOLID_PHYSICS_BOX.  We use SOLID_PHYSICS_BOX on the
// SERVER too (NOT SOLID_BBOX) so both sides agree for ROTATED props: the engine
// OBB patch (world.c:1156 World_OBBTrace) rotates the trace by .angles purely
// geometrically — keyed on solid==SOLID_PHYSICS_BOX, with NO ODE body / MOVETYPE
// dependency — so a MOVETYPE_NONE static box collides as its real oriented shape
// on both client and server (a SOLID_BBOX server box would be axis-aligned and
// mispredict against the oriented client mirror).
// ---------------------------------------------------------------------------
// Solidity spawnflags (apply to every prop_* class routing through here).
const float PROP_NOTSOLID   = 1;   // force no collision (overrides the per-class default)
const float PROP_FORCESOLID = 2;   // force collision ON (overrides a non-solid class default)
const float PROP_FORCEBOX   = 4;   // force the cheap oriented box even for an IQM/MD3 model
const float PROP_PREDICTED  = 8;   // CSQC-mirror so the LOCAL pmove collides (rock-solid; hero props only)

// Mesh formats that expose the engine's NativeTrace (mod_alias) can collide as their
// actual TRIANGLE MESH (SOLID_PHYSICS_TRIMESH, world.c:1073) instead of a box.
// GoldSrc/Source .mdl load as mod_halflife (no NativeTrace) and MUST stay on the box.
// We can't tell GoldSrc .mdl from native Quake .mdl by extension, so only the
// unambiguous mesh formats opt in — which is exactly the user's IQM nature props, and
// NEVER the Source-map .mdl clutter (those keep the cheap box → Source maps stay safe).
float(string m) Prop_IsTrimeshModel =
{
	float n = strlen(m);
	if (n < 4)
		return FALSE;
	string ext = substring(m, n - 4, 4);
	return (ext == ".iqm" || ext == ".md3");
};

// ---------------------------------------------------------------------------
// Predicted-collision mirror (PROP_PREDICTED flag).  A lean PVS-gated CSQC
// entity (CSQC_ENT_PRED_PROP) carrying the model + scaled SOLID so the LOCAL
// predicted pmove + CSQC bullet traces collide CLIENT-side — no rubber-band.
// Wire layout MUST match CSQC_PredProp_Update (cl_physprop.qc) byte-for-byte.
// Hero props only — at thousands this is the d1_canals mirror-flood OOM.
// ---------------------------------------------------------------------------
float(entity playerent, float changedflags) predprop_Send =
{
	WriteByte (MSG_ENTITY, CSQC_ENT_PRED_PROP);
	WriteShort(MSG_ENTITY, self.modelindex);
	WriteCoord(MSG_ENTITY, self.origin_x);
	WriteCoord(MSG_ENTITY, self.origin_y);
	WriteCoord(MSG_ENTITY, self.origin_z);
	WriteCoord(MSG_ENTITY, self.angles_x);
	WriteCoord(MSG_ENTITY, self.angles_y);
	WriteCoord(MSG_ENTITY, self.angles_z);
	WriteCoord(MSG_ENTITY, self.mins_x);   // already scaled (setsize in Props_SpawnStatic)
	WriteCoord(MSG_ENTITY, self.mins_y);
	WriteCoord(MSG_ENTITY, self.mins_z);
	WriteCoord(MSG_ENTITY, self.maxs_x);
	WriteCoord(MSG_ENTITY, self.maxs_y);
	WriteCoord(MSG_ENTITY, self.maxs_z);
	WriteByte (MSG_ENTITY, (self.solid == SOLID_PHYSICS_TRIMESH) ? 1 : 0);   // 1 = mesh, 0 = box
	WriteCoord(MSG_ENTITY, self.scale);    // drives the client trimesh narrowphase scale + render
	WriteByte (MSG_ENTITY, self.skin);
	WriteByte (MSG_ENTITY, bound(0, rint(self.colormod_x * 255), 255));
	WriteByte (MSG_ENTITY, bound(0, rint(self.colormod_y * 255), 255));
	WriteByte (MSG_ENTITY, bound(0, rint(self.colormod_z * 255), 255));
	WriteByte (MSG_ENTITY, bound(0, rint(self.alpha * 255), 255));   // 0 → client treats as opaque
	return TRUE;
};

// nonsolid_default: prop_detail passes TRUE (Source decorative detail props are
// non-solid); prop_static / prop_dynamic pass FALSE (oriented collision box,
// matching Source-map static props + the rotated-OBB client trace).
void(float nonsolid_default) Props_SpawnStatic =
{
	if (!Props_SetupModel())
		return;

	self.movetype = MOVETYPE_NONE;          // static — no ODE integration (won't fall)

	// Per-class default, overridable by either spawnflag.
	float nonsolid = nonsolid_default;
	if (self.spawnflags & PROP_FORCESOLID) nonsolid = FALSE;
	if (self.spawnflags & PROP_NOTSOLID)   nonsolid = TRUE;
	if (nonsolid)
		self.solid = SOLID_NOT;
	else if (!(self.spawnflags & PROP_FORCEBOX) && Prop_IsTrimeshModel(self.model))
		self.solid = SOLID_PHYSICS_TRIMESH;   // IQM/MD3 → per-triangle collision (engine NativeTrace; server-only, like the box)
	else
		self.solid = SOLID_PHYSICS_BOX;       // GoldSrc/Source .mdl (or Force Box) → oriented box via World_OBBTrace
	// Collision bbox scales with the visual `scale` (default 1).  For BOX props the
	// OBB reads only mins/maxs, so this fully scales their collision; for TRIMESH it
	// scales the broadphase/PVS bbox (the per-triangle narrowphase scale lives in the
	// engine — World_ClipMoveToEntity, ENGINE_PATCHES Patch 50).
	float sc = self.scale;
	if (sc <= 0) sc = 1;
	setsize(self, self.mins * sc, self.maxs * sc);
	if (cvar("sv_debug_physprops"))
		dprint(sprintf("%s: '%s' collision bbox (scale %g) %v .. %v\n",
		               self.classname, self.model, sc, self.mins, self.maxs));

	// A fresh entity's colormod is '0 0 0' (= black on the client); default to full
	// brightness when ApplyRenderKeys didn't set a tint.
	if (self.colormod == '0 0 0')
		self.colormod = '1 1 1';

	// NO per-prop CSQC mirror for static scenery.  Prop-dense Source maps place
	// THOUSANDS of prop_static (d1_canals_01: entnums past 8000), and an always-on
	// CSQC entity each (phys_files_Send + PVSF_NOREMOVE = sent to every client,
	// ignoring PVS) floods the CSQC entity stream until the update packet truncates
	// -> a desynced entity-number read -> Host_EndGame, and previously a ~34GB
	// CSQC_EntityCheck realloc OOM (see ENGINE_PATCHES Patch 25).  Static props
	// never move, so the engine's STANDARD PVS-culled entity networking renders them
	// (modelindex/angles/colormod/alpha are all networked) at near-zero ongoing cost
	// and scales to thousands.  Trade-off: the local predicted CSQC pmove no longer
	// client-side-collides them (the server SOLID_PHYSICS_BOX still blocks bullets,
	// grenades and every non-predicted move); a minor rubber-band on decorative
	// clutter is well worth not flooding the wire.  prop_physics keep their mirror.

	// Predicted collision (opt-in, PROP_PREDICTED — hero props only): mirror this prop
	// to CSQC so the LOCAL predicted pmove + bullet traces collide client-side → no
	// rubber-band.  PVS-gated (no PVSF_NOREMOVE): a static prop is never carried off
	// screen and you only collide when near (= in PVS).  This replaces the standard
	// engine render-net with the CSQC mirror (CSQC_PredProp_Update renders it).
	if ((self.spawnflags & PROP_PREDICTED) && self.solid != SOLID_NOT)
	{
		self.SendEntity = predprop_Send;
		self.SendFlags  = 1;
	}
};

void() prop_static           = { Props_SpawnStatic(FALSE); };  // solid oriented box (default)
void() prop_static_override  = { Props_SpawnStatic(FALSE); };
void() prop_detail           = { Props_SpawnStatic(TRUE);  };  // non-solid decorative (Source detail prop)
void() prop_dynamic          = { Props_SpawnStatic(FALSE); };
void() prop_dynamic_override = { Props_SpawnStatic(FALSE); };

// ---------------------------------------------------------------------------
// Physics props: ODE rigid box + +use carry — same recipe as the filing
// cabinet (phys_files_spawn_infront, sv_physprop.qc:733).  Source .mdl has no
// .phy mesh, so collision is a box from the model bounds (also required for the
// carry velocity-servo; the engine World_OBBTrace patch rotates it oriented).
// ---------------------------------------------------------------------------
void() Props_SpawnPhysics =
{
	if (!Props_SetupModel())
		return;

	// sv_props_physics 0 -> spawn as a NON-COLLIDABLE visual-only prop: no ODE rigid
	// body, no CSQC solid mirror, no +use carry. Each physics prop otherwise creates
	// ONE live ODE body (was free before the bbox fix, because a zero box made ODE skip
	// body creation), so a prop-dense Source map now simulates hundreds of bodies — the
	// likely instability/RAM source while map-testing. This keeps the model visible
	// (essentially a non-solid prop_static) but removes all the physics cost.
	// PROP_NOTSOLID (spawnflag) OR sv_props_physics 0 -> NON-COLLIDABLE visual-only prop: no ODE
	// rigid body, no CSQC solid mirror, no +use carry. Each physics prop otherwise creates ONE
	// live ODE body, so a prop-dense Source map simulates hundreds of bodies. This keeps the model
	// visible (essentially a non-solid prop_static) but removes all the physics cost.
	if (!cvar("sv_props_physics") || (self.spawnflags & PROP_NOTSOLID))
	{
		self.movetype = MOVETYPE_NONE;
		self.solid    = SOLID_NOT;
		if (self.colormod == '0 0 0')
			self.colormod = '1 1 1';
		return;
	}

	// nettest Patch 70: scale the broadphase AABB by the visual scale (like Props_SpawnStatic) so a
	// scaled prop's box + the NETWORKED mins/maxs (phys_files_Send sends self.mins/maxs -> the CSQC
	// mirror's box + the ODE box geom) match the scaled model/hull. Was raw bounds -> loose for
	// scale<1, broken for scale>1.
	float ppsc = self.scale; if (ppsc <= 0) ppsc = 1;
	setsize(self, self.mins * ppsc, self.maxs * ppsc);   // broadphase AABB = scaled model bounds (narrowphase = hull/mesh)

	// IQM/MD3 -> SOLID_PHYSICS_TRIMESH so the player collides with the generated convex HULL /
	// ACD decomposition (World_HullTrace, sv_prop_collision 2/3) like prop_static; GoldSrc/Source
	// .mdl (or the Force-Box flag) -> oriented box. ODE builds a body for either solid type
	// (com_phys_ode.c) so the prop still falls + tumbles; barrels/cans are TRIMESH+ODE proof.
	if (!(self.spawnflags & PROP_FORCEBOX) && Prop_IsTrimeshModel(self.model))
		self.solid = SOLID_PHYSICS_TRIMESH;
	else
		self.solid = SOLID_PHYSICS_BOX;

	if (self.colormod == '0 0 0')
		self.colormod = '1 1 1' * cvar("sv_carry_lightscale");

	self.po_fx_enabled    = TRUE;   // impact / slide / scrape contact FX
	self.po_carry_enabled = TRUE;   // +use grab / carry / throw (flag-gated carry)
	self.po_stuck_grace   = 5;      // seconds embedded in BSP before despawn

	// Per-entity mass override ("mass" key) falls back to the shared cvar.
	local float pmass = (self.mass > 0) ? self.mass : cvar("sv_physprop_mass");
	PhysObj_Setup(self, pmass, cvar("sv_physprop_friction"));   // MOVETYPE_PHYSICS + ODE
	self.think     = PhysObj_Think;
	self.nextthink = time + 0.05;

	// CSQC solid mirror (reused) so the local pmove + bullets collide and the
	// carrier can client-predict the hold pose.
	self.SendEntity = phys_files_Send;
	self.SendFlags  = 1;
	self.pvsflags   = PVSF_NOREMOVE;
};

void() prop_physics             = { Props_SpawnPhysics(); };
void() prop_physics_override    = { Props_SpawnPhysics(); };
void() prop_physics_multiplayer = { Props_SpawnPhysics(); };
void() prop_sphere              = { Props_SpawnPhysics(); };   // single rigid box (no true sphere sim)
void() prop_ragdoll             = { Props_SpawnPhysics(); };   // single rigid box (no ragdoll sim)
