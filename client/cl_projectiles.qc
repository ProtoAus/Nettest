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
    // Avelocity-driven angle drift — frametime is the per-frame engine
    // global, so the rotation rate matches whatever the server set on
    // spawn regardless of client framerate.
    self.angles = self.angles + self.avelocity * frametime;
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
        setsize(self, '-2 -2 -2', '2 2 2');
        // Initialise angles from the current velocity direction so the
        // model points where it's flying on first appearance, before any
        // avelocity-driven rotation kicks in. Looks much better than the
        // default (0,0,0) angles for fast-moving projectiles like the
        // crossbow bolt that should align with the velocity vector.
        if (vlen(new_velocity) > 0)
            self.angles = vectoangles(new_velocity);
        // Paintball: shrink the snowball model so it reads as a
        // small marker round, and apply the per-shot tint.
        if (ptype == PROJ_TYPE_PAINTBALL)
        {
            self.scale    = 0.5;
            self.colormod = new_colormod;
        }
    }

    // Always live: avelocity may change between samples (rare for
    // projectiles, but cheaper to assign than to gate). proj_type
    // isn't stored on the CSQC entity (the field is gated to SSQC and
    // the local ptype variable is enough for this update).
    self.avelocity = new_avelocity;
    self.csqc_projectile_type = ptype;
    self.frame = 0;

    // Route the new authoritative sample through the smoothing helper.
    // Gravity factor matches the server's .gravity for this projectile
    // type so the CSQC extrap curves the same way the server's
    // MOVETYPE_TOSS / FLYMISSILE physics propagates between sends.
    CSQC_TossSampleApply(self, new_origin, new_velocity,
                         Projectile_TypeGravity(ptype));
};
