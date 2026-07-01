const string CFC4_EXPLOSION_SPRITE = "gfx/fexplo.spr";
const float  CFC4_EXPLOSION_SCALE  = 4;

void() CSQC_C4_ExplosionSpriteThink =
{
    self.frame = self.frame + 1;
    if (self.frame >= 8)
    {
        remove(self);
        return;
    }
    self.nextthink = time + 0.05;
};

void(vector pos) CSQC_C4_SpawnExplosionSprite =
{
    entity spr = spawn();
    setorigin(spr, pos + '0 0 24');
    setmodel(spr, CFC4_EXPLOSION_SPRITE);
    spr.scale     = CFC4_EXPLOSION_SCALE;
    spr.drawmask  = MASK_ENGINE;
    spr.effects   = EF_ADDITIVE;
    spr.frame     = 0;
    spr.think     = CSQC_C4_ExplosionSpriteThink;
    spr.nextthink = time + 0.05;
};

// ============================================================
//  client/cl_c4.qc  -  Planted C4 CSQC parser + dlight pulse
//
//  Receives the SendEntity payload from c4_planted_SendEntity in
//  shared/weapons/sh_wpn_cfc4.qc (entry CSQC_ENT_C4 = 14).  Renders
//  the bomb's world model and pulses a red dlight in sync with each
//  beep — server bumps the beep_serial byte every time it plays
//  beep.wav, we trigger a pulse on serial change.
//
//  Wire payload (must match the SendEntity exactly):
//    byte  CSQC_ENT_C4
//    coord ×3 origin
//    byte  beep_serial   (0..255, wraps)
//    byte  defuse_state  (0 = idle, 1 = defuse in progress)
// ============================================================

.float c4_beep_serial;
.float c4_last_beep_serial;
.float c4_last_pulse_time;
.float c4_defuse_state;

// Live planted-C4 CSQC-entity count, maintained on create (CSQC_C4_Update isnew)
// and remove (CSQC_Ent_Remove in cl_main.qc).  Lets CSQC_C4_DrawLights early-out
// of its per-frame nextent() walk over ALL entities when no C4 is planted — the
// common case (every Bhop / non-Defuse round). cl_c4 compiles before cl_main, so
// the global is visible in the removal hook without a forward decl.
float csqc_c4_count;

// Most recent moment a planting click fired on the local player —
// drives the red flash on the planter's body during prefire so the
// planting reads as visually "armed".  Set by CSQC_PredictCFC4Command
// at each predicted click stage; consumed by CSQC_C4_DrawPlanterFlash
// below.  Resets after 0.15 s (the dlight fades to nothing).
float csqc_cfc4_planter_flash_time;

void(float isnew) CSQC_C4_Update =
{
    float new_origin_x = readcoord();
    float new_origin_y = readcoord();
    float new_origin_z = readcoord();
    float new_angles_x = readangle();
    float new_angles_y = readangle();
    float new_angles_z = readangle();
    float new_serial   = readbyte();
    float new_defuse   = readbyte();

    setorigin(self, [new_origin_x, new_origin_y, new_origin_z]);
    self.angles = [new_angles_x, new_angles_y, new_angles_z];

    if (isnew)
    {
        setmodel(self, "models/weapons/wpn_cfc4/w_c4.mdl");
        self.classname = "csqc_c4";   // tag for the removal hook + light-walk gate
        self.solid     = SOLID_NOT;
        self.movetype  = MOVETYPE_NONE;
        self.drawmask  = MASK_ENGINE;
        self.c4_last_beep_serial = new_serial;   // first frame — no pulse trigger
        csqc_c4_count = csqc_c4_count + 1;
    }

    // Detect a beep transition (serial bumped on the server).  Capture
    // cltime so the per-frame predraw can fade the dlight intensity.
    if (new_serial != self.c4_last_beep_serial)
    {
        self.c4_last_pulse_time = cltime;
        self.c4_last_beep_serial = new_serial;
    }
    self.c4_beep_serial   = new_serial;
    self.c4_defuse_state  = new_defuse;
};

// Per-frame red flash on the planter during prefire — set off by
// each predicted plant click.  Same fade curve as a muzzle flash:
// peak intensity at the click moment, decays to zero over 0.15 s.
// Drawn on the LOCAL player's chest.  (Other clients seeing a
// remote planter flash would need a multicast event — flagged as
// future cleanup; the planter's own "I'm planting" feedback is the
// most important visual cue.)
void() CSQC_C4_DrawPlanterFlash =
{
    if (!predicted_player)
        return;
    if (csqc_cfc4_planter_flash_time <= 0)
        return;

    float age = cltime - csqc_cfc4_planter_flash_time;
    if (age >= 0.15)
        return;

    float intensity = 1.0 - (age / 0.15);

    // Place the dlight just in front of the camera so it lights
    // the viewmodel — anchoring it to the player's chest left
    // the gun mostly black against the pulse.  The body-chest
    // dlight is kept too so other observers still see the
    // planter pulse from the outside.
    vector cam_pos = (vector)getproperty(VF_ORIGIN);
    vector cam_ang = (vector)getproperty(VF_ANGLES);
    makevectors(cam_ang);
    vector vm_light = cam_pos + v_forward * 16 + v_up * -2;

    float lflags = cvar("cl_combat_light_shadows") ? 0 : PFLAGS_NOSHADOW;
    dynamiclight_add(vm_light,
                     220 * intensity,
                     '1 0.18 0.18' * intensity, 0, "", lflags);
    dynamiclight_add(predicted_player.origin + '0 0 24',
                     160 * intensity,
                     '1 0.15 0.15' * intensity, 0, "", lflags);
};

// Per-frame dlight pulse.  Called from the CSQC view-update path.
// Walks all planted_c4 entities and adds a red dlight whose
// brightness decays after each beep.
void() CSQC_C4_DrawLights =
{
    // No planted C4 → skip the whole-entity nextent() walk entirely (the common
    // case — every Bhop / non-Defuse round).  Count maintained in CSQC_C4_Update
    // (isnew) + CSQC_Ent_Remove.
    if (csqc_c4_count <= 0)
        return;

    float lflags = cvar("cl_combat_light_shadows") ? 0 : PFLAGS_NOSHADOW;

    // Walk CSQC entities by the csqc_c4 classname (set in CSQC_C4_Update).
    entity cur = nextent(world);
    while (cur)
    {
        if (cur.model == "models/weapons/wpn_cfc4/w_c4.mdl")
        {
            if (cur.c4_defuse_state == 2)
            {
                // DEFUSED — steady BLUE "safe" light.  Independent of the beep
                // pulse (the bomb stopped beeping the instant it was disarmed).
                dynamiclight_add(cur.origin + '0 0 8', 96, '0.2 0.45 1', 0, "", lflags);
            }
            else if (cur.c4_last_pulse_time > 0)
            {
                // ARMED — red light that flashes with each beep.  Stays red and
                // keeps flashing even while a defuse is IN PROGRESS (state 1);
                // it only turns blue once the bomb is actually defused (above).
                float age = cltime - cur.c4_last_pulse_time;
                float intensity = 1.0 - (age / 0.15);
                if (intensity < 0) intensity = 0;
                if (intensity > 0)
                    dynamiclight_add(cur.origin + '0 0 8',
                                     96 * intensity,
                                     '1 0.1 0.1' * intensity, 0, "", lflags);
            }
        }
        cur = nextent(cur);
    }
};
