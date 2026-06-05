//
//  sv_conveyor.qc  –  func_conveyor  (push + scrolling textures)
//
//  Brush that pushes whatever touches its top in the entity's angle
//  direction at `speed` units/second.  Textures starting with
//  "scroll*" animate at a related rate — the engine's GLSL shader
//  reads `e_glowmod.g == 0.5` to enable the scroll path and uses
//  `e_glowmod.b` as the per-second scroll multiplier (see
//  valve/glsl/defaultwall.glsl line 62-67).  We encode our speed
//  into glowmod.b on spawn so visual scroll matches the push.
//
//  Spawnflags (HL bit layout):
//    1   No push    – cosmetic only (still scrolls textures)
//    2   Not solid  – walk through the brush entirely
//

void() SetMovedir;                                              // sv_push.qc
void() SV_InitReplicatedSolidBrush;                             // sv_brushsync.qc
void(entity c) Conveyor_AddToList;                              // sh_pmove.qc

const float SF_CONVEYOR_NOPUSH   = 1;
const float SF_CONVEYOR_NOTSOLID = 2;

// Per-brush direction is computed at spawn from `angles`.  movedir
// goes into self.movedir (engine + brushsync wire already carry it).

// Player displacement is handled in PM_CheckConveyors (sh_pmove.qc).
// It runs in pmove on both SSQC (authoritative) and CSQC (predicted),
// reading the same conveyor_list, applying the same per-frame
// movedir*speed*dt positional offset traced against geometry — so
// the player is pushed identically on both sides and never sees a
// rubberband-snap when the server snapshot arrives.
//
// No server-side touch / think is necessary for the player path.
// (Non-player physics objects landing on a conveyor would need
// separate handling but that's not a current use case.)

/*QUAKED func_conveyor (0 .5 .8) ? NO_PUSH NOT_SOLID
Pushes touching entities + scrolls textures at `speed` units/sec.

"angles"  push direction
"speed"   units per second (default 100)

NO_PUSH (1):     cosmetic only (textures still scroll).
NOT_SOLID (2):   non-solid; can't be stood on.
*/
void() func_conveyor =
{
    if (!self.speed)
        self.speed = 100;
    if (self.angles == '0 0 0')
        self.angles = '0 360 0';
    SetMovedir();

    SV_InitReplicatedSolidBrush();
    // BRUSH_TYPE_CONVEYOR makes brushsync ship movedir + speed +
    // spawnflags so CSQC pmove can apply the same per-frame
    // displacement we do (PM_CheckConveyors in sh_pmove.qc).  This
    // is what eliminates the rubberbanding under non-zero ping —
    // the predicted client position now matches the server before
    // any reconciliation step.
    self.brush_type = BRUSH_TYPE_CONVEYOR;

    if (self.spawnflags & SF_CONVEYOR_NOTSOLID)
        self.solid = SOLID_NOT;

    // Register on the conveyor list so PM_CheckConveyors finds us.
    // Server-side iteration runs in the same pmove path as the
    // client, identical math, identical result.
    Conveyor_AddToList(self);

    // Encode scroll-rate hint into glowmod for the engine's
    // scrolling-texture shader path.  e_glowmod.g == 0.5 is the
    // sentinel; e_glowmod.b is multiplied by 1024 then by -0.01 in
    // the shader to derive per-second tex_c offset.  Solve for
    // glowmod.b = speed / -10.24 to get a positive `speed` map key
    // producing forward scroll.  Kept negative so HL maps' default
    // sign matches what their authors expected.
    self.glowmod = [self.glowmod_x, 0.5, self.speed * (-1.0 / 10.24)];

    // Bump SendFlags so brushsync re-ships glowmod (covered by the
    // existing replication path — solid_brush_SendEntity already
    // ships glowmod via colormod / effects).
    self.SendFlags = 1;
};
