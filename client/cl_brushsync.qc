//
//  cl_brushsync.qc  –  CSQC solid brush entity
//
//  Receives func_wall-style brush entities from the server and rebuilds them
//  as SOLID_BSP entities so client prediction traces hit them correctly.
//

void() CSQC_SolidBrush_Update =
{
    string modelname;
    vector org, ang, emins, emaxs, vel;
    float alpha_value;
    float effect_flags;

    modelname = readstring();
    org = readvector();
    ang = readvector();
    emins = readvector();
    emaxs = readvector();
    alpha_value = readfloat();
    effect_flags = readfloat();
    vel = readvector();

    if (self.model != modelname)
        setmodel(self, modelname);

    setsize(self, emins, emaxs);

    self.movetype = MOVETYPE_NOCLIP;  // auto-advances at velocity between server packets
    self.solid = SOLID_BSP;
    self.drawmask = MASK_ENGINE;
    self.angles = ang;
    self.alpha = alpha_value;
    self.effects = effect_flags;
    self.velocity = vel;
    setorigin(self, org);
};
