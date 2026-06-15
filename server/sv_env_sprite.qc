//
//  sv_env_sprite.qc  –  env_sprite  (HL/GoldSrc point entity)
//
//  Sprite (or MDL) placed in the world.  Visibility is gated by
//  the START_ON / PLAY_ONCE spawnflags and toggled via .use.
//  Unnamed env_sprites are always-on (HL default — no targetname
//  means no .use binding).
//
//  Keys (HL parity):
//    "model"        SPR or MDL path — required.
//    "framerate"    frames/sec for SPR cycling; speed scalar for MDL
//                   animation playback (1.0 = normal).
//    "scale"        sprite size multiplier (no effect on MDL).
//    "sequence"     MDL sequence index (no effect on SPR).
//    "angles"       Pitch Yaw Roll.
//    "rendermode"   0..5 GoldSrc render mode.
//    "renderamt"    0..255 fx-amount.
//    "rendercolor"  "R G B" 0..255 tint.
//    "targetname"   trigger identifier — without this the sprite is
//                   always on regardless of START_ON.
//
//  Spawnflags (HL bit layout):
//    1   SF_SPRITE_START_ON   visible at map start
//    2   SF_SPRITE_PLAY_ONCE  single-shot — visible while triggered,
//                             hidden again after the play window.
//                             Default play duration = 1 s (tunable
//                             via `wait` map key).
//
//  Behaviour scope (compatibility, not bug-for-bug):
//    - Visibility toggled by setting / clearing EF_NODRAW.  No
//      tear-down on hide; entity persists in PVS, ready to re-show.
//    - PLAY_ONCE uses a fixed-duration auto-hide think.  HL ties
//      the duration to the SPR's frame count + framerate; we don't
//      have a portable QC API for the frame count, so we expose
//      `wait` (seconds) as the play duration override.
//

void() BrushSync_ApplyRenderKeys;        // sv_brushsync.qc

// HL sprite flags.
const float SF_SPRITE_START_ON  = 1;
const float SF_SPRITE_PLAY_ONCE = 2;

// `framerate` and `wait` are reused from elsewhere; declare if not
// already in scope.  `.float framerate` is declared in sv_cycler_sprite.qc
// (compiles before us); `.float wait` is declared in sv_doors.qc.
// .scale is an engine field for visual scaling.

.float es_visible;       // current on/off state — 1 = drawing
.float sequence;         // MDL animation index — declared also in
                          // sv_cycler.qc; duplicate decls of matching
                          // type share storage in QC

void() env_sprite_hide =
{
    self.effects |= EF_NODRAW;
    self.es_visible = 0;
    self.think     = __NULL__;
    self.nextthink = 0;
};

void() env_sprite_show =
{
    self.effects = self.effects - (self.effects & EF_NODRAW);
    self.es_visible = 1;
};

void() env_sprite_use =
{
    if (self.spawnflags & SF_SPRITE_PLAY_ONCE)
    {
        // Single-shot — fire, schedule auto-hide.  If already
        // visible (a retrigger arrived mid-play), HL hides
        // immediately — match that behaviour.
        if (self.es_visible)
        {
            env_sprite_hide();
            return;
        }
        env_sprite_show();
        float play_dur = self.wait;
        if (play_dur <= 0) play_dur = 1.0;
        self.think     = env_sprite_hide;
        self.nextthink = time + play_dur;
        return;
    }

    // Toggle mode — flip visibility, stay there until next trigger.
    if (self.es_visible)
        env_sprite_hide();
    else
        env_sprite_show();
};

/*QUAKED env_sprite (.5 .5 .5) (-8 -8 -8) (8 8 8) START_ON PLAY_ONCE
HL/GoldSrc-style sprite or model display point entity.  Visibility
gated by spawnflags and toggled via .use.

"model"        SPR or MDL path.
"framerate"    sprite frames/sec, or MDL playback speed scalar.
"scale"        sprite size multiplier.
"sequence"     MDL animation index.
"angles"       Pitch Yaw Roll.
"rendermode"   0..5 GoldSrc render mode.
"renderamt"    0..255 fx-amount.
"rendercolor"  "R G B" 0..255 tint.
"wait"         PLAY_ONCE auto-hide duration in seconds (default 1).
"targetname"   trigger identifier (unnamed = always on).
*/
void() env_sprite =
{
    if (!self.model || self.model == "")
    {
        dprint("env_sprite: no model set, removing\n");
        remove(self);
        return;
    }

    // nettest: a Source sprite is a .vmt MATERIAL, not a model. Feeding it to
    // precache_model/setmodel loads it as a model (mod_dummy) and the sprite
    // render path then crashes on the dummy. FTE can't render a Source .vmt
    // sprite, so drop the entity (the glow is simply absent) rather than crash.
    if (substring(self.model, strlen(self.model) - 4, 4) == ".vmt")
    {
        dprint(sprintf("env_sprite: refusing Source .vmt sprite '%s'\n", self.model));
        remove(self);
        return;
    }

    precache_model(self.model);
    setmodel(self, self.model);

    // Sprites have no collision in HL — purely visual.  MDL
    // case uses the same: env_sprite is non-interactive scenery.
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    setsize(self, '0 0 0', '0 0 0');

    if (self.framerate > 0)
        self.framerate = self.framerate;        // engine reads this for auto-cycling
    if (self.frame == 0 && self.sequence > 0)
        self.frame = self.sequence;

    // Default scale to 1.0 if not set so the sprite renders at
    // its authored size.  HL treats 0 as "default" too.
    if (self.scale == 0)
        self.scale = 1.0;

    BrushSync_ApplyRenderKeys();

    self.use = env_sprite_use;

    // Initial visibility — unnamed sprites are always on; named
    // ones honour the START_ON flag.
    float start_on;
    if (self.targetname == "")
        start_on = 1;
    else
        start_on = (self.spawnflags & SF_SPRITE_START_ON) ? 1 : 0;

    if (start_on)
        env_sprite_show();
    else
        env_sprite_hide();
};
