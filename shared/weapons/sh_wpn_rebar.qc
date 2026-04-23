// ============================================================
//  shared/weapons/sh_wpn_rebar.qc  -  Rebar Gun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 12-bolt magazine, no reserve, hitscan
//  Fire  : lag-compensated hitscan, linear damage falloff
//         Spawns a stuck rebar model at the hit point (server only)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_rebar;

// --- Animation frames ---
const float REBAR_FRAME_INTERVAL      = 0.05;   // 1/20

const float REBAR_DRAW_START          = 1;
const float REBAR_DRAW_END            = 10;

const float REBAR_FIRE_START          = 11;
const float REBAR_FIRE_END            = 31;
const float REBAR_FIRE_DELAY          = 0.6;

const float REBAR_EMPTY_FIRE_END      = 17;
const float REBAR_EMPTY_IDLE_FRAME    = 17;
const float REBAR_IDLE_FRAME          = 0;

const float MAX_MAG_REBAR             = 12;

// --- Balance ---
const float REBAR_CLOSE_DAMAGE        = 110;
const float REBAR_MIN_DAMAGE          = 100;
const float REBAR_DAMAGE_FALLOFF_RANGE = 4096;
const float REBAR_DRYFIRE_DELAY       = 0.2;
const float REBAR_VISUAL_SPEED        = 3000;   // visual projectile speed (hitscan is instant, this is cosmetic)

// --- Pre-computed durations ---
const float REBAR_DRAW_DURATION       = (REBAR_DRAW_END - REBAR_DRAW_START) * REBAR_FRAME_INTERVAL;
const float REBAR_FIRE_DURATION       = (REBAR_FIRE_END - REBAR_FIRE_START) * REBAR_FRAME_INTERVAL;

const string REBAR_VIEWMODEL    = "models/weapons/wpn_rebar/v_rebar.mdl";
const string REBAR_WORLDMODEL   = "models/weapons/wpn_rebar/w_rebar.mdl";
const string REBAR_DEPLOY_SOUND = "";
const string REBAR_DISPLAY_NAME = "REBAR";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_RebarTickState =
{
    return SH_SimpleTickState(now, REBAR_DRAW_DURATION, REBAR_FIRE_DURATION);
};

// REBAR_FIRE_DELAY (0.6) < REBAR_FIRE_DURATION (1.0), so we must block
// re-fire during WS_FIRE.  SH_StandardTryFire only blocks RELOAD/DRAW,
// so add an explicit idle gate before delegating.
float(float now) SH_RebarTryFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    return SH_StandardTryFire(now, mag_rebar, REBAR_FIRE_DELAY, REBAR_DRYFIRE_DELAY);
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_RebarPickupCopy =
{ player.mag_rebar = self.mag_rebar; };

void() W_RebarStuckThink =
{ remove(self); };

void() W_RebarShoot =
{
    vector src, dir, end;
    float dist, damage, saved_dim;
    entity stuck;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    dir = v_forward;
    end = src + dir * 8192;

    W_WeaponTraceLine(src, end);

    if (trace_fraction < 1.0)
    {
        dist = vlen(trace_endpos - src);

        if (W_CanDamageTarget(trace_ent))
        {
            damage = W_LinearDamageFalloff(dist, REBAR_CLOSE_DAMAGE, REBAR_MIN_DAMAGE, REBAR_DAMAGE_FALLOFF_RANGE);
            W_ApplyDamage(self, trace_ent, damage);
        }
        else
        {
            W_ImpactEffect(trace_endpos);

            // Spawn stuck rebar visual — offset out of the wall along surface normal
            stuck = spawn();
            setmodel(stuck, "models/weapons/wpn_rebar/rebar.mdl");
            setorigin(stuck, trace_endpos + trace_plane_normal * 2);
            stuck.angles = vectoangles(dir);
            stuck.solid = SOLID_NOT;
            stuck.movetype = MOVETYPE_NONE;
            stuck.nodrawtoclient = self;   // shooter sees client-predicted one
            stuck.think = W_RebarStuckThink;
            stuck.nextthink = time + 30;
        }

        W_DebugImpact(trace_endpos, W_LinearDamageFalloff(dist, REBAR_CLOSE_DAMAGE, REBAR_MIN_DAMAGE, REBAR_DAMAGE_FALLOFF_RANGE), W_BoneToHitgroup(trace_bone_id));

        // Exclude shooter from stick sound — they hear it from client prediction
        saved_dim = dimension_send;
        dimension_send = dimension_send & ~self.dimension_seen;
        W_MulticastSound(trace_endpos, "sounds/weapons/wpn_rebar/stick.wav");
        dimension_send = saved_dim;
    }
};

void() W_RebarFire =
{
    float r = SH_RebarTryFire(time);
    if (r == 1)
    {
        self.weaponframe = REBAR_FIRE_START;
        self.wep_nextframe = time + REBAR_FRAME_INTERVAL;
        W_RebarShoot();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_rebar/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_RebarFrame =
{
    float result;
    self.weaponframe += 1;
    self.wep_nextframe += REBAR_FRAME_INTERVAL;

    result = SH_RebarTickState(time);
    if (result & 1)
    {
        if (self.mag_rebar <= 0)
            self.weaponframe = REBAR_EMPTY_IDLE_FRAME;
        else
            self.weaponframe = REBAR_IDLE_FRAME;
        self.wep_nextframe = 0;
    }
};

void() W_RebarEquip =
{
    W_StandardEquipSetup(REBAR_VIEWMODEL, REBAR_DISPLAY_NAME, REBAR_DRAW_START, REBAR_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_RebarFire;
    self.reload   = __NULL__;
    self.wepframe = W_RebarFrame;
    self.shoot    = W_RebarShoot;
    W_SetCrosshairProfile(0, 0, 320, 1, TRUE);
};

void() W_RebarDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_rebar = self.mag_rebar;
    self.mag_rebar = 0;
    setmodel(tgt, "models/weapons/wpn_rebar/w_rebar.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_rebar"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_REBAR; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_RebarEquip; tgt.weap_drop_func = W_RebarDrop;
    tgt.pickupcopy = W_RebarPickupCopy; tgt.touch = weapon_touch;
    tgt.dropped_spin = 1;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_rebar =
{
    setmodel(self, "models/weapons/wpn_rebar/w_rebar.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_rebar"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_REBAR; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_RebarEquip; self.weap_drop_func = W_RebarDrop;
    self.pickupcopy = W_RebarPickupCopy; self.touch = weapon_touch;
    self.dropped_spin = 1;
    self.mag_rebar = MAX_MAG_REBAR;
    W_RegisterMapWeapon(weapon_rebar);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictRebarCommand =
{
    float r;
    if (input_buttons & 1)
    {
        r = SH_RebarTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_rebar/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_MuzzleFlash();

                // Instant hitscan trace — spawn stuck rebar + impact at hit point
                {
                    makevectors(input_angles);
                    vector fire_dir = v_forward;
                    vector fire_org = self.origin + self.view_ofs + fire_dir * 16;
                    traceline(fire_org, fire_org + fire_dir * 8192, MOVE_NORMAL, self);
                    if (trace_fraction < 1.0)
                    {
                        vector hit_pos = trace_endpos;
                        vector hit_normal = trace_plane_normal;
                        float  hit_damage = W_LinearDamageFalloff(
                            vlen(hit_pos - fire_org),
                            REBAR_CLOSE_DAMAGE, REBAR_MIN_DAMAGE, REBAR_DAMAGE_FALLOFF_RANGE);

                        CSQC_BulletImpact(hit_pos, hit_normal, hit_damage);
                        if (cvar("cl_debug_impacts"))
                            CSQC_AddDebugImpact(hit_pos, fire_org, '0 1 0', 0, 0);
                        localsound("sounds/weapons/wpn_rebar/stick.wav");

                        entity stuck = spawn();
                        setmodel(stuck, "models/weapons/wpn_rebar/rebar.mdl");
                        setorigin(stuck, hit_pos + hit_normal * 2);
                        stuck.angles = vectoangles(fire_dir);
                        stuck.movetype = MOVETYPE_NONE;
                        stuck.solid = SOLID_NOT;
                        stuck.drawmask = MASK_ENGINE;
                        stuck.think = CSQC_FakeProjectileExpire;
                        stuck.nextthink = time + 30;
                    }
                }
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }
    SH_RebarTickState(csqc_pred_time);
};

float(float elapsed) CSQC_RebarDisplayFrame =
{
    float frame = CSQC_StandardDisplayFrame(elapsed, REBAR_FRAME_INTERVAL,
        REBAR_DRAW_START, REBAR_DRAW_END,
        REBAR_FIRE_START, REBAR_FIRE_END,
        0, 0,
        REBAR_IDLE_FRAME);

    // Empty-mag idle uses a different frame
    if (predicted_player.weaponstate == WS_IDLE && predicted_player.mag_rebar <= 0)
        return REBAR_EMPTY_IDLE_FRAME;

    return frame;
};

void() CSQC_RebarDropClear =
{
	self.mag_rebar = 0;
};

void() CSQC_RebarEquip =
{
	self.weapon_name         = REBAR_DISPLAY_NAME;
	self.weapon_viewmodel    = REBAR_VIEWMODEL;
	self.weapon_worldmodel   = REBAR_WORLDMODEL;
	self.weapon_deploy_sound = REBAR_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictRebarCommand;
	self.csqc_predict_reload = __NULL__;
	self.csqc_display_frame  = CSQC_RebarDisplayFrame;
	self.csqc_drop_clear     = CSQC_RebarDropClear;
};

#endif // CSQC
