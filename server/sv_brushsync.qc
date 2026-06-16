//
//  sv_brushsync.qc  –  replicated solid brush entities
//
//  Replicates brush models to CSQC so shared tracebox prediction sees the
//  same func_wall geometry as the server.
//
//  Doors and buttons send additional parameters (pos1, pos2, speed, state)
//  so the client can predict their movement instantly.
//

.float brush_type;      // BRUSH_TYPE_* — set by func_door/func_button
.float mover_state;     // current movement state (shared with door_state/button_state)
// Forward-decl: defined in sv_doors.qc which compiles after this
// file.  Used by solid_brush_SendEntity to inform CSQC's +use
// predictor whether the door's ONE_MOVEMENT latch is exhausted.
.float door_movement_done;

// GoldSrc-convention render keys.  Stored on every replicated brush
// so the map's entity string can specify them.  Only `renderamt` is
// currently honoured (translated to FTE's 0..1 .alpha below); the
// others are declared so the engine accepts the keys without
// warnings and so future code can pick them up without an FGD
// migration.  All four default to 0 = "use defaults".
//   rendermode      — 0 = normal, 1 = color, 2 = texture, 3 = glow,
//                      4 = solid, 5 = additive (HL semantics)
//   rendercolor     — RGB tint when rendermode != 0
//   zhlt_lightflags — compile-time hint (0 = default, 1 = embed-fix,
//                      2 = opaque)
//   renderamt       — 0..255 alpha; redeclared here so func_wall /
//                      func_door / func_button inherit it via
//                      SV_InitReplicatedSolidBrush, while
//                      func_breakable continues to handle it in its
//                      own spawn (declarations of the same field name
//                      across files share a slot).
.float  rendermode;
.vector rendercolor;
.float  zhlt_lightflags;
.float  renderamt;
// GoldSrc renderfx (kRenderFx*) — 17-value animation enum applied on
// top of rendermode.  Values 0..16: 0 Normal, 1 Slow Pulse,
// 2 Fast Pulse, 3 Slow Wide Pulse, 4 Fast Wide Pulse, 5 Slow Fade Away,
// 6 Fast Fade Away, 7 Slow Become Solid, 8 Fast Become Solid,
// 9 Slow Strobe, 10 Fast Strobe, 11 Faster Strobe, 12 Slow Flicker,
// 13 Fast Flicker, 14 Constant Glow, 15 Distort, 16 Hologram.
// Evaluated each render frame in CSQC via BrushSync_ApplyRenderFX
// so the per-frame work doesn't cost server bandwidth.  Field is
// shared so the brushsync wire and any point entity that supports
// renderfx (env_sprite, cycler_sprite, cycler) can read it from a
// single declaration.
.float  renderfx;

// Set TRUE on a brush whose every surface uses the HL "AAATRIGGER"
// texture — the standard mapping placeholder for trigger volumes /
// clip helpers / cosmetic invisibles.  CSQC reads it and hides the
// entity locally when cl_aaatrigger is 0.  Detected once at spawn
// via getsurfacetexture; a brush whose textures change mid-game
// would need a re-detection pass (none of the current entity
// classes do that).
.float  is_aaatrigger;

// Walk every surface of `self`'s currently-set model and return
// TRUE only when ALL surfaces are textured with AAATRIGGER.  Mixed
// brushes (one aaatrigger face, three regular textures) are NOT
// considered trigger brushes — the mapper presumably wanted the
// rest visible.  Empty models / models with no surfaces return
// FALSE.  Texture name comparison is case-insensitive (BSP texture
// names ship in mixed case across compilers).
float() Brush_IsAATrigger =
{
    float i = 0;
    float saw_any = 0;
    while (i < 4096)        // sanity cap; brushes never have this many
    {
        if (getsurfacenumpoints(self, i) <= 0)
            break;
        string tex = getsurfacetexture(self, i);
        if (tex != "" && tex != __NULL__)
        {
            if (strtolower(tex) != "aaatrigger")
                return 0;
            saw_any = 1;
        }
        i = i + 1;
    }
    return saw_any;
};

// FTE/DP effect bits used by the rendermode translator below.  These
// values match the engine's expectations — see sv_defs.qc:683-694
// for the full list.  EF_ADDITIVE specifically isn't const-declared
// in sv_defs.qc (it's only exposed via the DP_EF_ADDITIVE feature
// define), so we re-declare locally with the canonical literal.
const float SOLIDBRUSH_EF_ADDITIVE     = 32;
const float SOLIDBRUSH_EF_FULLBRIGHT   = 512;
const float SOLIDBRUSH_EF_NODEPTHTEST  = 8192;

// Translate the GoldSrc render keys into FTE-equivalent fields on
// `self`.  Called from SV_InitReplicatedSolidBrush (for func_wall /
// func_door / func_button) and from func_breakable's own spawn.
//
// rendermode mapping (HL kRender* values):
//   0 Normal    — opaque, no FX.  renderamt unused.
//   1 Color     — flat tint via rendercolor; renderamt is alpha.
//   2 Texture   — textured surface with alpha; renderamt is alpha.
//   3 Glow      — additive + no-depth-test (sprite-style); renderamt is alpha.
//   4 Solid     — alpha-tested transparency (HL "{}" textures or
//                 shader alphafunc).  Forces full opacity so the
//                 texture's per-pixel alpha is the only source of
//                 transparency; renderamt is intentionally ignored.
//                 Without this, an explicit self.alpha < 1 would
//                 push the engine onto the alpha-blend path and the
//                 alpha-test transparent pixels would render as
//                 semi-visible — visually "wall disappears".
//   5 Additive  — additive blend; renderamt is alpha.
//
// rendercolor is read as a `.vector` with each component in 0..255
// (the FGD `color255` editor type produces "R G B" strings, which
// QC's vector-key parser splits into self.rendercolor_x/y/z).
void() BrushSync_ApplyRenderKeys =
{
    // HL semantics: renderamt is an explicit "FX Amount 0..255" that
    // multiplies into the alpha channel for translucent modes.  QC
    // can't tell "key absent" from "key set to 0", so for the modes
    // where 0 means "invisible" (Color/Texture/Glow/Additive) we just
    // accept that — mappers picking those modes are expected to set
    // renderamt explicitly.  The Normal-mode fallback below preserves
    // back-compat with brushes that rely on a bare `renderamt` to
    // fade without ever setting rendermode.
    float ra_alpha = bound(0, self.renderamt / 255, 1);

    if (self.rendermode == 1)        // Color
    {
        self.alpha    = ra_alpha;
        self.colormod = self.rendercolor / 255;
    }
    else if (self.rendermode == 2)   // Texture (alpha-blend)
    {
        // HL mapping convention: mode 2 with NO renderamt set is the
        // common shorthand for "use the texture's own alpha mask"
        // (the {TEXTURE prefix gives a per-pixel alpha-test cutout).
        // Strict HL semantics would render that case fully invisible
        // (alpha = 0/255 = 0), but most mappers write rendermode 2
        // and expect a transparent-mask texture to "just work" — so
        // when no explicit renderamt is set we fall back to alpha-
        // test (mode 4) semantics: full opacity, let the texture's
        // own alpha drive transparency.  Bspguy and other permissive
        // viewers do the same.
        //
        // Mode 2 with renderamt > 0 keeps alpha-blend behaviour for
        // the explicit "X% see-through" use case.
        if (self.renderamt > 0)
            self.alpha = ra_alpha;
        else
            self.alpha = 1;
    }
    else if (self.rendermode == 3)   // Glow
    {
        self.alpha    = ra_alpha;
        // Additive + fullbright, but DEPTH-TESTED so walls occlude it.  (HL's kRenderGlow
        // is no-depth + a per-frame visibility trace; we don't do the trace, so leaving
        // NODEPTHTEST on made the glow draw over ALL geometry — visible across the map
        // through walls.  Depth-testing gives the wall occlusion the user expects.)
        self.effects  = self.effects | SOLIDBRUSH_EF_ADDITIVE | SOLIDBRUSH_EF_FULLBRIGHT;
        if (self.rendercolor != '0 0 0')
            self.colormod = self.rendercolor / 255;
    }
    else if (self.rendermode == 4)   // Solid (alpha-test)
    {
        // Full opaque — the texture's own per-pixel alpha (or shader
        // alphafunc / "{}" prefix on HL BSPs) is the transparency
        // source.  rendercolor is unused for mode 4.
        self.alpha = 1;
    }
    else if (self.rendermode == 5)   // Additive
    {
        self.alpha   = ra_alpha;
        self.effects = self.effects | SOLIDBRUSH_EF_ADDITIVE;
        if (self.rendercolor != '0 0 0')
            self.colormod = self.rendercolor / 255;
    }
    else                             // 0 / unset — Normal
    {
        // Default opaque, but back-compat: a brush with renderamt
        // set and rendermode=0 should still fade (matches the
        // original renderamt-only behaviour from before the
        // rendermode dispatch was added).
        if (self.alpha <= 0)
            self.alpha = 1;
        if (self.renderamt > 0)
            self.alpha = ra_alpha;

        // Extension over strict HL semantics: apply rendercolor as
        // a colormod tint even in Normal mode.  HL mode 0 ignores
        // rendercolor (mappers had to switch to mode 1 to get any
        // colour, which replaces the texture with flat tinted
        // colour — losing the texture).  In practice the common
        // mapper expectation is "tint my brush red but keep the
        // texture visible and solid", and FTE's colormod does
        // exactly that (it multiplies the lit texture output, works
        // on Quake palette + BSP textures the same as any other).
        // Default rendercolor "0 0 0" leaves colormod at neutral
        // (1,1,1) so brushes without an explicit colour are
        // unaffected.
        if (self.rendercolor != '0 0 0')
            self.colormod = self.rendercolor / 255;
    }
};

// Belt-and-suspenders pass: walk every static brushmodel entity and
// OR PHYSDROP_DIM into dim_hit.  The primary fix for phys-drop
// collision against brushwork is at SPAWN time (sv_breakable.qc and
// SV_InitReplicatedSolidBrush below), but this pass remains as a
// safety net for any brush that bypassed those entry points (mid-game
// Spawn(), savegame restore, modder-added classnames).
//
// Movers (func_door / func_button) are gated by sv_phys_drops_movers
// — see SV_InitReplicatedSolidBrush for the LCP-crash background.
//
// Dimension filter background:
//   FTE's ODE auto-builds a trimesh geom for every SOLID_BSP entity
//   once any MOVETYPE_PHYSICS entity is in the world (rbe_hasphysicsents).
//   The collision is then gated by a bidirectional dim mask check
//   (com_phys_ode.c:2625-2631).  Phys drops use a custom bit
//   (PHYSDROP_DIM = 256) on top of the engine default 255.  Without
//   the OR here, brushwork has dim_hit=255 and the phys-drop's
//   dim_solid=256 fails the check — the drop tunnels through.
//
// `sv_debug_physprops 1` logs each entity touched + its dim_hit
// before/after, so it's easy to confirm in-game that the wiring
// reached every brush.
void() BrushSyncODE =
{
    float dbg = cvar("sv_debug_physprops");
    float movers = cvar("sv_phys_drops_movers");
    float n_b = 0, n_d = 0, n_w = 0;

    entity e = nextent(world);
    while (e)
    {
        float touch = 0;
        if (e.classname == "func_breakable") { touch = 1; n_b = n_b + 1; }
        else if (movers && (e.classname == "func_door"
                         || e.classname == "func_button")) { touch = 1; n_d = n_d + 1; }
        else if (e.classname == "func_wall") { touch = 1; n_w = n_w + 1; }

        if (touch && !(e.dimension_hit & PHYSDROP_DIM))
        {
            if (dbg)
                dprint(sprintf("[brushsync] %s ent=%g dim_hit %g -> %g\n",
                    e.classname, num_for_edict(e),
                    e.dimension_hit, e.dimension_hit | PHYSDROP_DIM));
            e.dimension_hit = e.dimension_hit | PHYSDROP_DIM;
        }
        e = nextent(e);
    }

    if (dbg)
        dprint(sprintf("[brushsync] total breakables=%g movers=%g walls=%g (movers gate=%g)\n",
            n_b, n_d, n_w, movers));
};

float(entity playerent, float changedflags) solid_brush_SendEntity =
{
    if (cvar("sv_debug_ent_types") && self.classname == "func_breakable")
    {
        bprint(PRINT_HIGH, sprintf("[brush send] ent=%g model='%s' origin=%v\n",
                                   num_for_edict(self), self.model, self.origin));
    }

    WriteByte(MSG_ENTITY, CSQC_ENT_SOLID_BRUSH);
    // Send the precached modelindex instead of the model string — CSQC
    // uses setmodelindex() to resolve it back.  Saves ~14-24 B per send
    // (brush names are typically "*N" for inline BSP submodels).  FTE
    // docs on modelnameforindex explicitly call this out as a net-traffic
    // reduction pattern.
    WriteShort(MSG_ENTITY, self.modelindex);

    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);

    WriteCoord(MSG_ENTITY, self.angles_x);
    WriteCoord(MSG_ENTITY, self.angles_y);
    WriteCoord(MSG_ENTITY, self.angles_z);

    WriteCoord(MSG_ENTITY, self.mins_x);
    WriteCoord(MSG_ENTITY, self.mins_y);
    WriteCoord(MSG_ENTITY, self.mins_z);

    WriteCoord(MSG_ENTITY, self.maxs_x);
    WriteCoord(MSG_ENTITY, self.maxs_y);
    WriteCoord(MSG_ENTITY, self.maxs_z);

    // alpha quantised to byte (0..255); effects is a bitfield but only the
    // low 16 bits are realistically used on brushes (EF_NODRAW, EF_FULLBRIGHT,
    // EF_NOSHADOW etc), so WriteShort is enough headroom.
    WriteByte(MSG_ENTITY,  bound(0, rint(self.alpha * 255), 255));
    WriteShort(MSG_ENTITY, self.effects);
    // GoldSrc render keys.  rendermode primarily serves as a hint
    // for CSQC's predict / brush-render code (the actual blend mode
    // is already encoded in self.alpha + self.effects above);
    // rendercolor needs to cross the wire because colormod isn't
    // covered by the byte+short above.  All four bytes only mean
    // anything when rendermode != 0; for default mode they're zero
    // overhead.
    WriteByte(MSG_ENTITY, self.rendermode);
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendercolor_x), 255));
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendercolor_y), 255));
    WriteByte(MSG_ENTITY, bound(0, rint(self.rendercolor_z), 255));
    // GoldSrc renderfx (0..16) — animation enum applied on top of
    // rendermode.  Evaluated by CSQC each render frame in
    // BrushSync_ApplyRenderFX (shared/sh_renderfx.qc).  Default 0
    // (Normal) costs 1 byte; the animation overhead happens only on
    // clients, never on server bandwidth.
    WriteByte(MSG_ENTITY, bound(0, rint(self.renderfx), 16));
    // AAATRIGGER flag — CSQC hides the brush locally when cl_aaatrigger
    // is 0.  Server still treats the brush as solid for traces /
    // collisions; this is a pure visibility cue for mapper helpers.
    WriteByte(MSG_ENTITY, self.is_aaatrigger ? 1 : 0);
    // Non-solid bit — TRUE when the server has self.solid == SOLID_NOT
    // (func_water, func_illusionary-via-brushsync, PASS_THROUGH doors).
    // CSQC was always forcing SOLID_BSP for replicated brushes, which
    // made the client's pmove collide with brushes the server treats
    // as walk-through.  Result: client pushed against a wall the
    // server isn't enforcing → server reconciliation snaps the player
    // back → "laggy" rubberbanding (esp. visible inside func_water).
    WriteByte(MSG_ENTITY, (self.solid == SOLID_NOT) ? 1 : 0);

    WriteCoord(MSG_ENTITY, self.velocity_x);
    WriteCoord(MSG_ENTITY, self.velocity_y);
    WriteCoord(MSG_ENTITY, self.velocity_z);
    // Angular velocity for rotating brushwork (func_door_rotating).
    // CSQC integrates self.angles += avelocity * frametime each
    // render frame so rotation is smooth between snapshots — without
    // this the brush steps from one snapshot pose to the next at
    // server-tick cadence and reads as visibly jerky.  Sliding
    // doors / buttons / static brushes ship 0/0/0 and the integrator
    // becomes a no-op.
    WriteCoord(MSG_ENTITY, self.avelocity_x);
    WriteCoord(MSG_ENTITY, self.avelocity_y);
    WriteCoord(MSG_ENTITY, self.avelocity_z);

    // Door/button parameters for client-side prediction
    WriteByte(MSG_ENTITY, self.brush_type);
    // Rotating-brush metadata.  `brush_is_rotating` tells CSQC
    // whether pos1/pos2 are ANGLES (func_door_rotating) rather than
    // origins (func_door/func_button).
    WriteByte(MSG_ENTITY, self.brush_is_rotating ? 1 : 0);
    if (self.brush_type == BRUSH_TYPE_CONVEYOR)
    {
        // Conveyor: ship movedir + speed + spawnflags so CSQC pmove
        // can apply the same per-frame positional displacement the
        // server does (PM_CheckConveyors in sh_pmove.qc).  Without
        // this the player would feel rubberbanded under any ping —
        // server pushes them forward, client predicts no push, then
        // the snapshot snaps the position when it arrives.
        WriteCoord(MSG_ENTITY, self.movedir_x);
        WriteCoord(MSG_ENTITY, self.movedir_y);
        WriteCoord(MSG_ENTITY, self.movedir_z);
        WriteFloat(MSG_ENTITY, self.speed);
        WriteFloat(MSG_ENTITY, self.spawnflags);
    }
    else if (self.brush_type == BRUSH_TYPE_DOOR || self.brush_type == BRUSH_TYPE_BUTTON)
    {
        WriteCoord(MSG_ENTITY, self.pos1_x);
        WriteCoord(MSG_ENTITY, self.pos1_y);
        WriteCoord(MSG_ENTITY, self.pos1_z);
        WriteCoord(MSG_ENTITY, self.pos2_x);
        WriteCoord(MSG_ENTITY, self.pos2_y);
        WriteCoord(MSG_ENTITY, self.pos2_z);
        WriteFloat(MSG_ENTITY, self.speed);
        WriteByte(MSG_ENTITY, self.mover_state);
        // CSQC reads this as `door_locked` — semantically a single
        // boolean meaning "should CSQC skip +use prediction for this
        // mover".  We compute the answer from the same gates
        // door_use checks server-side, so a direct player +use gets
        // the same accept/reject decision on both sides and the
        // client doesn't mispredict an animation the server will
        // reject (and vice versa, doesn't suppress a press the
        // server would have allowed).
        //
        //   - DOOR_USE_ABLE off (bit 2) → direct +use rejected.
        //   - door_movement_done = 1   → ONE_MOVEMENT exhausted.
        // Spawnflag literal 2 used here because DOOR_USE_ABLE is
        // defined in sv_doors.qc, which compiles after this file.
        // USE_ONLY (256) gates target activation, which CSQC doesn't
        // predict, so it's intentionally not folded in.
        float predict_block = 0;
        if (self.brush_type == BRUSH_TYPE_DOOR)
        {
            if (!(self.spawnflags & 2))
                predict_block = 1;
            if (self.door_movement_done)
                predict_block = 1;
        }
        WriteByte(MSG_ENTITY, predict_block);
    }

    // Material code (BREAKABLE_*) — only meaningful on func_breakable.
    // Every other brush class (func_wall / func_door / func_button)
    // leaves .style at the QC default 0, which under the current
    // material numbering is GLASS.  Sending that as-is means CSQC's
    // Impact_ClassifyLocal classifies every plain wall hit as a
    // glass surface — wrong impact particles, wrong decal, wrong
    // ricochet sound on the shooter's screen.
    //
    // Use 255 as a sentinel for "no material info, use default";
    // CSQC's classify functions don't have a case for 255 and fall
    // through to IMPACT_MAT_DEFAULT, which is the right concrete-
    // dust look for a non-breakable wall.
    float reported_style = 255;
    if (self.classname == "func_breakable")
        reported_style = self.style;
    WriteByte(MSG_ENTITY, reported_style);

    // Current health.  Clamped to [0, 32767] and written as a short so
    // the attacker's CSQC can subtract predicted damage and decide
    // whether the shot would break the brush, playing the break sound
    // locally without a server round-trip.
    //
    // Brushes whose server-side takedamage is DAMAGE_NO report 0
    // unconditionally so CSQC's prediction path bails out at its
    // `brush_health <= 0` gate.  This covers:
    //   - BREAKABLE_TRIGGER_ONLY (bullets pass straight through; only
    //     a trigger fires the break)
    //   - BREAKABLE_ONLY_EXPLOSION (gunfire ignored)
    //   - targetname-gated breakables without ALWAYS_SHOOTABLE
    //   - ordinary func_wall and other non-breakable brushwork
    // Without this gate, gunfire on any of those brushes used to
    // mispredict a local break that the server immediately rolled
    // back — visible as a per-shot invisible-flicker.
    float reported_health = self.health;
    if (self.takedamage == DAMAGE_NO)
        reported_health = 0;
    WriteShort(MSG_ENTITY, bound(0, reported_health, 32767));

    // max_health + cnt let CSQC spawn matching debris gibs locally when
    // the attacker predicts a break. Same values the server would pass to
    // CSQC_SpawnGlassGibs / CSQC_SpawnDebrisGibs via the gib events.
    WriteShort(MSG_ENTITY, bound(0, self.max_health, 32767));
    WriteByte(MSG_ENTITY, bound(0, self.cnt, 255));

    // Broken flag — func_breakable flips this when destroyed. Client
    // uses it to toggle drawmask / solid so the brush cleanly reappears
    // on round restart without relying on engine to re-send after a
    // SendEntity = __NULL__ transition.
    WriteByte(MSG_ENTITY, self.breakable_broken ? 1 : 0);

    return TRUE;
};

void() SV_InitReplicatedSolidBrush =
{
    if (!self.model)
    {
        dprint(sprintf("%s: no model, removing\n", self.classname));
        remove(self);
        return;
    }

    setmodel(self, self.model);
    self.movetype = MOVETYPE_PUSH;
    self.solid = SOLID_BSP;
    BrushSync_ApplyRenderKeys();
    // AAATRIGGER detection — must run after setmodel so the brush
    // model is loaded and getsurfacetexture has data to walk.
    self.is_aaatrigger = Brush_IsAATrigger();

    self.pvsflags = PVSF_NOREMOVE;
    self.SendEntity = solid_brush_SendEntity;
    self.SendFlags = 1;

    // Phys-drop ODE collision filter — see the long comment in
    // sv_breakable.qc:func_breakable for why.  Gated by
    // sv_phys_drops_movers because the prior version of this code
    // (the deferred BrushSyncODE pass) used to crash with LCP
    // "s <= 0" / dxNormalize4 errors when phys bodies landed on
    // moving func_door / func_button trimeshes.  The current FTE
    // engine syncs static-geom positions per-frame to mover origins
    // (com_phys_ode.c:2496-2502), so the crash class should be gone
    // — but the cvar gate stays in case a regression surfaces.
    if (cvar("sv_phys_drops_movers"))
        self.dimension_hit = self.dimension_hit | PHYSDROP_DIM;
};

/*QUAKED func_wall (.5 .5 .5) ? TRIGGERSPAWN TOGGLE START_ON NOT_SOLID
Simple solid brush entity. Replicated to CSQC so client prediction collides
with it identically to the server.
*/
void() func_wall =
{
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
};
