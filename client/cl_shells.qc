// ============================================================
//  client/cl_shells.qc  -  Shell casings & magazine drops
//
//  Client-predicted shell casings and magazine drops.
//  Local player sees these instantly via CSQC prediction.
//  Other players see them via server multicast events.
//  Ported from NewQuake/weapons/accessory.qc.
// ============================================================

.float fly_sound;   // bounce sound counter for casings
.float shell_delay; // debounce timer for touch sounds

// ------------------------------------------------------------
//  Model lookup by shell/mag type
// ------------------------------------------------------------

string(float type) CSQC_ShellModelForType =
{
    switch (type)
    {
        case SHELL_9MM:         return "models/weapons/9mmcasing.mdl";
        case SHELL_RED:         return "models/weapons/redcasing.mdl";
        case SHELL_RIFLE:       return "models/weapons/riflecasing.mdl";
        case SHELL_RIFLE_BIG:   return "models/weapons/riflecasingbig.mdl";
        case SHELL_SHOTGUN1:    return "models/weapons/shotgunshell1.mdl";
        case SHELL_SHOTGUN2:    return "models/weapons/shotgunshell2.mdl";
    }
    return "models/weapons/9mmcasing.mdl";
};

string(float type) CSQC_MagModelForType =
{
    switch (type)
    {
        case MAG_PISTOL:    return "models/weapons/pistolmag.mdl";
        case MAG_PISTOL_HL: return "models/weapons/pistolmaghl.mdl";
        case MAG_RIFLE:     return "models/weapons/riflemag.mdl";
    }
    return "models/weapons/riflemag.mdl";
};

// ------------------------------------------------------------
//  Bounce sounds, settling, touch
// ------------------------------------------------------------

void() CSQC_ShellBounceSound =
{
    float r = random();
    if (r < 0.333)
        pointsound(self.origin, "sounds/weapons/casing1.wav", 1.0, ATTN_NORM);
    else if (r < 0.666)
        pointsound(self.origin, "sounds/weapons/casing2.wav", 1.0, ATTN_NORM);
    else
        pointsound(self.origin, "sounds/weapons/casing3.wav", 1.0, ATTN_NORM);
};

void(vector surface_normal) CSQC_ShellSettle =
{
    vector n;
    float yaw;

    n = surface_normal;
    if (vlen(n) < 0.01)
        n = '0 0 1';

    self.movetype = MOVETYPE_NONE;
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.touch = __NULL__;

    // Raise off the ground so shells don't clip into the floor
    self.origin_z += 1;
    setorigin(self, self.origin);

    // Lay flat on surface: pitch=0, roll=0, random yaw spin
    // For a flat floor (normal = 0 0 1) this gives angles = '0 yaw 0'
    // For slopes, tilt pitch/roll to match the surface
    yaw = random() * 360;

    if (n_z > 0.99)
    {
        // Perfectly flat floor — just lay flat with random yaw
        self.angles = [0, yaw, 0];
    }
    else
    {
        // Sloped surface — compute pitch and roll from normal
        // pitch = tilt forward/back, roll = tilt left/right
        vector fwd, rt;
        makevectors([0, yaw, 0]);
        fwd = v_forward;
        rt = v_right;

        self.angles_x = -asin(n * fwd) * (180.0 / M_PI);  // pitch from forward tilt
        self.angles_z = asin(n * rt) * (180.0 / M_PI);     // roll from side tilt
        self.angles_y = yaw;
    }
};

void() CSQC_ShellTouch =
{
    vector flat_velocity = self.velocity;
    flat_velocity_z = 0;

    if (trace_plane_normal_z > 0.6
        && fabs(self.velocity_z) < 70
        && vlen(flat_velocity) < 55)
    {
        CSQC_ShellSettle(trace_plane_normal);
        return;
    }

    if (self.fly_sound <= 0)
        return;

    if (time < self.shell_delay)
        return;

    CSQC_ShellBounceSound();
    self.fly_sound = self.fly_sound - 1;
    self.shell_delay = time + 0.1;
};

void() CSQC_ShellExpire =
{
    remove(self);
};

// Think-based settle check — if shell has nearly stopped moving, trace
// down to the floor and orient flat.
void() CSQC_ShellSettleThink =
{
    vector flat_vel;

    // Still has significant velocity — check again later
    flat_vel = self.velocity;
    flat_vel_z = 0;
    if (fabs(self.velocity_z) > 30 || vlen(flat_vel) > 30)
    {
        self.nextthink = time + 0.2;
        return;
    }

    // Trace down to find the floor normal
    traceline(self.origin, self.origin - '0 0 32', TRUE, self);
    if (trace_fraction < 1)
        CSQC_ShellSettle(trace_plane_normal);
    else
        CSQC_ShellSettle('0 0 1');

    // Schedule removal
    self.think = CSQC_ShellExpire;
    self.nextthink = time + 20;
};

// ------------------------------------------------------------
//  Core spawn — local player (relative to view)
// ------------------------------------------------------------

void(string mdl, vector origin_offset, vector base_velocity, vector velocity_jitter, vector base_avelocity, vector avelocity_jitter, float move_type, float lifetime, float bounce_count) CSQC_SpawnAccessory =
{
    entity accessory;
    vector accessory_origin;
    vector accessory_velocity;
    vector accessory_avelocity;
    float local_fwd, local_right, local_up;

    makevectors(input_angles);

    accessory = spawn();
    setmodel(accessory, mdl);
    accessory.classname = "csqc_debris";
    accessory.solid = SOLID_NOT;
    accessory.movetype = move_type;
    accessory.touch = CSQC_ShellTouch;
    accessory.shell_delay = time + 0.05;
    accessory.drawmask = MASK_ENGINE;
    setsize(accessory, '0 0 0', '0 0 0');

    accessory_origin = self.origin + self.view_ofs
        + (v_forward * origin_offset_x)
        + (v_right * origin_offset_y)
        + (v_up * origin_offset_z);
    setorigin(accessory, accessory_origin);

    local_fwd   = base_velocity_x + ((random() - 0.5) * 2 * velocity_jitter_x);
    local_right = base_velocity_y + ((random() - 0.5) * 2 * velocity_jitter_y);
    local_up    = base_velocity_z + ((random() - 0.5) * 2 * velocity_jitter_z);

    accessory_velocity = self.velocity
        + (v_forward * local_fwd)
        + (v_right * local_right)
        + (v_up * local_up);
    accessory.velocity = accessory_velocity;

    accessory_avelocity_x = base_avelocity_x + ((random() - 0.5) * 2 * avelocity_jitter_x);
    accessory_avelocity_y = base_avelocity_y + ((random() - 0.5) * 2 * avelocity_jitter_y);
    accessory_avelocity_z = base_avelocity_z + ((random() - 0.5) * 2 * avelocity_jitter_z);
    accessory.avelocity = accessory_avelocity;
    accessory.fly_sound = bounce_count;

    // Settle check kicks in after initial bouncing, then schedules expiry
    accessory.think = CSQC_ShellSettleThink;
    accessory.nextthink = time + 0.5;
};

void(string mdl, vector ofs, vector vel, vector vel_jitter, vector avel, vector avel_jitter) CSQC_SpawnCasing =
{
    // Global shell adjustments: push forward, raise, adjust ejection velocity
    ofs_x += 4;
    ofs_z += 1;
    vel_y += 20;
    vel_z += 10;
    CSQC_SpawnAccessory(mdl, ofs, vel, vel_jitter, avel, avel_jitter, MOVETYPE_BOUNCE, 20, 2);
};

void(string mdl, vector ofs, vector vel, vector vel_jitter, vector avel, vector avel_jitter) CSQC_SpawnMag =
{
    // Lower mag drop origin on player
    ofs_z -= 4;
    CSQC_SpawnAccessory(mdl, ofs, vel, vel_jitter, avel, avel_jitter, MOVETYPE_TOSS, 20, 0);
};

// ------------------------------------------------------------
//  Remote spawn — from multicast (absolute world coords)
// ------------------------------------------------------------

void(string mdl, vector org, vector vel, vector avel, float move_type, float lifetime, float bounce_count) CSQC_SpawnRemoteAccessory =
{
    entity accessory = spawn();
    setmodel(accessory, mdl);
    accessory.classname = "csqc_debris";
    accessory.solid = SOLID_NOT;
    accessory.movetype = move_type;
    accessory.touch = CSQC_ShellTouch;
    accessory.shell_delay = time + 0.05;
    accessory.drawmask = MASK_ENGINE;
    setsize(accessory, '0 0 0', '0 0 0');

    setorigin(accessory, org);
    accessory.velocity = vel;
    accessory.avelocity = avel;
    accessory.fly_sound = bounce_count;

    accessory.think = CSQC_ShellSettleThink;
    accessory.nextthink = time + 0.5;
};

void(string mdl, vector org, vector vel, vector avel) CSQC_SpawnRemoteCasing =
{
    CSQC_SpawnRemoteAccessory(mdl, org, vel, avel, MOVETYPE_BOUNCE, 20, 2);
};

void(string mdl, vector org, vector vel, vector avel) CSQC_SpawnRemoteMag =
{
    CSQC_SpawnRemoteAccessory(mdl, org, vel, avel, MOVETYPE_TOSS, 20, 0);
};

// ------------------------------------------------------------
//  Wipe all shells and mags (round restart)
// ------------------------------------------------------------

void() CSQC_ShellsWipeAll =
{
    entity e, next;
    e = nextent(world);
    while (e)
    {
        next = nextent(e);
        if (e.classname == "csqc_debris")
            remove(e);
        e = next;
    }
};

// ------------------------------------------------------------
//  Precache
// ------------------------------------------------------------

void() CSQC_PrecacheShells =
{
    precache_model("models/weapons/9mmcasing.mdl");
    precache_model("models/weapons/redcasing.mdl");
    precache_model("models/weapons/riflecasing.mdl");
    precache_model("models/weapons/riflecasingbig.mdl");
    precache_model("models/weapons/shotgunshell1.mdl");
    precache_model("models/weapons/shotgunshell2.mdl");
    precache_model("models/weapons/pistolmag.mdl");
    precache_model("models/weapons/pistolmaghl.mdl");
    precache_model("models/weapons/riflemag.mdl");
    precache_sound("sounds/weapons/casing1.wav");
    precache_sound("sounds/weapons/casing2.wav");
    precache_sound("sounds/weapons/casing3.wav");
};
