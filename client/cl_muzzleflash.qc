// ============================================================
//  client/cl_muzzleflash.qc  -  Client-predicted muzzle flash
//
//  Spawns a brief dynamic light at the camera position when
//  a weapon fires. Called from CSQC prediction code so it
//  appears instantly regardless of ping.
//
//  Other players see the flash via the server's standard
//  EF_MUZZLEFLASH on the player entity.
// ============================================================

float csqc_muzzleflash_time;       // cltime when the last flash started
float csqc_muzzleflash_duration;   // how long the flash lasts

const float MUZZLE_FLASH_RADIUS   = 300;
const float MUZZLE_FLASH_DURATION = 0.1;

// Called from weapon prediction when a shot fires.
// Triggers a dynamic light at the player's view position.
void() CSQC_MuzzleFlash =
{
    csqc_muzzleflash_time = cltime;
    csqc_muzzleflash_duration = MUZZLE_FLASH_DURATION;
};

// Called every render frame from CSQC_UpdateView.
// Adds the dynamic light while the flash is active.
void() CSQC_DrawMuzzleFlash =
{
    float age;
    float frac;
    float radius;
    vector pos;

    if (csqc_muzzleflash_time <= 0)
        return;

    age = cltime - csqc_muzzleflash_time;
    if (age >= csqc_muzzleflash_duration)
    {
        csqc_muzzleflash_time = 0;
        return;
    }

    // Fade out over the duration
    frac = 1.0 - (age / csqc_muzzleflash_duration);
    radius = MUZZLE_FLASH_RADIUS * frac;

    // Position at the camera (view origin)
    pos = getproperty(VF_ORIGIN);

    // Push forward and up from the camera to simulate muzzle position
    makevectors(getproperty(VF_ANGLES));
    pos = pos + v_forward * 8 + v_up * 4;

    dynamiclight_add(pos, radius, '1 0.8 0.4' * frac);
};
