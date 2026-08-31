// ============================================================
//  client/cl_projectiles.qc  -  CSQC entity layer for server
//  projectiles (HL grenade, GL grenade, RPG rocket, crossbow bolt).
//
//  Server side (sv_weapons.qc projectile_SendEntity) sends each
//  projectile at sv_toss_tickrate with origin + velocity + avelocity.
//  Owner is hidden by SendEntity returning FALSE — the shooter sees
//  only their CSQC fake (per-weapon predict block). All other PVS
//  clients receive samples here and route them through the smoothing
//  helper (cl_tosssmooth.qc) so visible flight stays smooth between
//  the discrete server send ticks.
//
//  Per-projectile model + gravity are derived from the proj_type
//  byte via Projectile_TypeModel / Projectile_TypeGravity in
//  shared/sh_weapons.qc, so we don't need a per-type parser switch.
// ============================================================

.float csqc_projectile_type;
// cltime this projectile appeared.  Only used by animated-sprite types, whose
// frame is a pure function of age (Projectile_AnimateSprite) so the networked
// twin and each weapon's CSQC-local fake stay in step without extra state.
.float proj_born;
.float proj_dbg_next;       // throttle for the developer lifecycle trace below

// Predraw: extrap+smooth via cl_tosssmooth.qc, then locally spin the
// model via avelocity (server doesn't send angle updates beyond the
// initial avelocity vector).
float() CSQC_Projectile_Predraw =
{
    // Sleeping-item fast-path — same heuristic as
    // CSQC_DroppedWeapon_Predraw. Projectiles rarely settle (gravity
    // keeps grenades moving, rockets explode mid-flight) but the
    // gate is harmless: a settled grenade benefits, an in-flight
    // one fails the toss_moving check and runs the full path.
    // Animated-sprite types churn even when they are not moving, so the frame
    // walk has to happen on BOTH sides of the sleeping-item fast path below.
    Projectile_AnimateSprite(self, self.csqc_projectile_type, self.proj_born);

    if (!self.toss_moving
        && self.extrap_error_cltime == 0
        && (self.avelocity * self.avelocity) <= 1)
    {
        addentity(self);
        return PREDRAW_NEXT;
    }

    CSQC_TossPredraw(self);
    if ((self.csqc_projectile_type == PROJ_TYPE_CSHEGRENADE
         || self.csqc_projectile_type == PROJ_TYPE_CSFLASHBANG
         || self.csqc_projectile_type == PROJ_TYPE_CSSMOKEGRENADE)
        && vlen(self.avelocity) <= 0)
    {
        self.angles_x = 0;
        self.angles_z = 0;
    }
    // NOSE-OVER, or avelocity spin — never both.
    //
    // A rocket or a mortar bomb has to point along its flight path, and until
    // now nothing made it: the SERVER's per-think `angles = f(velocity)` write
    // (sh_wpn_dodmortar.qc, sh_wpn_dodat.qc) is DEAD, because DodAT_SendEntity
    // transmits type, origin, velocity and avelocity and no angles at all — and
    // these are SendEntity projectiles with no owner skip, so the CSQC copy is
    // the only thing anyone renders, the shooter included.  The client then set
    // .angles exactly once, inside the isnew branch, and no DoD projectile
    // carries an avelocity, so the line below was a no-op for them.  The bomb
    // held its launch-instant orientation for the entire arc.
    //
    // Done on the client rather than by widening the wire: the velocity is
    // already there (zero extra bandwidth), the predraw runs at RENDER rate so
    // the nose-over is smooth instead of stepping at the toss tickrate, and the
    // position beside it is extrapolated from the same anchor — so deriving the
    // orientation from the same extrapolated velocity keeps the nose consistent
    // with the arc actually being drawn.
    if (Projectile_TypeFacesVelocity(self.csqc_projectile_type) && self.toss_moving)
    {
        // Same dt cap and the same gravity * toss_gravity product
        // Toss_PredictedNow uses for the position, so nose and path agree.
        // The refresh is called explicitly rather than assumed live:
        // Toss_PredictedNow returns early when toss_last_cltime <= 0 without
        // ever reaching it, and it is a cltime-keyed no-op when it is live.
        CSQC_TossFrameCacheRefresh();
        float nose_dt = bound(0, cltime - self.toss_last_cltime, toss_frame_cache_dt_cap);
        vector nose_v = self.toss_last_velocity;
        nose_v_z -= toss_frame_cache_gravity * self.toss_gravity * nose_dt;
        if (nose_v * nose_v > 1)
            self.angles = Projectile_FlightAngles(self.csqc_projectile_type, nose_v);
    }
    else
    {
        // Avelocity-driven angle drift — frametime is the per-frame engine
        // global, so the rotation rate matches whatever the server set on
        // spawn regardless of client framerate.
        self.angles = self.angles + self.avelocity * frametime;
    }
    addentity(self);
    return PREDRAW_NEXT;
};

// Predraw for a weapon's CSQC-LOCAL fake whose model is an animated sprite.
//
// The fakes are plain drawmask entities with no predraw, which is fine for a
// static model but leaves an animated sprite frozen on frame 0.  This is the
// minimum needed to walk it: no extrapolation (a fake owns its own movement)
// and no smoothing (there is no server sample to reconcile against).
float() CSQC_FakeSpriteProj_Predraw =
{
    Projectile_AnimateSprite(self, self.csqc_projectile_type, self.proj_born);
    addentity(self);
    return PREDRAW_NEXT;
};

void(float isnew) CSQC_Projectile_Update =
{
    float ptype = readbyte();

    vector new_origin;
    new_origin_x = readcoord();
    new_origin_y = readcoord();
    new_origin_z = readcoord();

    vector new_velocity;
    new_velocity_x = readcoord();
    new_velocity_y = readcoord();
    new_velocity_z = readcoord();

    vector new_avelocity;
    new_avelocity_x = readcoord();
    new_avelocity_y = readcoord();
    new_avelocity_z = readcoord();

    // Paintball-only color suffix — must mirror projectile_SendEntity
    // in sv_weapons.qc. Read unconditionally per type so the byte
    // stream stays in sync.
    vector new_colormod = '1 1 1';
    if (ptype == PROJ_TYPE_PAINTBALL)
    {
        new_colormod_x = readbyte() * (1.0 / 255.0);
        new_colormod_y = readbyte() * (1.0 / 255.0);
        new_colormod_z = readbyte() * (1.0 / 255.0);
    }

    if (isnew)
    {
        self.classname = "csqc_projectile";
        self.solid     = SOLID_NOT;
        self.drawmask  = MASK_ENGINE;
        self.predraw   = CSQC_Projectile_Predraw;
        // Look up model from the type byte. Sized small — these are
        // ballistic, not collidable on CSQC (server is authoritative).
        string mdl = Projectile_TypeModel(ptype);
        if (mdl != "")
            setmodel(self, mdl);

        // "the grunts grenade was invisible" — the SERVER side of that report is
        // proven correct (measured: modelindex 388, live velocity, SendFlags
        // bumped every tick), so if a monster-thrown grenade still does not draw,
        // the cause is one of exactly three things and this line names which:
        //   modelindex 0  -> the model is not in the CLIENT's precache list, so
        //                    setmodel silently did nothing;
        //   mdl ""        -> the type byte did not resolve to a path;
        //   both fine     -> it is drawing, and the fault is elsewhere (scale,
        //                    origin, or it is being removed immediately).
        if (cvar("developer"))
            print(sprintf("[proj] new type=%g model=\"%s\" modelindex=%g org=%v\n",
                          ptype, mdl, self.modelindex, new_origin));
        setsize(self, '-2 -2 -2', '2 2 2');
        // Initialise angles from the current velocity direction so the
        // model points where it's flying on first appearance, before any
        // avelocity-driven rotation kicks in. Looks much better than the
        // default (0,0,0) angles for fast-moving projectiles like the
        // crossbow bolt that should align with the velocity vector.
        if (vlen(new_velocity) > 0)
            self.angles = Projectile_FlightAngles(ptype, new_velocity);
        // Paintball: shrink the snowball model so it reads as a
        // small marker round, and apply the per-shot tint.
        if (ptype == PROJ_TYPE_PAINTBALL)
        {
            self.scale    = 0.5;
            self.colormod = new_colormod;
        }

        // GoldSrc additive art.  FTE reads neither a .spr's SPR_ADDITIVE header
        // field nor a studio texture's additive flag, so the blend has to be
        // asserted here or the displacer orb draws as an opaque black square and
        // the shock bolt as a lit chrome sliver.  See Projectile_TypeIsAdditive.
        if (Projectile_TypeIsAdditive(ptype))
        {
            self.effects |= EF_ADDITIVE | EF_FULLBRIGHT;
            self.proj_born = cltime;
        }
    }

    // Always live: avelocity may change between samples (rare for
    // projectiles, but cheaper to assign than to gate). proj_type
    // isn't stored on the CSQC entity (the field is gated to SSQC and
    // the local ptype variable is enough for this update).
    self.avelocity = new_avelocity;
    self.csqc_projectile_type = ptype;
    // Only pin the frame for projectiles that HAVE one frame.  exit1.spr is a
    // 25-frame animation and this line was resetting it on every update, which
    // is why the displacer orb was a dead blob rather than a churning ball.
    // The animated ones are walked in the predraw instead.
    if (Projectile_TypeSpriteFPS(ptype) <= 0)
        self.frame = 0;

    // Birth alone does not answer "was it invisible": an entity that arrives
    // correctly and is then removed, or whose origin walks off to nowhere, looks
    // exactly like one that never drew.  Throttled to 2 Hz so a 30 s test grenade
    // produces a readable trace rather than 600 lines.
    if (cvar("developer") && cltime >= self.proj_dbg_next)
    {
        self.proj_dbg_next = cltime + 0.5;
        print(sprintf("[proj] live type=%g modelindex=%g drawmask=%g org=%v vel=%v\n",
                      ptype, self.modelindex, self.drawmask, new_origin, new_velocity));
    }

    // Route the new authoritative sample through the smoothing helper.
    // Gravity factor matches the server's .gravity for this projectile
    // type so the CSQC extrap curves the same way the server's
    // MOVETYPE_TOSS / FLYMISSILE physics propagates between sends.
    CSQC_TossSampleApply(self, new_origin, new_velocity,
                         Projectile_TypeGravity(ptype));
};

// ============================================================
//  PROJECTILE ESCORT LIGHTS
// ============================================================
//
// dynamiclight_add lasts exactly ONE FRAME, so a light that follows something
// has to be re-emitted every render frame from a walk over the entities.  That
// is the shape client/cl_c4.qc:151-178 already uses for the bomb's beacon, and
// this is the same walk for projectiles.
//
// Matching on .model rather than on a flag is deliberate: it catches BOTH the
// networked projectile (which CSQC_Projectile_Update setmodel'd from
// Projectile_TypeModel) and the shooter's own local fake, which is a different
// entity with a different classname but necessarily the same model.  Without
// that the person firing would be the only player who sees no light.
//
// Throttled by csqc_dlight_update_this_frame, the same cl_dlight_update_hz gate
// the muzzle flash uses -- these are cosmetic lights and there can be several in
// the air at once.
void() CSQC_Projectile_DrawLights =
{
    if (!csqc_dlight_update_this_frame)
        return;

    float lflags = cvar("cl_combat_light_shadows") ? 0 : PFLAGS_NOSHADOW;

    entity cur = nextent(world);
    while (cur)
    {
        // OpFor shock bolt — cyan, matching its beam recipe (particles/beams.cfg
        // rgb 30 240 250) and the muzzle flash the same shot emits, so the whole
        // weapon reads as one colour.
        if (cur.model == "sprites/muzzle_shock.spr")
            dynamiclight_add(cur.origin, 140, '0.12 0.94 0.98', 0, "", lflags);

        // RPG rocket — Half-Life's EF_LIGHT.  const.h:110 names it exactly:
        // "rocket flare glow sprite", and rpg.cpp:201 sets it in IgniteThink (so
        // it appears when the motor lights, not at launch) and rpg.cpp:304-307
        // clears it when the motor cuts out.  FTE does not implement the HL
        // effects bits, so nothing drew it and the rocket flew as a bare model
        // with only its smoke ribbon behind it.
        //
        // Both halves are here because EF_LIGHT is both: a glow SPRITE and the
        // light it casts.  The flicker is what sells it as a burning motor
        // rather than a lamp — a rocket exhaust is not a steady source.
        // Literal rather than RPG_ROCKET_MODEL: this file compiles BEFORE
        // shared/weapons/sh_wpn_hlrpg.qc (cl_progs.src :32 vs :103), so the
        // constant is not in scope yet.  Same string, checked against
        // Projectile_TypeModel/PROJ_TYPE_RPG_ROCKET.
        else if (cur.model == "models/rpgrocket.mdl")
        {
            // Flicker.  Keyed on cltime and the entity number so two rockets in
            // the air never pulse in lockstep.
            float flick = 0.82 + 0.18 * sin(cltime * 47 + num_for_edict(cur));
            dynamiclight_add(cur.origin, 190 * flick, '1.00 0.62 0.22', 0, "", lflags);

            // The flare SPRITE is drawn by CSQC_DrawRocketFlares in
            // client/cl_env_beam.qc, not here: spriteframe() and the DRAWFLAG_*
            // constants are declared in that file, which compiles AFTER this one
            // (cl_progs.src :32 vs :34).  This half is the light; that half is
            // the glow, and together they are HL's EF_LIGHT.
        }
        cur = nextent(cur);
    }
};
