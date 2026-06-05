//
//  sv_cycler_sprite.qc  –  cycler_sprite  (HL/GoldSrc point entity)
//
//  Animated point-entity sprite billboard.  Auto-cycles frames at
//  `framerate` Hz; .use freezes / resumes the animation; while
//  frozen each bullet hit advances one frame (HL CCyclerSprite
//  semantics — solid bbox so bullets / players touch it, but it
//  takes no real damage thanks to a resurrecting on_damaged).
//
//  Common decorative use:  a static prop where the mapper wants a
//  sprite (smoke column, light glow, decorative HL .spr) without
//  resorting to MDL imports.  Mappers also use it as a poor-man's
//  "model" placeholder by setting `model` to a sprite path.
//
//  Keys:
//    "model"        sprite path (e.g. "sprites/tele1.spr").  Required.
//    "framerate"    auto-step rate, frames/sec.  Default 10.
//    "rendermode"   0..5 GoldSrc render mode.
//    "renderamt"    0..255 fx-amount (alpha for non-Normal modes).
//    "rendercolor"  "R G B" 0..255 tint.
//    "angles"       Pitch Yaw Roll — only Roll (X) used; sprite
//                   always faces the camera so pitch/yaw are ignored.
//    "targetname"   identifier for trigger chains (optional).
//

// Forward decl — defined in server/sv_brushsync.qc (compiles before
// this file in sv_progs.src).  Translates rendermode / renderamt /
// rendercolor into FTE's alpha / colormod / effects fields.
void() BrushSync_ApplyRenderKeys;

// Mapper-set BSP key — declared so the entity-block parser populates
// it on the spawn entity.  Not part of the engine's default field
// set, so we have to claim a slot ourselves.
.float framerate;

// Per-entity state.  cs_framerate caches the mapper-set framerate
// (default-resolved at spawn) so .use's resume path doesn't have to
// re-read the field; cs_frozen is the .use toggle.
.float cs_framerate;
.float cs_frozen;

void() cycler_sprite_think;

// Per-frame callback when frozen and bullets land — advance one
// frame, restore health so we never die.  on_damaged in W_ApplyDamage
// fires when post-damage health > 0; we keep health at 9999 so even
// a single AWP body-shot doesn't drop us into the on_killed branch.
void() cycler_sprite_damaged =
{
    if (self.cs_frozen)
        self.frame = self.frame + 1;
    self.health = 9999;
};

// Belt-and-suspenders: if a single hit DID overflow into on_killed
// (e.g. an env_explosion magnitude > 9999), resurrect.  Same
// frame-step + health reset.  Match HL's "cycler never actually
// dies" promise.
void() cycler_sprite_killed =
{
    if (self.cs_frozen)
        self.frame = self.frame + 1;
    self.health     = 9999;
    self.takedamage = DAMAGE_YES;     // engine clears this on death
};

void() cycler_sprite_think =
{
    if (self.cs_frozen) return;
    self.frame = self.frame + 1;
    // FTE wraps sprite frame indices automatically; no max-frame
    // bookkeeping needed.
    self.nextthink = time + (1.0 / self.cs_framerate);
};

void() cycler_sprite_use =
{
    self.cs_frozen = self.cs_frozen ? 0 : 1;
    if (self.cs_frozen)
    {
        // Halt the auto-step; the entity stays solid + takes hits,
        // each hit advances one frame via cycler_sprite_damaged.
        self.think     = __NULL__;
        self.nextthink = 0;
    }
    else
    {
        // Resume auto-cycling at the cached framerate.
        self.think     = cycler_sprite_think;
        self.nextthink = time + (1.0 / self.cs_framerate);
    }
};

/*QUAKED cycler_sprite (.5 .5 .5) (-16 -16 -16) (16 16 16)
HL/GoldSrc-style animated sprite point entity.  Auto-cycles `frame`
at `framerate` Hz; .use toggles between auto-cycle and frozen-with-
shoot-to-step.

"model"        sprite path (e.g. "sprites/tele1.spr").
"framerate"    frames per second (default 10).
"rendermode"   0=Normal 1=Color 2=Texture 3=Glow 4=Solid 5=Additive.
"renderamt"    0..255 alpha for non-Normal modes.
"rendercolor"  "R G B" 0..255 tint.
"targetname"   trigger identifier.
*/
void() cycler_sprite =
{
    if (!self.model || self.model == "")
    {
        dprint("cycler_sprite: no model set, removing\n");
        remove(self);
        return;
    }

    precache_model(self.model);
    setmodel(self, self.model);
    // setmodel adopts the sprite's bounds — but sprites typically
    // report tiny mins/maxs (or zero) which make the bbox useless
    // for hitscan touch.  Force a 32 qu cube hitbox like HL's
    // CCyclerSprite::Spawn does (UTIL_SetSize(-32,-32,-32 .. +32)).
    setsize(self, '-16 -16 -16', '16 16 16');

    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_BBOX;        // bullets + players touch it

    self.cs_framerate = self.framerate;
    if (self.cs_framerate <= 0) self.cs_framerate = 10;
    self.framerate    = self.cs_framerate;   // engine reads this for any auto-frame logic

    self.frame    = 0;
    self.cs_frozen = 0;

    self.use         = cycler_sprite_use;

    // takedamage + on_damaged + on_killed give the
    // "shoot-to-step-while-frozen" behaviour without ever actually
    // killing the entity.  health 9999 absorbs realistic per-shot
    // damage; the on_killed fallback covers the explosion-radius
    // edge case.
    self.takedamage  = DAMAGE_YES;
    self.health      = 9999;
    self.on_damaged  = cycler_sprite_damaged;
    self.on_killed   = cycler_sprite_killed;

    // GoldSrc render keys → FTE alpha / colormod / effects.  Same
    // helper the brushsync entities use so rendermode 1..5 produce
    // the visible behaviour mappers expect.
    BrushSync_ApplyRenderKeys();

    self.think     = cycler_sprite_think;
    self.nextthink = time + (1.0 / self.cs_framerate);
};
