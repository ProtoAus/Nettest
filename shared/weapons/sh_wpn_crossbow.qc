// ============================================================
//  shared/weapons/sh_wpn_crossbow.qc  -  HL Crossbow
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 5-bolt magazine, 10 reserve
//  Fire  : spawns bolt projectile (MOVETYPE_FLYMISSILE)
//         Scoped: higher damage (120), unscoped: lower (50)
//  Scope : toggle zoom via alt-fire
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_crossbow;
.float ammo_crossbow;
.float proj_damage;   // damage stored on projectile entity

// --- Animation frames ---
const float XBOW_FRAME_INTERVAL       = 0.05;   // 1/20

const float XBOW_DRAW_LOADED_START    = 1;
const float XBOW_DRAW_LOADED_END      = 10;
const float XBOW_DRAW_EMPTY_START     = 11;
const float XBOW_DRAW_EMPTY_END       = 21;

const float XBOW_FIRE_START           = 22;
const float XBOW_FIRE_END             = 59;
const float XBOW_FIRE_EMPTY_END       = 70;
const float XBOW_FIRE_RELOAD_FRAME    = 40;
const float XBOW_FIRE_DELAY           = 0.75;

const float XBOW_RELOAD_START         = 71;
const float XBOW_RELOAD_END           = 139;
const float XBOW_RELOAD_SOUND_FRAME   = 108;
const float XBOW_RELOAD_APPLY         = 139;

const float XBOW_LOADED_IDLE_FRAME    = 140;
const float XBOW_EMPTY_IDLE_FRAME     = 70;

const float MAX_MAG_CROSSBOW          = 5;
const float MAX_AMMO_CROSSBOW         = 10;

// --- Balance ---
const float XBOW_PROJECTILE_SPEED     = 3000;
const float XBOW_PROJECTILE_DAMAGE    = 50;
const float XBOW_SCOPED_DAMAGE        = 120;
const float XBOW_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed durations ---
const float XBOW_DRAW_DURATION        = (XBOW_DRAW_LOADED_END - XBOW_DRAW_LOADED_START) * XBOW_FRAME_INTERVAL;
const float XBOW_FIRE_DURATION        = (XBOW_FIRE_END - XBOW_FIRE_START) * XBOW_FRAME_INTERVAL;
const float XBOW_FIRE_EMPTY_DURATION  = (XBOW_FIRE_EMPTY_END - XBOW_FIRE_START) * XBOW_FRAME_INTERVAL;
const float XBOW_RELOAD_DURATION      = (XBOW_RELOAD_END - XBOW_RELOAD_START) * XBOW_FRAME_INTERVAL;
const float XBOW_RELOAD_APPLY_TIME    = (XBOW_RELOAD_APPLY - XBOW_RELOAD_START) * XBOW_FRAME_INTERVAL;

const string CROSSBOW_VIEWMODEL    = "models/weapons/wpn_hlcrossbow/v_crossbow.mdl";
const string CROSSBOW_WORLDMODEL   = "models/weapons/wpn_hlcrossbow/w_crossbow.mdl";
const string CROSSBOW_DEPLOY_SOUND = "";
const string CROSSBOW_DISPLAY_NAME = "CROSSBOW";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_CrossbowTickState =
{
    // Use longer empty fire duration when mag is empty
    float fire_dur = (self.mag_crossbow <= 0) ? XBOW_FIRE_EMPTY_DURATION : XBOW_FIRE_DURATION;
    return SH_StandardTickState(now, mag_crossbow, ammo_crossbow, MAX_MAG_CROSSBOW,
        XBOW_DRAW_DURATION, fire_dur,
        XBOW_RELOAD_DURATION, XBOW_RELOAD_APPLY_TIME);
};

float(float now) SH_CrossbowTryFire =
{
    // Don't clear zoomstage here — Fire needs it to decide hitscan vs projectile.
    // Cleared in W_CrossbowFire / CSQC prediction AFTER the shot.
    return SH_StandardTryFire(now, mag_crossbow, XBOW_FIRE_DELAY, XBOW_DRYFIRE_DELAY);
};

float(float now) SH_CrossbowTryReload =
{
    float r = SH_StandardTryReload(now, mag_crossbow, ammo_crossbow, MAX_MAG_CROSSBOW);
    if (r == 1)
        self.zoomstage = 0;   // unscope on reload
    return r;
};

float(float now) SH_CrossbowTryAltFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.zoomstage > 0)
        self.zoomstage = 0;
    else
        self.zoomstage = 2;   // single zoom stage (full zoom)

    self.attack_finished = now + 0.3;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_CrossbowPickupCopy =
{ player.mag_crossbow = self.mag_crossbow; player.ammo_crossbow = self.ammo_crossbow; };

// Bolt projectile touch
void() W_CrossbowBoltTouch =
{
    float damage;
    float saved_dim;

    if (other == self.owner)
        return;

    // Exclude shooter from impact sounds — they already heard it client-side
    saved_dim = dimension_send;
    if (self.owner)
        dimension_send = dimension_send & ~self.owner.dimension_seen;

    if (W_CanDamageTarget(other))
    {
        damage = self.proj_damage;
        W_ApplyDamage(self.owner, other, damage);
        if (random() < 0.5)
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hitbody1.wav");
        else
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hitbody2.wav");
    }
    else
    {
        if (random() < 0.5)
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hit1.wav");
        else
            W_MulticastSound(self.origin, "sounds/weapons/wpn_hlcrossbow/hit2.wav");

        // Spawn stuck bolt visual
        entity stuck = spawn();
        setmodel(stuck, "models/weapons/wpn_rebar/rebar.mdl");
        setorigin(stuck, self.origin);
        stuck.angles = self.angles;
        stuck.solid = SOLID_NOT;
        stuck.movetype = MOVETYPE_NONE;
        stuck.think = sub_remove;
        stuck.nextthink = time + 20;
    }

    dimension_send = saved_dim;
    remove(self);
};

void() W_CrossbowBoltThink =
{
    remove(self);
};

void() W_CrossbowFire =
{
    float r;
    entity bolt;

    r = SH_CrossbowTryFire(time);
    if (r == 1)
    {
        self.weaponframe = XBOW_FIRE_START;
        self.wep_nextframe = time + XBOW_FRAME_INTERVAL;

        makevectors(self.v_angle);

        if (self.zoomstage > 0)
        {
            // Scoped: instant hitscan + stick rebar in wall
            vector src = self.origin + self.view_ofs;
            vector dir = v_forward;
            W_WeaponTraceLine(src, src + dir * 8192);

            if (trace_fraction < 1.0)
            {
                if (W_CanDamageTarget(trace_ent))
                    W_ApplyDamage(self, trace_ent, XBOW_SCOPED_DAMAGE);
                else
                {
                    W_ImpactEffect(trace_endpos);

                    entity stuck = spawn();
                    setmodel(stuck, "models/weapons/wpn_rebar/rebar.mdl");
                    setorigin(stuck, trace_endpos + trace_plane_normal * 2);
                    stuck.angles = vectoangles(dir);
                    stuck.solid = SOLID_NOT;
                    stuck.movetype = MOVETYPE_NONE;
                    stuck.nodrawtoclient = self;
                    stuck.think = sub_remove;
                    stuck.nextthink = time + 20;
                }

                // Impact sound — exclude shooter
                {
                    float saved_dim = dimension_send;
                    dimension_send = dimension_send & ~self.dimension_seen;
                    if (random() < 0.5)
                        W_MulticastSound(trace_endpos, "sounds/weapons/wpn_hlcrossbow/hit1.wav");
                    else
                        W_MulticastSound(trace_endpos, "sounds/weapons/wpn_hlcrossbow/hit2.wav");

                    // Debug: send server hit to shooter only
                    dimension_send = self.dimension_seen;
                    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
                    WriteByte(MSG_MULTICAST, CSQC_EVENT_DEBUG_IMPACT);
                    WriteCoord(MSG_MULTICAST, trace_endpos_x);
                    WriteCoord(MSG_MULTICAST, trace_endpos_y);
                    WriteCoord(MSG_MULTICAST, trace_endpos_z);
                    multicast(trace_endpos, MULTICAST_PVS);

                    dimension_send = saved_dim;
                }
            }
        }
        else
        {
            // Unscoped: projectile bolt
            bolt = spawn();
            bolt.owner = self;
            bolt.classname = "proj_crossbow_bolt";
            bolt.movetype = MOVETYPE_FLYMISSILE;
            bolt.solid = SOLID_BBOX;
            setmodel(bolt, "models/weapons/wpn_rebar/rebar.mdl");
            setsize(bolt, '-1 -1 -1', '1 1 1');
            setorigin(bolt, self.origin + self.view_ofs + v_forward * 16);
            bolt.velocity = v_forward * XBOW_PROJECTILE_SPEED;
            bolt.angles = vectoangles(bolt.velocity);
            bolt.proj_damage = XBOW_PROJECTILE_DAMAGE;
            bolt.touch = W_CrossbowBoltTouch;
            bolt.think = W_CrossbowBoltThink;
            bolt.nextthink = time + 5;
            bolt.nodrawtoclient = self;
        }

        self.zoomstage = 0;
        self.sv_zoomstage = 0;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrossbow/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_CrossbowAltFire =
{
    if (SH_CrossbowTryAltFire(time))
    {
        self.sv_zoomstage = self.zoomstage;
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csawp/zoom.wav", 1, ATTN_NORM);
    }
};

void() W_CrossbowReload =
{
    if (SH_CrossbowTryReload(time))
    {
        self.weaponframe = XBOW_RELOAD_START;
        self.wep_nextframe = time + XBOW_FRAME_INTERVAL;
        self.sv_zoomstage = 0;
    }
};

void() W_CrossbowFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += XBOW_FRAME_INTERVAL;

    if (self.weaponstate == WS_RELOAD && self.weaponframe == XBOW_RELOAD_SOUND_FRAME)
        sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlcrossbow/reload.wav", 1, ATTN_NORM);

    result = SH_CrossbowTickState(time);
    if (result & 1)
    {
        if (self.mag_crossbow <= 0)
            self.weaponframe = XBOW_EMPTY_IDLE_FRAME;
        else
            self.weaponframe = XBOW_LOADED_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_CrossbowEquip =
{
    float draw_start = (self.mag_crossbow > 0) ? XBOW_DRAW_LOADED_START : XBOW_DRAW_EMPTY_START;
    W_StandardEquipSetup(CROSSBOW_VIEWMODEL, CROSSBOW_DISPLAY_NAME, draw_start,
        XBOW_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_CrossbowFire;
    self.reload   = W_CrossbowReload;
    self.wepframe = W_CrossbowFrame;
    self.altfire  = W_CrossbowAltFire;
    W_ClearZoom();
    W_SetCrosshairProfile(0, 0, 320, 1, FALSE);
};

void() W_CrossbowDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_crossbow = self.mag_crossbow; tgt.ammo_crossbow = self.ammo_crossbow;
    self.mag_crossbow = 0; self.ammo_crossbow = 0;
    setmodel(tgt, "models/weapons/wpn_hlcrossbow/w_crossbow.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_crossbow"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CROSSBOW; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_CrossbowEquip; tgt.weap_drop_func = W_CrossbowDrop;
    tgt.pickupcopy = W_CrossbowPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_crossbow =
{
    setmodel(self, "models/weapons/wpn_hlcrossbow/w_crossbow.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_crossbow"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CROSSBOW; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_CrossbowEquip; self.weap_drop_func = W_CrossbowDrop;
    self.pickupcopy = W_CrossbowPickupCopy; self.touch = weapon_touch;
    self.mag_crossbow = MAX_MAG_CROSSBOW; self.ammo_crossbow = MAX_AMMO_CROSSBOW;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_xbow_reload_snd_played;
const float XBOW_RELOAD_SND_TIME = (XBOW_RELOAD_SOUND_FRAME - XBOW_RELOAD_START) * XBOW_FRAME_INTERVAL;

void() CSQC_PredictCrossbowCommand =
{
    float r;

    // Alt-fire: zoom toggle
    if (input_buttons & 4)
    {
        if (SH_CrossbowTryAltFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { localsound("sounds/weapons/wpn_csawp/zoom.wav"); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Primary fire
    if (input_buttons & 1)
    {
        r = SH_CrossbowTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlcrossbow/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();

                makevectors(input_angles);
                vector fire_org = self.origin + self.view_ofs + v_forward * 16;
                vector fire_dir = v_forward;

                if (self.zoomstage > 0)
                {
                    // Scoped: instant hitscan trace + stuck rebar
                    traceline(fire_org, fire_org + fire_dir * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        vector hit_pos = trace_endpos;
                        vector hit_normal = trace_plane_normal;

                        CSQC_BulletImpact(hit_pos, hit_normal);
                        if (cvar("cl_debug_impacts"))
                            CSQC_AddDebugImpact(hit_pos, fire_org, '0 1 0');
                        if (random() < 0.5)
                            localsound("sounds/weapons/wpn_hlcrossbow/hit1.wav");
                        else
                            localsound("sounds/weapons/wpn_hlcrossbow/hit2.wav");

                        entity stuck = spawn();
                        setmodel(stuck, "models/weapons/wpn_rebar/rebar.mdl");
                        setorigin(stuck, hit_pos + hit_normal * 2);
                        stuck.angles = vectoangles(fire_dir);
                        stuck.movetype = MOVETYPE_NONE;
                        stuck.solid = SOLID_NOT;
                        stuck.drawmask = MASK_ENGINE;
                        stuck.think = CSQC_FakeProjectileExpire;
                        stuck.nextthink = time + 20;
                    }
                }
                else
                {
                    // Unscoped: fake flying bolt
                    entity bolt = spawn();
                    float hit_dist, travel_time;

                    setmodel(bolt, "models/weapons/wpn_rebar/rebar.mdl");
                    setorigin(bolt, fire_org);
                    bolt.velocity = fire_dir * XBOW_PROJECTILE_SPEED;
                    bolt.angles = vectoangles(bolt.velocity);
                    bolt.movetype = MOVETYPE_NOCLIP;
                    bolt.solid = SOLID_NOT;
                    bolt.drawmask = MASK_ENGINE;

                    traceline(fire_org, fire_org + fire_dir * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        hit_dist = vlen(trace_endpos - fire_org);
                        travel_time = hit_dist / XBOW_PROJECTILE_SPEED;
                        bolt.fake_proj_hitpos = trace_endpos + trace_plane_normal * 2;
                        bolt.fake_proj_hitsnd = (random() < 0.5) ? "sounds/weapons/wpn_hlcrossbow/hit1.wav" : "sounds/weapons/wpn_hlcrossbow/hit2.wav";
                        bolt.think = CSQC_FakeProjectileStick;
                        bolt.nextthink = time + travel_time;
                    }
                    else
                    {
                        bolt.think = CSQC_FakeProjectileExpire;
                        bolt.nextthink = time + 3;
                    }
                }
            }
            self.zoomstage = 0;
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted reload sound
    if (self.weaponstate == WS_RELOAD && !csqc_xbow_reload_snd_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= XBOW_RELOAD_SND_TIME)
        { localsound("sounds/weapons/wpn_hlcrossbow/reload.wav"); CSQC_RecordPredictedAutoSound(); csqc_xbow_reload_snd_played = TRUE; }
    }

    SH_CrossbowTickState(csqc_pred_time);
};

void() CSQC_PredictCrossbowReload =
{
    if (SH_CrossbowTryReload(csqc_pred_time))
    { csqc_xbow_reload_snd_played = FALSE; CSQC_MarkPendingWeaponAck(); }
};

float(float elapsed) CSQC_CrossbowDisplayFrame =
{
    float draw_start = (predicted_player.mag_crossbow > 0) ? XBOW_DRAW_LOADED_START : XBOW_DRAW_EMPTY_START;
    float draw_end   = (predicted_player.mag_crossbow > 0) ? XBOW_DRAW_LOADED_END : XBOW_DRAW_EMPTY_END;
    float fire_end   = (predicted_player.mag_crossbow <= 0) ? XBOW_FIRE_EMPTY_END : XBOW_FIRE_END;
    float idle_frame = (predicted_player.mag_crossbow <= 0) ? XBOW_EMPTY_IDLE_FRAME : XBOW_LOADED_IDLE_FRAME;

    return CSQC_StandardDisplayFrame(elapsed, XBOW_FRAME_INTERVAL,
        draw_start, draw_end,
        XBOW_FIRE_START, fire_end,
        XBOW_RELOAD_START, XBOW_RELOAD_END,
        idle_frame);
};

void() CSQC_CrossbowDropClear =
{
	self.mag_crossbow = 0;
	self.ammo_crossbow = 0;
	self.zoomstage = 0;
};

void() CSQC_CrossbowEquip =
{
	self.weapon_name         = CROSSBOW_DISPLAY_NAME;
	self.weapon_viewmodel    = CROSSBOW_VIEWMODEL;
	self.weapon_worldmodel   = CROSSBOW_WORLDMODEL;
	self.weapon_deploy_sound = CROSSBOW_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictCrossbowCommand;
	self.csqc_predict_reload = CSQC_PredictCrossbowReload;
	self.csqc_display_frame  = CSQC_CrossbowDisplayFrame;
	self.csqc_drop_clear     = CSQC_CrossbowDropClear;
};

#endif // CSQC
