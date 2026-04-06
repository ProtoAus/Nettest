//
//  sv_doors.qc  –  func_button and func_door
//
//  Both entities register with SV_InitReplicatedSolidBrush so the CSQC world
//  has a matching SOLID_BSP entity for client-side prediction.  Whenever
//  velocity or position changes, SendFlags is set so the engine re-sends the
//  solid_brush packet; CSQC then moves the entity at the correct velocity
//  between updates, keeping prediction traces accurate.
//

// ============================================================================
//  Shared helpers
// ============================================================================

void() SetMovedir;   // defined in sv_push.qc

void(entity caller, entity triggerer) Trigger_UseTargets =
{
    entity target_entity;
    entity oldself;
    entity oldactivator;

    if (!caller.target)
        return;

    oldactivator = activator;
    activator = triggerer;

    target_entity = find(world, targetname, caller.target);
    while (target_entity)
    {
        if (target_entity != caller && target_entity.use)
        {
            oldself = self;
            self = target_entity;
            self.use();
            self = oldself;
        }
        target_entity = find(target_entity, targetname, caller.target);
    }

    activator = oldactivator;
};

// ============================================================================
//  Generic mover  –  velocity-based movement toward a destination
//  Sets SendFlags so the CSQC entity gets the updated position + velocity.
// ============================================================================

void(vector destination, float move_speed, void() move_done) Mover_Start =
{
    vector delta;
    float  distance;
    float  travel_time;

    delta    = destination - self.origin;
    distance = vlen(delta);

    if (distance <= 0 || move_speed <= 0)
    {
        setorigin(self, destination);
        self.velocity  = '0 0 0';
        self.SendFlags = 1;
        move_done();
        return;
    }

    travel_time    = distance / move_speed;
    self.velocity  = delta * (1.0 / travel_time);
    self.nextthink = self.ltime + travel_time;
    self.think     = move_done;
    self.SendFlags = 1;   // tell CSQC: new origin + velocity
};

// ============================================================================
//  func_button
// ============================================================================

float BUTTON_STATE_BOTTOM = 0;
float BUTTON_STATE_UP     = 1;
float BUTTON_STATE_TOP    = 2;
float BUTTON_STATE_DOWN   = 3;

void() button_fire;

void() button_done =
{
    setorigin(self, self.pos1);
    self.velocity      = '0 0 0';
    self.button_state  = BUTTON_STATE_BOTTOM;
    self.frame         = 0;
    self.SendFlags     = 1;
};

void() button_return =
{
    self.button_state = BUTTON_STATE_DOWN;
    Mover_Start(self.pos1, self.speed, button_done);
};

void() button_wait =
{
    setorigin(self, self.pos2);
    self.velocity     = '0 0 0';
    self.button_state = BUTTON_STATE_TOP;
    self.frame        = 1;
    self.SendFlags    = 1;
    Trigger_UseTargets(self, self.enemy);

    if (self.wait < 0)
        return;

    self.nextthink = self.ltime + self.wait;
    self.think     = button_return;
};

void() button_blocked =
{
};

void() button_fire =
{
    if (self.button_state == BUTTON_STATE_UP || self.button_state == BUTTON_STATE_TOP)
        return;

    if (self.noise)
        sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);

    self.button_state = BUTTON_STATE_UP;
    Mover_Start(self.pos2, self.speed, button_wait);
};

void() button_use =
{
    self.enemy = activator;
    button_fire();
};

void() button_touch =
{
    if (other.classname != "player")
        return;
    self.enemy = other;
    button_fire();
};

/*QUAKED func_button (0 .5 .8) ?
Touch or shoot/use to activate.  Moves in the entity's angle direction,
fires targets, waits, and optionally returns.

"angle"    opening direction
"target"   entities to fire when pressed
"speed"    movement speed (default 40)
"wait"     seconds before returning (default 1, -1 = never)
"lip"      remaining lip at end of move (default 4)
"distance" explicit move distance (overrides lip calc)
"sounds"   0=steam 1=wood 2=metallic 3=in-out
*/
void() func_button =
{
    string default_noise;

    if (self.sounds == 1)
        default_noise = "buttons/switch21.wav";
    else if (self.sounds == 2)
        default_noise = "buttons/switch02.wav";
    else if (self.sounds == 3)
        default_noise = "buttons/switch04.wav";
    else
        default_noise = "buttons/airbut1.wav";

    if (!self.noise)
        self.noise = default_noise;
    precache_sound(self.noise);

    if (!self.speed) self.speed = 40;
    if (!self.wait)  self.wait  = 1;
    if (!self.lip)   self.lip   = 4;

    SV_InitReplicatedSolidBrush();
    self.blocked      = button_blocked;
    self.use          = button_use;
    self.touch        = button_touch;
    self.button_state = BUTTON_STATE_BOTTOM;
    self.pos1         = self.origin;

    if (self.movedir != '0 0 0')
        self.pos2 = self.pos1 + self.movedir;
    else
    {
        SetMovedir();
        if (self.distance)
            self.pos2 = self.pos1 + self.movedir * self.distance;
        else
            self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * self.size) - self.lip);
    }
};

// ============================================================================
//  func_door
// ============================================================================

float DOOR_START_OPEN  = 1;
float DOOR_CRUSHING    = 2;
float DOOR_DONT_LINK   = 4;
float DOOR_TOGGLE      = 32;

float DOOR_STATE_BOTTOM = 0;
float DOOR_STATE_UP     = 1;
float DOOR_STATE_TOP    = 2;
float DOOR_STATE_DOWN   = 3;

float DOOR_TRIGGER_PAD_XY = 60;
float DOOR_TRIGGER_PAD_Z  = 8;

float door_group_mark_serial;

void() door_go_up;
void() door_go_down;

void() door_hit_bottom =
{
    setorigin(self, self.pos1);
    self.velocity    = '0 0 0';
    self.door_state  = DOOR_STATE_BOTTOM;
    self.SendFlags   = 1;
    if (self.noise1)
        sound(self, CHAN_VOICE, self.noise1, 1, ATTN_NORM);
};

void() door_go_down =
{
    if (self.door_state == DOOR_STATE_BOTTOM || self.door_state == DOOR_STATE_DOWN)
        return;
    self.door_state = DOOR_STATE_DOWN;
    if (self.noise2)
        sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);
    Mover_Start(self.pos1, self.speed, door_hit_bottom);
};

void() door_hit_top =
{
    setorigin(self, self.pos2);
    self.velocity   = '0 0 0';
    self.door_state = DOOR_STATE_TOP;
    self.SendFlags  = 1;
    if (self.noise1)
        sound(self, CHAN_VOICE, self.noise1, 1, ATTN_NORM);
    if ((self.spawnflags & DOOR_TOGGLE) || self.wait < 0)
        return;
    self.nextthink = self.ltime + self.wait;
    self.think     = door_go_down;
};

void() door_go_up =
{
    if (self.door_state == DOOR_STATE_TOP)
    {
        if (!(self.spawnflags & DOOR_TOGGLE) && self.wait >= 0)
        {
            self.nextthink = self.ltime + self.wait;
            self.think     = door_go_down;
        }
        return;
    }
    if (self.door_state == DOOR_STATE_UP)
        return;
    self.door_state = DOOR_STATE_UP;
    if (self.noise2)
        sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);
    Mover_Start(self.pos2, self.speed, door_hit_top);
};

void() door_blocked =
{
    if (self.spawnflags & DOOR_CRUSHING)
        return;
    if (self.door_state == DOOR_STATE_UP || self.door_state == DOOR_STATE_TOP)
        door_go_down();
    else
        door_go_up();
};

// ---- door group activation ----

float(entity d1, entity d2) Door_ShouldLink =
{
    if (d1 == d2)                                               return FALSE;
    if ((d1.spawnflags & DOOR_DONT_LINK) || (d2.spawnflags & DOOR_DONT_LINK)) return FALSE;
    if (d1.groupname && d1.groupname[0])
        return (d2.groupname == d1.groupname);
    if (d2.groupname && d2.groupname[0])                       return FALSE;
    if (d1.cmins_x > d2.cmaxs_x || d1.cmaxs_x < d2.cmins_x) return FALSE;
    if (d1.cmins_y > d2.cmaxs_y || d1.cmaxs_y < d2.cmins_y) return FALSE;
    if (d1.cmins_z > d2.cmaxs_z || d1.cmaxs_z < d2.cmins_z) return FALSE;
    return TRUE;
};

void(entity door) Door_ActivateSingle =
{
    entity oldself;
    door.attack_finished = time + 0.1;
    oldself = self;
    if ((door.spawnflags & DOOR_TOGGLE) && (door.door_state == DOOR_STATE_UP || door.door_state == DOOR_STATE_TOP))
    {
        self = door; door_go_down(); self = oldself;
        return;
    }
    self = door; door_go_up(); self = oldself;
};

void(entity seed) Door_OpenGroup =
{
    entity nextdoor;
    if (seed.door_mark == door_group_mark_serial)
        return;
    seed.door_mark = door_group_mark_serial;
    Door_ActivateSingle(seed);
    nextdoor = find(world, classname, "func_door");
    while (nextdoor)
    {
        if (nextdoor.door_mark != door_group_mark_serial && Door_ShouldLink(seed, nextdoor))
            Door_OpenGroup(nextdoor);
        nextdoor = find(nextdoor, classname, "func_door");
    }
};

void() door_use =
{
    if (self.attack_finished > time)
        return;
    self.attack_finished = time + 0.1;
    Trigger_UseTargets(self, activator);
    door_group_mark_serial = door_group_mark_serial + 1;
    if (door_group_mark_serial <= 0) door_group_mark_serial = 1;
    Door_OpenGroup(self);
};

void() door_trigger_touch =
{
    entity oldself, oldactivator;
    if (other.classname != "player")
        return;
    oldself = self; oldactivator = activator;
    activator = other;
    self = self.owner;
    door_use();
    self = oldself; activator = oldactivator;
};

void() door_spawn_trigger =
{
    entity trigger;
    vector center, mins, maxs;
    center  = (self.cmins + self.cmaxs) * 0.5;
    mins    = self.cmins - center - [DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_Z];
    maxs    = self.cmaxs - center + [DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_Z];
    trigger = spawn();
    setorigin(trigger, center);
    setsize(trigger, mins, maxs);
    trigger.movetype = MOVETYPE_NONE;
    trigger.solid    = SOLID_TRIGGER;
    trigger.owner    = self;
    trigger.touch    = door_trigger_touch;
};

/*QUAKED func_door (0 .5 .8) ? START_OPEN CRUSHING DONT_LINK _ _ TOGGLE
Touch-activated moving brush door.

"angle"      opening direction
"target"     entities to fire when opened
"targetname" if set, no auto trigger is spawned; activate via use only
"speed"      movement speed (default 100)
"wait"       seconds before closing (default 3, -1 = stay open)
"lip"        remaining lip at end of move (default 8)
"distance"   explicit move distance (overrides lip calc)
"groupname"  link doors with the same name into one group
"sounds"     0=silent 1=stone 2=base 3=chain 4=metal
*/
void() func_door =
{
    vector swap_pos;

    if (self.sounds == 1)
    {
        if (!self.noise1) self.noise1 = "doors/drclos4.wav";
        if (!self.noise2) self.noise2 = "doors/doormv1.wav";
    }
    else if (self.sounds == 2)
    {
        if (!self.noise1) self.noise1 = "doors/hydro2.wav";
        if (!self.noise2) self.noise2 = "doors/hydro1.wav";
    }
    else if (self.sounds == 3)
    {
        if (!self.noise1) self.noise1 = "doors/stndr2.wav";
        if (!self.noise2) self.noise2 = "doors/stndr1.wav";
    }
    else if (self.sounds == 4)
    {
        if (!self.noise1) self.noise1 = "doors/ddoor2.wav";
        if (!self.noise2) self.noise2 = "doors/ddoor1.wav";
    }

    if (self.noise1) precache_sound(self.noise1);
    if (self.noise2) precache_sound(self.noise2);

    if (!self.speed) self.speed = 100;
    if (!self.wait)  self.wait  = 3;
    if (!self.lip)   self.lip   = 8;

    SV_InitReplicatedSolidBrush();
    self.blocked = door_blocked;
    self.use     = door_use;
    self.pos1    = self.origin;

    if (self.movedir != '0 0 0')
    {
        self.pos2   = self.pos1 + self.movedir;
        self.angles = '0 0 0';
    }
    else if (self.mangle != '0 0 0')
    {
        if (!self.distance) self.distance = 64;
        makevectors(self.mangle);
        self.movedir = v_forward;
        self.pos2    = self.pos1 + self.movedir * self.distance;
    }
    else
    {
        if (self.angles == '0 0 0')
            self.angles = '0 -1 0';
        SetMovedir();
        if (self.distance)
            self.pos2 = self.pos1 + self.movedir * self.distance;
        else
            self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * self.size) - self.lip);
    }

    if (self.spawnflags & DOOR_START_OPEN)
    {
        setorigin(self, self.pos2);
        swap_pos  = self.pos1;
        self.pos1 = self.pos2;
        self.pos2 = swap_pos;
    }

    // combined bounds for proximity trigger and group-linking
    self.cmins = self.pos1 + self.mins;
    self.cmaxs = self.pos1 + self.maxs;
    if (self.pos2_x + self.mins_x < self.cmins_x) self.cmins_x = self.pos2_x + self.mins_x;
    if (self.pos2_y + self.mins_y < self.cmins_y) self.cmins_y = self.pos2_y + self.mins_y;
    if (self.pos2_z + self.mins_z < self.cmins_z) self.cmins_z = self.pos2_z + self.mins_z;
    if (self.pos2_x + self.maxs_x > self.cmaxs_x) self.cmaxs_x = self.pos2_x + self.maxs_x;
    if (self.pos2_y + self.maxs_y > self.cmaxs_y) self.cmaxs_y = self.pos2_y + self.maxs_y;
    if (self.pos2_z + self.maxs_z > self.cmaxs_z) self.cmaxs_z = self.pos2_z + self.maxs_z;

    self.door_state = DOOR_STATE_BOTTOM;

    if (!self.targetname)
        door_spawn_trigger();
};
