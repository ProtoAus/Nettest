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

	precache_model(self.model);
	setmodel(self, self.model);      // sets self.mins/maxs from the model bounds

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
void() Props_SpawnStatic =
{
	if (!Props_SetupModel())
		return;

	self.movetype = MOVETYPE_NONE;          // static — no ODE integration (won't fall)
	self.solid    = SOLID_PHYSICS_BOX;      // oriented box via World_OBBTrace, matches the client mirror
	setsize(self, self.mins, self.maxs);   // box = model bounds

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
};

void() prop_static           = { Props_SpawnStatic(); };
void() prop_static_override  = { Props_SpawnStatic(); };
void() prop_detail           = { Props_SpawnStatic(); };
void() prop_dynamic          = { Props_SpawnStatic(); };
void() prop_dynamic_override = { Props_SpawnStatic(); };

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
	if (!cvar("sv_props_physics"))
	{
		self.movetype = MOVETYPE_NONE;
		self.solid    = SOLID_NOT;
		if (self.colormod == '0 0 0')
			self.colormod = '1 1 1';
		return;
	}

	setsize(self, self.mins, self.maxs);   // box = model bounds
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
