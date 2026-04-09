// ============================================================
//  shared/weapons/sh_wpn_pistol.qc  -  Pistol
//
//  Slot  : SLOT_SECONDARY  (impulse 2 / key 2)
//  Stats : 12-round magazine, 24 reserve, semi-auto
//  Fire  : lag-compensated hitscan, linear damage falloff
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_pistol;
.float ammo_pistol;

// --- Animation frames ---
const float PISTOL_FRAME_INTERVAL      = 0.05;

const float PISTOL_DRAW_START          = 1;
const float PISTOL_DRAW_END            = 10;

const float PISTOL_FIRE_START          = 11;
const float PISTOL_FIRE_END            = 33;
const float PISTOL_FIRE_DELAY          = 0.2;

const float PISTOL_RELOAD_START        = 34;
const float PISTOL_RELOAD_END          = 65;
const float PISTOL_RELOAD_SND_FRAME    = 35;
const float PISTOL_RELOAD_MAGDROP      = 44;
const float PISTOL_RELOAD_APPLY        = 53;

const float PISTOL_IDLE_FRAME          = 0;

const float MAX_MAG_PISTOL             = 12;
const float MAX_AMMO_PISTOL            = 24;
const float PISTOL_DRYFIRE_DELAY       = 0.2;

// --- Balance ---
const float PISTOL_BASE_SPREAD          = 0.004;
const float PISTOL_MOVE_SPREAD          = 0.045;
const float PISTOL_FULL_SPREAD_SPEED    = 320;
const float PISTOL_CLOSE_DAMAGE         = 20;
const float PISTOL_MIN_DAMAGE           = 8;
const float PISTOL_DAMAGE_FALLOFF_RANGE = 2048;

// --- Pre-computed state durations ---
const float PISTOL_DRAW_DURATION      = (PISTOL_DRAW_END - PISTOL_DRAW_START) * PISTOL_FRAME_INTERVAL;
const float PISTOL_FIRE_DURATION      = (PISTOL_FIRE_END - PISTOL_FIRE_START) * PISTOL_FRAME_INTERVAL;
const float PISTOL_RELOAD_DURATION    = (PISTOL_RELOAD_END - PISTOL_RELOAD_START) * PISTOL_FRAME_INTERVAL;
const float PISTOL_RELOAD_APPLY_TIME  = (PISTOL_RELOAD_APPLY - PISTOL_RELOAD_START) * PISTOL_FRAME_INTERVAL;

const string PISTOL_VIEWMODEL    = "models/weapons/wpn_pistol/v_pistol.mdl";
const string PISTOL_WORLDMODEL   = "models/weapons/wpn_pistol/w_pistol.mdl";
const string PISTOL_DEPLOY_SOUND = "";
const string PISTOL_DISPLAY_NAME = "PISTOL";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_PistolTickState =
{
    return SH_StandardTickState(now, mag_pistol, ammo_pistol, MAX_MAG_PISTOL,
        PISTOL_DRAW_DURATION, PISTOL_FIRE_DURATION,
        PISTOL_RELOAD_DURATION, PISTOL_RELOAD_APPLY_TIME);
};

float(float now) SH_PistolTryFire =
{
    return SH_StandardTryFire(now, mag_pistol, PISTOL_FIRE_DELAY, PISTOL_DRYFIRE_DELAY);
};

float(float now) SH_PistolTryReload =
{
    return SH_StandardTryReload(now, mag_pistol, ammo_pistol, MAX_MAG_PISTOL);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_PistolPickupCopy =
{
    player.mag_pistol  = self.mag_pistol;
    player.ammo_pistol = self.ammo_pistol;
};

void() W_PistolShoot =
{
    W_StandardHitscanShoot(PISTOL_BASE_SPREAD, PISTOL_MOVE_SPREAD, PISTOL_FULL_SPREAD_SPEED,
        PISTOL_CLOSE_DAMAGE, PISTOL_MIN_DAMAGE, PISTOL_DAMAGE_FALLOFF_RANGE);
};

void() W_PistolFire =
{
    float r = SH_PistolTryFire(time);

    if (r == 1)
    {
        self.weaponframe   = PISTOL_FIRE_START;
        self.wep_nextframe = time + PISTOL_FRAME_INTERVAL;

        W_PistolShoot();

        r = random();
        if (r < 0.25)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire1.wav", 1, ATTN_NORM);
        else if (r < 0.50)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire2.wav", 1, ATTN_NORM);
        else if (r < 0.75)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire3.wav", 1, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/fire4.wav", 1, ATTN_NORM);

        W_ShellEffect(SHELL_9MM, '8 6 -4', '6 46 36', '240 720 120');
    }
    else if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
    }
};

void() W_PistolReload =
{
    if (SH_PistolTryReload(time))
    {
        self.weaponframe   = PISTOL_RELOAD_START;
        self.wep_nextframe = time + PISTOL_FRAME_INTERVAL;
    }
};

void() W_PistolFrame =
{
    float result;

    self.weaponframe  += 1;
    self.wep_nextframe += PISTOL_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD)
    {
        if (self.weaponframe == PISTOL_RELOAD_SND_FRAME)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/reload.wav", 1, ATTN_NORM);
        if (self.weaponframe == PISTOL_RELOAD_MAGDROP)
        {
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/magdrop.wav", 1, ATTN_NORM);
            W_MagDropEffect(MAG_PISTOL, '4 -4 -6', '0 -30 -20');
        }
        if (self.weaponframe == PISTOL_RELOAD_APPLY)
            sound(self, CHAN_WEAPON, "sounds/weapons/wpn_pistol/deadlockreload.wav", 1, ATTN_NORM);
    }

    result = SH_PistolTickState(time);
    if (result & 1)
    {
        self.weaponframe   = PISTOL_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_PistolEquip =
{
    W_StandardEquipSetup(PISTOL_VIEWMODEL, PISTOL_DISPLAY_NAME, PISTOL_DRAW_START,
        PISTOL_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_PistolFire;
    self.reload   = W_PistolReload;
    self.wepframe = W_PistolFrame;
    self.shoot    = W_PistolShoot;
    W_SetCrosshairProfile(PISTOL_BASE_SPREAD, PISTOL_MOVE_SPREAD, PISTOL_FULL_SPREAD_SPEED, 1.5, TRUE);
};

void() W_PistolDrop =
{
    entity tgt = weapon_drop_target;

    tgt.mag_pistol  = self.mag_pistol;
    tgt.ammo_pistol = self.ammo_pistol;

    self.mag_pistol  = 0;
    self.ammo_pistol = 0;

    setmodel(tgt, "models/weapons/wpn_pistol/w_pistol.mdl");
    setsize(tgt, '-12 -12 0', '12 12 24');
    tgt.classname    = "weapon_pistol";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_PISTOL;
    tgt.weapon_slot  = SLOT_SECONDARY;
    tgt.weap_draw    = W_PistolEquip;
    tgt.weap_drop_func = W_PistolDrop;
    tgt.pickupcopy   = W_PistolPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_pistol =
{
    setmodel(self, "models/weapons/wpn_pistol/w_pistol.mdl");
    setsize(self, '-12 -12 0', '12 12 24');
    self.classname     = "weapon_pistol";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_PISTOL;
    self.weapon_slot   = SLOT_SECONDARY;
    self.weap_draw     = W_PistolEquip;
    self.weap_drop_func = W_PistolDrop;
    self.pickupcopy    = W_PistolPickupCopy;
    self.touch         = weapon_touch;
    self.mag_pistol    = MAX_MAG_PISTOL;
    self.ammo_pistol   = MAX_AMMO_PISTOL;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

const float PISTOL_RELOAD_MAGDROP_TIME = (PISTOL_RELOAD_MAGDROP - PISTOL_RELOAD_START) * PISTOL_FRAME_INTERVAL;
float csqc_pistol_reload_snd_stage;

void() CSQC_PredictPistolCommand =
{
    float r;

    if (input_buttons & 1)
    {
        r = SH_PistolTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                r = random();
                if (r < 0.25)
                    localsound("sounds/weapons/wpn_pistol/fire1.wav");
                else if (r < 0.50)
                    localsound("sounds/weapons/wpn_pistol/fire2.wav");
                else if (r < 0.75)
                    localsound("sounds/weapons/wpn_pistol/fire3.wav");
                else
                    localsound("sounds/weapons/wpn_pistol/fire4.wav");
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedImpact(PISTOL_BASE_SPREAD, PISTOL_MOVE_SPREAD, PISTOL_FULL_SPREAD_SPEED);
                CSQC_SpawnCasing("models/weapons/9mmcasing.mdl",
                    '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                localsound("sounds/weapons/dryfire1.wav");
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Predicted reload sounds — mag drop
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        if (csqc_pistol_reload_snd_stage < 1 && reload_elapsed >= PISTOL_RELOAD_MAGDROP_TIME)
        {
            localsound("sounds/weapons/wpn_pistol/magdrop.wav"); CSQC_RecordPredictedAutoSound();
            CSQC_SpawnMag("models/weapons/pistolmag.mdl", '4 -4 -6', '0 -30 -20', '4 8 8', '0 180 0', '0 90 90');
            csqc_pistol_reload_snd_stage = 1;
        }
    }

    SH_PistolTickState(csqc_pred_time);
};

void() CSQC_PredictPistolReload =
{
    if (SH_PistolTryReload(csqc_pred_time))
    { csqc_pistol_reload_snd_stage = 0; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_PistolDisplayFrame =
{
    return CSQC_StandardDisplayFrame(elapsed, PISTOL_FRAME_INTERVAL,
        PISTOL_DRAW_START, PISTOL_DRAW_END,
        PISTOL_FIRE_START, PISTOL_FIRE_END,
        PISTOL_RELOAD_START, PISTOL_RELOAD_END,
        PISTOL_IDLE_FRAME);
};

void() CSQC_PistolDropClear =
{
	self.mag_pistol = 0;
	self.ammo_pistol = 0;
};

void() CSQC_PistolEquip =
{
	self.weapon_name         = PISTOL_DISPLAY_NAME;
	self.weapon_viewmodel    = PISTOL_VIEWMODEL;
	self.weapon_worldmodel   = PISTOL_WORLDMODEL;
	self.weapon_deploy_sound = PISTOL_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictPistolCommand;
	self.csqc_predict_reload = CSQC_PredictPistolReload;
	self.csqc_display_frame  = CSQC_PistolDisplayFrame;
	self.csqc_drop_clear     = CSQC_PistolDropClear;
};

#endif // CSQC
