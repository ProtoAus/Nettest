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
        self.solid     = SOLID_NOT;
        self.movetype  = MOVETYPE_NONE;
        self.drawmask  = MASK_ENGINE;
        self.c4_last_beep_serial = new_serial;   // first frame — no pulse trigger
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

    dynamiclight_add(vm_light,
                     220 * intensity,
                     '1 0.18 0.18' * intensity);
    dynamiclight_add(predicted_player.origin + '0 0 24',
                     160 * intensity,
                     '1 0.15 0.15' * intensity);
};

// Per-frame dlight pulse.  Called from the CSQC view-update path.
// Walks all planted_c4 entities and adds a red dlight whose
// brightness decays after each beep.
void() CSQC_C4_DrawLights =
{
    entity e = findchain(classname, "");   // chain by entity, model-based filter
    // Faster: walk by model.  But we set model on receive, so use that.
    e = world;
    entity cur = nextent(world);
    while (cur)
    {
        if (cur.model == "models/weapons/wpn_cfc4/w_c4.mdl"
            && cur.c4_last_pulse_time > 0)
        {
            // Pulse fades over 0.15s after each beep.  Defuse-in-progress
            // brightens to a steady glow instead — visual cue that
            // someone's working on it.
            float age = cltime - cur.c4_last_pulse_time;
            float intensity;
            if (cur.c4_defuse_state)
            {
                intensity = 1.0;   // steady-on while defusing
            }
            else
            {
                intensity = 1.0 - (age / 0.15);
                if (intensity < 0) intensity = 0;
            }
            if (intensity > 0)
            {
                vector lightcolor = '1 0.1 0.1';   // red
                if (cur.c4_defuse_state)
                    lightcolor = '0.2 0.7 1';      // cyan while defusing
                dynamiclight_add(cur.origin + '0 0 8',
                                 96 * intensity,
                                 lightcolor * intensity);
            }
        }
        cur = nextent(cur);
    }
};
