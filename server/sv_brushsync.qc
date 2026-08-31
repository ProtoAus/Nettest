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
// Same deal.  .door_flags (sv_doors.qc:742) is the NORMALISED spawnflag word
// written at spawn by both the sliding and the rotating class.  Only bit 32 is
// read here — DOOR_TOGGLE (sv_doors.qc:734) == DOORROT_TOGGLE
// (sv_doors_rotating.qc:79) — spelled as a literal because both constants are
// declared in files that compile AFTER this one in sv_progs.src.
.float door_flags;

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
// Assign the HL-derived alpha onto `self`, translating "alpha 0" into
// EF_NODRAW.
//
// This exists because .alpha == 0 does NOT mean invisible in FTE — it means
// "field never set, treat as fully opaque".  Both the server and the CSQC
// entity path special-case it: sv_ents.c:3818 (`if (!ent->xv->alpha)
// state->trans = 255;`) and pr_csqc.c:895 (`if (!in->xv->alpha ||
// in->xv->alpha == 1)`).  So writing renderamt-0 straight into .alpha
// produced the exact OPPOSITE of what the mapper asked for: a brush HL draws
// as nothing came out fully solid.
//
// GoldSrc uses renderamt-0 on a non-Normal rendermode as the standard idiom
// for "present and solid but not drawn" — invisible gib spawners, invisible
// blockers, marker entities.  hl_c01_a1's microwave stew is exactly this: the
// func_breakable "stewgibs" carries rendermode 2 with no renderamt at all,
// and an env_render flips its twin to rendermode 2 to hide it on cue.
//
// EF_NODRAW is the only "don't draw this" the brushsync wire has, and it is
// already the idiom func_wall_toggle_hide uses, so CSQC handles it.
void(float a) BrushSync_SetAlpha =
{
    if (a <= 0)
    {
        self.alpha   = 1;                          // stays 1: EF_NODRAW does the hiding
        self.effects = self.effects | EF_NODRAW;
        return;
    }
    self.alpha = a;
};

void() BrushSync_ApplyRenderKeys =
{
    // HL semantics: renderamt is an explicit "FX Amount 0..255" that
    // multiplies into the alpha channel for translucent modes, and 0 is
    // INVISIBLE, not opaque.  QC can't tell "key absent" from "key set to 0",
    // and both spellings mean the same thing to Half-Life, so both go through
    // BrushSync_SetAlpha above.
    float ra_alpha = bound(0, self.renderamt / 255, 1);

    if (self.rendermode == 1)        // Color
    {
        BrushSync_SetAlpha(ra_alpha);
        self.colormod = self.rendercolor / 255;
    }
    else if (self.rendermode == 2)   // Texture (alpha-blend)
    {
        // Mode 2 with renderamt 0 is invisible in Half-Life, full stop.
        //
        // This used to fall back to alpha-test (mode 4) semantics — full
        // opacity, let the texture's own mask drive transparency — on the
        // theory that mappers write rendermode 2 and expect a "{TEXTURE"
        // cutout to just work.  On a GoldSrc BSP that theory is wrong: the
        // map was authored and tested against real HL, where the result is
        // an invisible brush, and mappers lean on it deliberately.  Measured
        // on the 121-map Sven corpus: 1284 entities carry rendermode 2 with
        // renderamt absent or 0, and they are meant to be unseen.
        //
        // Native (non-GoldSrc) maps keep the permissive reading, because
        // there the mapper is working against THIS FGD, not Half-Life's.
        // Cost of the split, measured across all 29 maps in quakers/maps:
        // zero — the only rendermode-2 brush any of them has carries an
        // explicit non-zero renderamt.
        if (self.renderamt > 0)
            self.alpha = ra_alpha;
        else if (Map_IsGoldSrc())
            BrushSync_SetAlpha(0);
        else
            self.alpha = 1;
    }
    else if (self.rendermode == 3)   // Glow
    {
        BrushSync_SetAlpha(ra_alpha);
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
        BrushSync_SetAlpha(ra_alpha);
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
    // GoldSrc ALTERNATE-TEXTURE selector.  This is the whole of the "+0/+A"
    // mechanism: a brush face textured "+0name" has a sibling "+aname", the BSP
    // loader chains them (engine gl/gl_model.c:3499-3501, guarded on fg_halflife
    // at :3483), and the renderer picks the alternate whenever the entity's
    // frame is non-zero (gl_model.c:3301-3305).  buttons.cpp:723 sets
    // pev->frame = 1 with the comment "use alternate textures" and :744 puts it
    // back to 0.
    //
    // sv_buttons.qc has ALWAYS set .frame 0/1 correctly, and the engine has
    // always been able to render it — but a replicated brush is a CSQC entity,
    // not an engine one, so the only frame the renderer ever sees is the one
    // this delta writes.  It wrote every other render key and not this one, so
    // every lit button, every emptied charger panel and every toggled func_wall
    // in the GoldSrc corpus stayed on its base texture forever.
    //
    // Bounded rather than written raw: GoldSrc only ever uses 0 or 1 here, and a
    // WriteByte of an out-of-range float wraps rather than clamps (the
    // sv_breakable.qc lesson from PATCH 156).
    WriteByte(MSG_ENTITY, bound(0, rint(self.frame), 255));
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
    // Contents override.  A negative .skin turns a SOLID_BSP brush into a volume
    // of that content instead of a wall — FTE's "movable pool of water", which
    // is what func_water uses (-3 water / -4 slime / -5 lava).  It HAS to reach
    // the client: the CSQC replica is made SOLID_BSP from the byte above, and a
    // SOLID_BSP brush without the override is a wall.  Client-side prediction
    // would then collide with water the server lets you swim through, which is
    // the rubberbanding wire_nonsolid was added to kill in the first place.
    // Sent as the magnitude; 0 means "no override".
    WriteByte(MSG_ENTITY, (self.skin < 0) ? bound(0, 0 - self.skin, 255) : 0);

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
        //   - door_movement_done = 1 → ONE_MOVEMENT exhausted.
        //   - door_has_master        → the door's `master` multisource may
        //                              reject the press, and its state is
        //                              dynamic and not networked, so never
        //                              predict those.  A round-trip of
        //                              latency beats predicting an open the
        //                              server then refuses.
        //
        // This used to also block on `spawnflags & 2` (the mod-invented
        // DOOR_USE_ABLE gate).  That gate is gone from door_use, and while
        // it existed it silently disabled prediction for EVERY GoldSrc door
        // — including the rotating ones, which opened fine but always a
        // full RTT late.  NO_TRIGGER (2048) gates target activation, which
        // CSQC doesn't predict, so it's intentionally not folded in.
        float predict_block = 0;
        if (self.brush_type == BRUSH_TYPE_DOOR)
        {
            if (self.door_movement_done)
                predict_block = 1;
            if (self.door_has_master)
                predict_block = 1;
            // GoldSrc door that refuses direct +use: never predict an open
            // the server is going to reject.
            if (!self.door_player_usable)
                predict_block = 1;
        }
        // Buttons gained a `master` gate too (sv_buttons.qc button_fire).
        // Same reasoning as the door case: multisource state is dynamic and
        // not networked, so a mastered button must never be predicted.
        else if (self.brush_type == BRUSH_TYPE_BUTTON)
        {
            if (self.door_has_master)
                predict_block = 1;
        }
        WriteByte(MSG_ENTITY, predict_block);
        // TOGGLE (bit 32).  A door parked at TOP closes on a re-press ONLY when
        // TOGGLE is set: Door_ActivateSingle (sv_doors.qc:1063) and rotdoor_use
        // (sv_doors_rotating.qc:906) both refuse otherwise, and a `wait -1` door
        // never closes on its own timer either (rotdoor_hit_top:696).  Without
        // this byte CSQC predicted the close on EVERY door — the brush snapped a
        // few degrees shut, froze on the predraw's 0.05s lookahead cap with no
        // corrective snapshot coming (a refused press dirties no SendFlags), and
        // kept a live avelocity on the rotating-brush list so pmove shoved anyone
        // who walked into it.
        // Measured on th_ep1_01: of 16 func_door_rotating, 12 are `wait -1` and
        // NONE set TOGGLE — and three of those twelve do not carry the "One Way"
        // flag either, so gating on One Way (16, HL SF_DOOR_ONEWAY, a swing
        // DIRECTION hint — doors.cpp:590) would have missed them.
        // Buttons never write .door_flags, so this reads 0 for them, which is
        // what CSQC wants: it already refuses to close a button from TOP.
        WriteByte(MSG_ENTITY, (self.door_flags & 32) ? 1 : 0);
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
    if (Brush_IsBreakableClass(self))
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

    // Bit 0 — broken flag.  func_breakable flips this when destroyed. Client
    // uses it to toggle drawmask / solid so the brush cleanly reappears
    // on round restart without relying on engine to re-send after a
    // SendEntity = __NULL__ transition.
    //
    // Bit 1 — BREAKABLE_INSTANT_CROWBAR (GoldSrc SF_BREAK_CROWBAR).  The client
    // needs this, and the lack of it made the flag DEAD: sv_trust_clientbreak
    // defaults to 1, so W_ApplyDamage skips its own func_breakable damage and
    // the brush's HP comes entirely from the client's breakclaim — which had no
    // idea the brush was crowbar-sensitive and always claimed the flat weapon
    // damage.  The server-side `deal = 9999` in every melee weapon was being
    // discarded before it reached the brush, so HL's instant crowbar break has
    // never actually worked here.
    //
    // Folded into the existing byte rather than adding one: no wire growth.
    WriteByte(MSG_ENTITY, (self.breakable_broken ? 1 : 0)
                        | ((self.spawnflags & BREAKABLE_INSTANT_CROWBAR) ? 2 : 0));

    return TRUE;
};

// Re-link a brush entity whose .angles changed AFTER setmodel().
//
// GoldSrc overloads `angles` on a mover to mean its MOVEMENT DIRECTION, not a
// rotation of the geometry, so SetMovedir() converts it to .movedir and then zeroes
// .angles.  The trouble is ordering: SV_InitReplicatedSolidBrush() below calls
// setmodel(), which links the entity into the world THERE AND THEN using whatever
// .angles currently holds - and the movedir conversion runs afterwards.
//
// For SOLID_BSP, World_LinkEdict expands a rotated entity's AABB by taking the world
// min/max of all eight box corners rotated ABOUT THE ENTITY ORIGIN.  An inline brush
// model's origin is (0,0,0) while its geometry sits wherever the mapper drew it, so
// for hl_c01_a1's door "doors" - box x[296,328] y[236,396] z[-240,-176], angles
// "90 0 0" - the link produced a box rotated about a point ~400 units outside it,
// i.e. in completely the wrong part of the map.  FindTouchedLeafs derives the PVS
// info from that same box, so the server never considered the door visible to anyone
// and CSQC never received it.  Clearing .angles a few lines later does not help:
// nothing re-links, so the stale box survives.
//
// The result is a mover that is invisible until the first time it MOVES, because
// moving calls setorigin() and that finally re-links it with the corrected angles.
// Doors with DOOR_START_OPEN looked fine all along - they setorigin() at spawn.
//
// setorigin() to the current origin is the cheap, idiomatic way to force the relink.
void() BrushSync_RelinkAngles =
{
    // sv_debug_brushlink 1 prints the box before/after, which is how this bug was
    // confirmed: a wrong box is centred near (0,0,0) instead of wrapping the brush.
    if (cvar("sv_debug_brushlink"))
    {
        // %v per vector, not %.0f per component: fteqcc caps varargs at 8, and
        // overflowing it silently prints garbage rather than erroring.
        vector before_mn = self.absmin, before_mx = self.absmax;
        setorigin(self, self.origin);
        if (before_mn != self.absmin || before_mx != self.absmax)
            dprint(sprintf("[brushlink] %s \"%s\" %s BEFORE %v .. %v  AFTER %v .. %v\n",
                self.classname, self.targetname, self.model,
                before_mn, before_mx, self.absmin, self.absmax));
        return;
    }
    setorigin(self, self.origin);
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
    // CFuncWall::Spawn opens with `pev->angles = g_vecZero;` (bmodels.cpp:67) and
    // that line is load-bearing, not tidiness: a func_wall never rotates, mappers
    // routinely leave a stray `angles` on brushwork, and a GoldSrc submodel with no
    // ORIGIN brush carries ABSOLUTE bounds with .origin '0 0 0' - so World_LinkEdict
    // rotates its box about the WORLD origin and the brush is drawn and collided
    // hundreds of units from where it belongs.  Same failure the DONT_MOVE button had
    // (sv_buttons.qc), and the same idiom func_wall_toggle already carries below.
    // 53 func_wall in the corpus carry a non-zero angles key with no origin brush.
    self.angles = '0 0 0';

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
};

// ---------------------------------------------------------------------------
//  func_wall_toggle — GoldSrc / Sven Co-op
// ---------------------------------------------------------------------------
// A func_wall that flips between VISIBLE+SOLID and INVISIBLE+NON-SOLID when
// used.  Sven leans on it heavily for puzzle geometry, one-way barriers and
// doors-that-are-not-doors; pizza_ya_san1 alone places 67 of them.
//
// BOTH halves of the state have to reach the client, and they travel by
// different routes through solid_brush_SendEntity:
//   visibility -> EF_NODRAW in self.effects, which the send function already
//                 ships (WriteShort of self.effects) and CSQC hands straight
//                 to addentity().  Same show/hide idiom as env_sprite.
//   solidity   -> self.solid, which the send function converts into the
//                 wire_nonsolid bit so CSQC's pmove stops colliding too.
//                 Without that half the client keeps walking into a wall the
//                 server has already made pass-through, and the resulting
//                 reconciliation reads as rubberbanding.
//
// SendFlags = -1 rather than |= 1: across a toggle the delta can look
// unchanged to the engine and the snapshot then never fires, leaving the
// client on the stale state.  Same trap documented at sv_breakable.qc:549.
const float FWT_START_INVISIBLE = 1;   // Sven/GoldSrc flag 1
const float FWT_USE_ANGLES      = 2;   // Sven flag 2 — honour Pitch Yaw Roll

// TWO different things want EF_NODRAW on this class and only one of them is
// the toggle.  BrushSync_ApplyRenderKeys sets the bit to express GoldSrc's
// "renderamt 0 on a non-Normal rendermode means invisible", because .alpha
// cannot carry a zero through FTE (see BrushSync_SetAlpha).  The toggle then
// sets and clears the same bit for its own, unrelated reason — and _show
// cleared it unconditionally, wiping the render-key answer the moment the
// brush spawned visible.
//
// pizza_ya_san1's `wlt_komugiarea` is the case: rendermode 5 (additive) with
// no renderamt at all, the standard idiom for an invisible-but-solid barrier.
// ApplyRenderKeys correctly marked it NODRAW; func_wall_toggle then spawned it
// "shown", stripped the bit, and left .alpha at 1 with SOLIDBRUSH_EF_ADDITIVE
// still set — so the client drew a fully opaque additive slab, the single most
// visible thing it could have produced.  CSQC's fx_hide guard could not save
// it either: that tests alpha <= 0, and alpha is deliberately 1 here.
//
// So latch what the render keys decided and let the toggle own only its own
// half.  Anything the keys hid stays hidden in BOTH toggle states; it is still
// solid when shown, which is the entire point of the idiom.
.float fwt_keys_nodraw;

void() func_wall_toggle_show =
{
    self.solid   = SOLID_BSP;
    if (self.fwt_keys_nodraw)
        self.effects = self.effects | EF_NODRAW;
    else
        self.effects = self.effects - (self.effects & EF_NODRAW);
    setorigin(self, self.origin);   // relink so the restored solidity takes effect
    self.SendFlags = -1;
};

void() func_wall_toggle_hide =
{
    self.solid   = SOLID_NOT;
    self.effects = self.effects | EF_NODRAW;
    setorigin(self, self.origin);
    self.SendFlags = -1;
};

void() func_wall_toggle_use =
{
    if (self.solid == SOLID_NOT)
        func_wall_toggle_show();
    else
        func_wall_toggle_hide();
};

/*QUAKED func_wall_toggle (.5 .5 .5) ? START_INVISIBLE USE_ANGLES
A func_wall that toggles between visible+solid and invisible+non-solid.
Fire its targetname to flip it.  While invisible it is fully absent: no
collision, nothing drawn.

"targetname"    fire this to toggle
"rendermode"    "renderamt" "rendercolor" "renderfx"  as func_wall
1 = Starts Invisible
2 = Use Angles (needs an origin brush; without one GoldSrc picks world origin)
*/
void() func_wall_toggle =
{
    // GoldSrc ignores the angles key on a func_wall unless flag 2 asks for it,
    // and maps routinely leave a stray non-zero "angles" on brushes that must
    // NOT rotate.  Clear it before setmodel so we match that behaviour instead
    // of silently rotating brushwork the original engine left alone.
    if (!(self.spawnflags & FWT_USE_ANGLES))
        self.angles = '0 0 0';

    SV_InitReplicatedSolidBrush();
    if (wasfreed(self))         // init removes brushes that have no model
        return;

    // Read it BEFORE the first show/hide, which is the only place it can be
    // read from: SV_InitReplicatedSolidBrush has just run the render keys.
    self.fwt_keys_nodraw = (self.effects & EF_NODRAW) ? TRUE : FALSE;

    self.brush_type = BRUSH_TYPE_STATIC;
    self.use = func_wall_toggle_use;

    if (self.spawnflags & FWT_START_INVISIBLE)
        func_wall_toggle_hide();
    else
        func_wall_toggle_show();
};
