//
// sv_env_laser.qc — HL/GoldSrc env_laser point entity
//
// Derivative of env_beam: a laser that always starts at the entity's
// own origin, traces to the LaserTarget (stopping at the first solid),
// and damages whatever it hits.  Reuses the env_beam CSQC entity
// type (CSQC_ENT_ENV_BEAM) so the client-side ribbon renderer is
// shared — env_laser just sets its end-sprite modelindex (which
// env_beam leaves at 0) and ticks its endpoints every 0.1s.
//
// Keys (driven by nettest.fgd):
//   LaserTarget — targetname of the aim target (info_target,
//                 func_train, etc.).  Required for the laser to fire.
//   renderamt   — brightness 0..255 (alpha).
//   rendercolor — beam RGB.
//   BoltWidth   — width in 0.1 units.
//   NoiseAmplitude — path jitter amplitude.
//   texture     — beam sprite path.
//   EndSprite   — sprite drawn at the hit point (additive billboard).
//   TextureScroll — scroll speed 0..100.
//   framestart  — initial frame.
//   damage      — DPS to whatever the trace hits.
//
// Spawnflags:
//     1  START_ON      — fire at map load.
//    16  START_SPARKS  — sparks at the start point on activation.
//    32  END_SPARKS    — sparks at the end point on activation.
//    64  DECAL_END     — scorch decal at the hit point on activation.
//

const float ELASER_START_ON     = 1;
const float ELASER_START_SPARKS = 16;
const float ELASER_END_SPARKS   = 32;
const float ELASER_DECAL_END    = 64;

// Network flag bits (must match cl_env_beam.qc).  env_laser reuses the
// env_beam wire format; spawnflag bits are translated to netflags here.
const float ELASER_NET_ACTIVE       = 1;
const float ELASER_NET_RING         = 2;   // unused for laser; keep bit so
                                            // both entity types share the
                                            // CSQC enum
const float ELASER_NET_SHADE_START  = 4;
const float ELASER_NET_SHADE_END    = 8;
const float ELASER_NET_START_SPARKS = 16;
const float ELASER_NET_END_SPARKS   = 32;

// Mapper keys.  Most overlap with env_beam (declared there with
// matching types so a single .field declaration covers both
// entities).  Only the LaserTarget + EndSprite keys are unique to
// env_laser.
.string LaserTarget;
.string EndSprite;

// Forward decls — env_beam declarations cover most of the rest.
// Shared SendEntity helper hoists into env_beam scope; we just set
// the right fields.

void() EnvLaser_Tick;

// Resolve the aim target via find-by-name.  HL random-pick behaviour
// when multiple entities share the name kicks in EVERY tick (every
// 0.1s) — the spec calls this out.  We borrow EnvBeam_FindByName
// from sv_env_beam.qc which already implements the random-pick path.
entity(string name) EnvBeam_FindByName;

// Per-tick aim trace.  Always starts at self.origin (HL: env_laser
// fires from its own origin, never from another entity).  End point
// is the LaserTarget's origin clamped by traceline — the laser stops
// at the first solid hit.  Damage is applied to trace_ent.
void() EnvLaser_AimAndDamage =
{
    // Resolve the aim point.  Re-evaluated every tick so the laser
    // tracks moving targets (func_train + spec note about 0.1s
    // update cadence).
    entity tgt = EnvBeam_FindByName(self.LaserTarget);
    vector aim;
    if (tgt && tgt != world)
        aim = tgt.origin;
    else
        aim = self.origin + '0 0 -64';   // straight down fallback

    // Trace from self.origin to the aim point.  Stops at first solid;
    // trace_endpos is the visible end of the beam.  MOVE_NORMAL so the
    // laser collides with players + brushes + props (HL spec note:
    // "env_laser's beam will be blocked by the player, NPCs, and
    // other entities").
    traceline(self.origin, aim, MOVE_NORMAL, self);

    self.ebeam_start_pos = self.origin;
    self.ebeam_end_pos   = trace_endpos;

    // Apply damage to whatever the trace hit (player / npc / breakable).
    if (self.damage > 0 && trace_ent && trace_ent != world
        && trace_ent.takedamage != DAMAGE_NO)
    {
        trace_ent.health -= self.damage * 0.1;     // per-tick at 10Hz
    }

    // DECAL_END handling: spawnflag bit is translated to an
    // EBEAM_NET_DECAL_END netflag in the env_beam wire format
    // (set by EnvBeam_SendEntity when reading the spawnflag).
    // CSQC sees the rising-edge active+decal_end combination and
    // spawns the scorch decal locally — no separate server event
    // required since the client already knows the end position.
};

// Forward decls from sv_env_beam.qc for the shared SendEntity path
// + dirty marker.  Both functions live in the env_beam compilation
// unit which is compiled before us.
float(entity ent, float changedflags) EnvBeam_SendEntity;
void()  EnvBeam_MarkDirty;

void() EnvLaser_Tick =
{
    if (!self.ebeam_active)
        return;

    vector old_s = self.ebeam_start_pos;
    vector old_e = self.ebeam_end_pos;
    EnvLaser_AimAndDamage();
    if (old_s != self.ebeam_start_pos || old_e != self.ebeam_end_pos)
        EnvBeam_MarkDirty();

    self.nextthink = time + 0.1;
};

void() EnvLaser_Activate =
{
    self.ebeam_active = 1;
    EnvLaser_AimAndDamage();
    EnvBeam_MarkDirty();

    self.think     = EnvLaser_Tick;
    self.nextthink = time + 0.1;
};

void() EnvLaser_Deactivate =
{
    self.ebeam_active = 0;
    self.nextthink    = 0;
    EnvBeam_MarkDirty();
};

void() EnvLaser_Use =
{
    if (self.ebeam_active)
        EnvLaser_Deactivate();
    else
        EnvLaser_Activate();
};

/*QUAKED env_laser (.4 .8 .8) (-4 -4 -4) (4 4 4) START_ON x x x START_SPARKS END_SPARKS DECAL_END
HL/GoldSrc-style laser beam.  Always fires from self.origin toward
the LaserTarget entity, blocked by the first solid in the way.

"LaserTarget"     Aim target's targetname.
"renderamt"       Brightness 0..255 (alpha).
"rendercolor"     Beam RGB.
"BoltWidth"       Width in 0.1 units.
"NoiseAmplitude"  Path jitter amplitude 0..255.
"texture"         Beam sprite path.
"EndSprite"       Sprite drawn at the hit point (additive billboard).
"TextureScroll"   Scroll speed 0..100.
"framestart"      Initial animation frame.
"damage"          DPS to whatever the trace hits.

START_ON       Fire at map load.
START_SPARKS   Emit sparks at the start point on activation.
END_SPARKS     Emit sparks at the end point on activation.
DECAL_END      Spawn a scorch decal at the hit point on activation.
*/
void() env_laser =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = EnvLaser_Use;

    // Defaults — match env_beam's seeds.
    if (self.renderamt == 0)         self.renderamt = 200;
    if (self.rendercolor == '0 0 0') self.rendercolor = '255 50 50';
    if (self.BoltWidth == 0)         self.BoltWidth = 16;

    // Precache beam sprite + optional end sprite.
    if (self.texture != "")
    {
        precache_model(self.texture);
        self.ebeam_sprite_index = getmodelindex(self.texture);
    }
    if (self.EndSprite != "")
    {
        precache_model(self.EndSprite);
        self.ebeam_end_sprite_index = getmodelindex(self.EndSprite);
    }

    // Always-broadcast SendEntity, shared with env_beam.
    self.pvsflags   = PVSF_USEPHS | PVSF_NOREMOVE;
    self.SendEntity = EnvBeam_SendEntity;
    self.SendFlags  = 1;

    self.ebeam_start_pos = self.origin;
    self.ebeam_end_pos   = self.origin;

    // START_ON deferred 0.2s so all entities (LaserTarget) are linked.
    if (self.spawnflags & ELASER_START_ON)
    {
        self.think     = EnvLaser_Activate;
        self.nextthink = time + 0.2;
    }
};
