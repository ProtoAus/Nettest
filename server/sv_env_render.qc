//
//  sv_env_render.qc  –  env_render  ("Render Controls", GoldSrc / Sven Co-op)
//
//  A point entity that, when triggered, copies its OWN render keys onto every
//  entity named by its `target`.  This is how HL maps swap an object between
//  visible and invisible states at runtime without moving or removing it.
//
//  Four spawnflags each SUPPRESS one of the four keys, so a mapper can (say)
//  change only the alpha and leave rendermode alone.  All four clear means
//  "apply everything", which is by far the most common authoring.
//
//  Worked example — hl_c01_a1's microwave stew, which is what prompted this
//  file.  Three brushes model one bowl:
//      stew_1   func_rotating,  rendermode absent      -> visible at map start
//      stew2_1  func_rotating + func_wall (rendermode 2, no renderamt)
//                                                      -> invisible at start
//  and multi_manager `microwavepopmm1_1` fires both of these on the same tick:
//      renderstewoff  env_render rendermode 2  -> target stew_1   (hide it)
//      renderstewon   env_render renderamt 255 -> target stew2_1  (show it)
//  i.e. the intact bowl is swapped for the exploded one.  With env_render
//  missing entirely, neither half ran: the intact stew never disappeared.
//
//  Measured on the 121-map Sven corpus: 656 env_renders across 57 maps.
//
//  Sven adds a fifth flag, AUTO_APPLY (16), which ignores `target` and hits
//  every entity within `armorvalue` units instead ("radius (0 disables)" in
//  sven-coop.fgd).  242 of the 656 carry an armorvalue.
//

const float ENVR_NO_RENDERFX    = 1;
const float ENVR_NO_RENDERAMT   = 2;
const float ENVR_NO_RENDERMODE  = 4;
const float ENVR_NO_RENDERCOLOR = 8;
const float ENVR_AUTO_APPLY     = 16;   // Sven: radius sweep instead of target

// Push one env_render's authored keys onto `targ` and re-derive its
// alpha / effects / colormod from them.
//
// The re-derive has to CLEAR before it applies, because
// BrushSync_ApplyRenderKeys ORs its effect bits (it is written for spawn time,
// where the entity is fresh).  Running it twice on the same entity would
// otherwise accumulate: a brush switched from Additive to Normal would keep
// its additive bit forever, and one switched from an invisible mode back to a
// visible one would keep EF_NODRAW and stay hidden.  Clearing exactly the
// three bits this translation owns leaves anything else on .effects
// (EF_NOSHADOW, mod-specific bits) untouched.
void(entity src, entity targ) EnvRender_ApplyTo =
{
    entity oldself = self;
    self = targ;

    if (!(src.spawnflags & ENVR_NO_RENDERMODE))  self.rendermode  = src.rendermode;
    if (!(src.spawnflags & ENVR_NO_RENDERAMT))   self.renderamt   = src.renderamt;
    if (!(src.spawnflags & ENVR_NO_RENDERCOLOR)) self.rendercolor = src.rendercolor;
    if (!(src.spawnflags & ENVR_NO_RENDERFX))    self.renderfx    = src.renderfx;

    self.effects  = self.effects
                  - (self.effects & (EF_NODRAW
                                     | SOLIDBRUSH_EF_ADDITIVE
                                     | SOLIDBRUSH_EF_FULLBRIGHT));
    self.colormod = '1 1 1';
    self.alpha    = 1;
    BrushSync_ApplyRenderKeys();

    // SendFlags = -1, not |= 1: across a pure render-key change the delta can
    // look unchanged to the engine and the snapshot then never fires, leaving
    // the client on the stale appearance.  Same trap as func_wall_toggle
    // (sv_brushsync.qc) and func_breakable.
    if (self.SendEntity)
        self.SendFlags = -1;

    if (cvar("sv_debug_use"))
        dprint(sprintf("[env_render] \"%s\" -> %s(\"%s\") mode=%g amt=%g fx=%g eff=%g\n",
                       src.targetname, self.classname, self.targetname,
                       self.rendermode, self.renderamt, self.renderfx, self.effects));

    self = oldself;
};

void() env_render_use =
{
    if (self.spawnflags & ENVR_AUTO_APPLY)
    {
        // Sven's radius mode.  armorvalue is documented as "radius
        // (0 disables)" — a zero radius means the flag is inert rather than
        // meaning "infinite", so bail rather than repainting the whole map.
        if (self.armorvalue <= 0)
            return;
        entity e = findradius(self.origin, self.armorvalue);
        entity nxt;
        while (e)
        {
            nxt = e.chain;             // ApplyTo may dirty fields; cache first
            if (e != self && e != world)
                EnvRender_ApplyTo(self, e);
            e = nxt;
        }
        return;
    }

    if (self.target == "" || self.target == __NULL__)
        return;

    entity t = find(world, targetname, self.target);
    entity tnxt;
    while (t)
    {
        tnxt = find(t, targetname, self.target);
        if (t != self)
            EnvRender_ApplyTo(self, t);
        t = tnxt;
    }
};

/*QUAKED env_render (.5 .5 0) (-8 -8 -8) (8 8 8) NO_RENDERFX NO_RENDERAMT NO_RENDERMODE NO_RENDERCOLOR AUTO_APPLY
Copies its own render keys onto every entity named by "target" when triggered.
Each spawnflag suppresses one key so a mapper can change only what they mean to.

"target"      entities to repaint (all matches, not just the first)
"rendermode"  0=normal 1=color 2=texture 3=glow 4=solid 5=additive
"renderamt"   0..255 alpha for the translucent modes.  0 = invisible.
"rendercolor" "R G B", 0..255 each
"renderfx"    0..16 kRenderFx animation enum
"armorvalue"  AUTO_APPLY radius in units (Sven extension; 0 disables)

NO_RENDERFX    leave the target's renderfx alone
NO_RENDERAMT   leave the target's renderamt alone
NO_RENDERMODE  leave the target's rendermode alone
NO_RENDERCOLOR leave the target's rendercolor alone
AUTO_APPLY     ignore "target"; repaint everything within "armorvalue" units
*/
void() env_render =
{
    self.use      = env_render_use;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};

// env_render_individual is the per-player variant: same key set, but the
// repaint is meant to be visible only to the player named by `netname`.
// Our render state is server-authoritative and shared by every client, so a
// per-player split isn't representable without a second wire path.  Applying
// it globally is the strictly-more-visible failure: the map's scripted state
// change still happens, everyone just sees it.  Silently doing nothing would
// soft-lock any map that gates progress on the swap.
void() env_render_individual =
{
    self.use      = env_render_use;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
