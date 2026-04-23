// ============================================================
//  shared/weapons/sh_wpn_csm3.qc  -  CS M3 Super 90
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell tube, 24 reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//  Reload: Shell-by-shell insertion (frame-driven loop)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_m3;
.float ammo_m3;

// --- Animation frames ---
const float M3_FRAME_INTERVAL         = 0.0333334;   // 1/30

const float M3_DRAW_START             = 1;
const float M3_DRAW_END               = 21;
const float M3_DRAW_PUMP_FRAME        = 14;

const float M3_FIRE_START             = 30;
const float M3_FIRE_END               = 53;
const float M3_FIRE_EJECT_FRAME       = 42;
const float M3_FIRE_DELAY             = 1.0;

const float M3_ALT_FIRE_START         = 54;
const float M3_ALT_FIRE_END           = 74;
const float M3_ALT_FIRE_EJECT_FRAME   = 62;
const float M3_ALT_FIRE_DELAY         = 0.9;

const float M3_RELOAD_START           = 75;
const float M3_RELOAD_LOOP_RESTART    = 84;
const float M3_RELOAD_INSERT_FRAME    = 88;
const float M3_RELOAD_LOOP_END        = 95;
const float M3_RELOAD_PUMP_FRAME      = 100;
const float M3_RELOAD_END             = 111;

const float M3_IDLE_FRAME             = 21;   // M3_DRAW_END

const float MAX_MAG_M3                = 8;
const float MAX_AMMO_M3               = 24;

// --- Balance ---
const float M3_PELLETS                = 12;
const float M3_SPREAD                 = 0.08;
const float M3_PELLET_CLOSE_DAMAGE    = 15;
const float M3_PELLET_MIN_DAMAGE      = 4;
const float M3_PELLET_FALLOFF_RANGE   = 1024;
const float M3_DRYFIRE_DELAY          = 0.2;

const string M3_VIEWMODEL    = "models/weapons/wpn_csm3/v_m3.mdl";
const string M3_WORLDMODEL   = "models/weapons/wpn_csm3/w_m3.mdl";
const string M3_DEPLOY_SOUND = "";
const string M3_DISPLAY_NAME = "M3";

// --- Pre-computed durations ---
const float M3_DRAW_DURATION          = (M3_DRAW_END - M3_DRAW_START) * M3_FRAME_INTERVAL;
const float M3_FIRE_DURATION          = (M3_FIRE_END - M3_FIRE_START) * M3_FRAME_INTERVAL;
const float M3_ALT_FIRE_DURATION      = (M3_ALT_FIRE_END - M3_ALT_FIRE_START) * M3_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine + try functions
// ============================================================

float(float now) SH_M3TickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE || self.weaponstate == WS_RELOAD)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= M3_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        // Use longer of the two fire anim durations
        if (elapsed >= M3_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_M3TryFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_m3 <= 0)
    { self.attack_finished = now + M3_DRYFIRE_DELAY; return -1; }

    self.mag_m3          -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + M3_FIRE_DELAY;
    return 1;
};

float(float now) SH_M3TryReload =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_m3 >= MAX_MAG_M3 || self.ammo_m3 <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_M3PickupCopy =
{ player.mag_m3 = self.mag_m3; player.ammo_m3 = self.ammo_m3; };

void() W_M3FirePellets =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    for (i = 0; i < M3_PELLETS; i++)
    {
        sx = SH_SpreadJitter(self.wep_action_id + i, 0) * M3_SPREAD;
        sy = SH_SpreadJitter(self.wep_action_id + i, 1) * M3_SPREAD;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            if (W_CanDamageTarget(trace_ent))
            {
                damage = W_LinearDamageFalloff(dist, M3_PELLET_CLOSE_DAMAGE, M3_PELLET_MIN_DAMAGE, M3_PELLET_FALLOFF_RANGE);
                W_ApplyDamage(self, trace_ent, damage);
                if (trace_ent.classname == "player")
                {
                    float pelletmat = IMPACT_MAT_FLESH;
                    float pellet_hg = W_BoneToHitgroup(trace_bone_id);
                    if (pellet_hg == HITGROUP_HEAD || trace_ent.health <= 0)
                        pelletmat = IMPACT_MAT_FLESH_LETHAL;
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, pelletmat);
                }
                else
                {
                    // Breakable — auto-classify; flesh breakables get the
                    // lethal upgrade on the killing pellet.
                    float bmat = W_ClassifyImpactMaterial(trace_ent);
                    if (bmat == IMPACT_MAT_FLESH && trace_ent.health <= 0)
                        bmat = IMPACT_MAT_FLESH_LETHAL;
                    W_ImpactEffectAllMat(trace_endpos, trace_plane_normal, bmat);
                }
            }
            else
                W_ImpactEffect(trace_endpos);

            W_DebugImpact(trace_endpos, W_LinearDamageFalloff(dist, M3_PELLET_CLOSE_DAMAGE, M3_PELLET_MIN_DAMAGE, M3_PELLET_FALLOFF_RANGE), W_BoneToHitgroup(trace_bone_id));
        }
    }
};

void() W_M3Fire =
{
    float r = SH_M3TryFire(time);
    if (r == 1)
    {
        // Randomly pick fire animation variant
        if (random() < 0.5)
        {
            self.weaponframe = M3_FIRE_START;
            self.attack_finished = time + M3_FIRE_DELAY;
        }
        else
        {
            self.weaponframe = M3_ALT_FIRE_START;
            self.attack_finished = time + M3_ALT_FIRE_DELAY;
        }

        self.wep_nextframe = time + M3_FRAME_INTERVAL;
        W_M3FirePellets();
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm3/fire.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_M3Reload =
{
    if (SH_M3TryReload(time))
    { self.weaponframe = M3_RELOAD_START; self.wep_nextframe = time + M3_FRAME_INTERVAL; }
};

void() W_M3Frame =
{
    self.weaponframe += 1;
    self.wep_nextframe += M3_FRAME_INTERVAL;

    // --- Draw ---
    if (self.weaponstate == WS_DRAW)
    {
        if (self.weaponframe == M3_DRAW_PUMP_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm3/pump.wav", 1, ATTN_NORM);

        if (self.weaponframe >= M3_DRAW_END)
        {
            self.weaponframe = M3_IDLE_FRAME;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Fire (handles both primary and alt fire anim ranges) ---
    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == M3_FIRE_EJECT_FRAME || self.weaponframe == M3_ALT_FIRE_EJECT_FRAME)
            W_ShellEffect(SHELL_SHOTGUN1, '8 6 -4', '6 46 36', '240 720 120');

        if (self.weaponframe >= M3_ALT_FIRE_START)
        {
            if (self.weaponframe >= M3_ALT_FIRE_END)
            {
                self.weaponframe = M3_IDLE_FRAME;
                self.weaponstate = WS_IDLE;
                self.wep_anim_start = 0;
                self.wep_nextframe = 0;
            }
        }
        else
        {
            if (self.weaponframe >= M3_FIRE_END)
            {
                self.weaponframe = M3_IDLE_FRAME;
                self.weaponstate = WS_IDLE;
                self.wep_anim_start = 0;
                self.wep_nextframe = 0;
            }
        }
        return;
    }

    // --- Shell-by-shell reload (frame-driven loop) ---
    if (self.weaponstate == WS_RELOAD)
    {
        // Insert shell at insert frame
        if (self.weaponframe == M3_RELOAD_INSERT_FRAME
            && self.mag_m3 < MAX_MAG_M3 && self.ammo_m3 > 0)
        {
            self.mag_m3 += 1;
            self.ammo_m3 -= 1;
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm3/insertshell.wav", 1, ATTN_NORM);
        }

        // At loop end: restart if more shells needed
        if (self.weaponframe >= M3_RELOAD_LOOP_END)
        {
            if (self.mag_m3 < MAX_MAG_M3 && self.ammo_m3 > 0)
            {
                self.weaponframe = M3_RELOAD_LOOP_RESTART;
                return;
            }
        }

        // Pump sound during exit
        if (self.weaponframe == M3_RELOAD_PUMP_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_csm3/pump.wav", 1, ATTN_NORM);

        // Reload complete
        if (self.weaponframe >= M3_RELOAD_END)
        {
            self.weaponframe = M3_IDLE_FRAME;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // Fallback
    self.weaponframe = M3_IDLE_FRAME;
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe = 0;
};

void() W_M3Equip =
{
    self.weaponmodel = M3_VIEWMODEL;
    self.weapon_name = M3_DISPLAY_NAME;
    self.weapon_draw_start_frame = M3_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_M3Fire; self.reload = W_M3Reload; self.wepframe = W_M3Frame;
    self.altfire = __NULL__; self.altrelease = __NULL__;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = M3_DRAW_START;
    self.wep_nextframe = time + M3_FRAME_INTERVAL;
    W_SetCrosshairProfile(M3_SPREAD, 0, 320, 3, TRUE);
};

void() W_M3Drop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_m3 = self.mag_m3; tgt.ammo_m3 = self.ammo_m3;
    self.mag_m3 = 0; self.ammo_m3 = 0;
    setmodel(tgt, "models/weapons/wpn_csm3/w_m3.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_csm3"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_CSM3; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_M3Equip; tgt.weap_drop_func = W_M3Drop;
    tgt.pickupcopy = W_M3PickupCopy; tgt.touch = weapon_touch;
    tgt.dropped_spin = 1;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_csm3 =
{
    setmodel(self, "models/weapons/wpn_csm3/w_m3.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_csm3"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_CSM3; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_M3Equip; self.weap_drop_func = W_M3Drop;
    self.pickupcopy = W_M3PickupCopy; self.touch = weapon_touch;
    self.dropped_spin = 1;
    self.mag_m3 = MAX_MAG_M3; self.ammo_m3 = MAX_AMMO_M3;
    W_RegisterMapWeapon(weapon_csm3);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_m3_reload_shells;
float csqc_m3_draw_pump_played;
float csqc_m3_reload_pump_played;
float csqc_m3_reload_insert_count;
float csqc_m3_casing_spawned;

const float M3_DRAW_PUMP_TIME = (M3_DRAW_PUMP_FRAME - M3_DRAW_START) * M3_FRAME_INTERVAL;
const float M3_FIRE_EJECT_TIME = (M3_FIRE_EJECT_FRAME - M3_FIRE_START) * M3_FRAME_INTERVAL;

void() CSQC_PredictM3Command =
{
    float r;
    if (input_buttons & 1)
    {
        r = SH_M3TryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_m3_casing_spawned = FALSE;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_csm3/fire.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(M3_PELLETS, M3_SPREAD,
                    M3_PELLET_CLOSE_DAMAGE, M3_PELLET_MIN_DAMAGE, M3_PELLET_FALLOFF_RANGE);
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted draw pump sound
    if (self.weaponstate == WS_DRAW && !csqc_m3_draw_pump_played
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= M3_DRAW_PUMP_TIME)
        {
            localsound("sounds/weapons/wpn_csm3/pump.wav");
            CSQC_RecordPredictedAutoSound();
            csqc_m3_draw_pump_played = TRUE;
        }
    }
    else if (self.weaponstate != WS_DRAW)
        csqc_m3_draw_pump_played = FALSE;

    // Predicted shell casing during fire eject
    if (self.weaponstate == WS_FIRE && !csqc_m3_casing_spawned
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        if (csqc_pred_time - self.wep_anim_start >= M3_FIRE_EJECT_TIME)
        {
            CSQC_SpawnCasing("models/weapons/shotgunshell1.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
            csqc_m3_casing_spawned = TRUE;
        }
    }

    // Predicted reload sounds — shell insertion + pump exit
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float enter_dur = (M3_RELOAD_LOOP_RESTART - M3_RELOAD_START) * M3_FRAME_INTERVAL;
        float loop_dur = (M3_RELOAD_LOOP_END - M3_RELOAD_LOOP_RESTART) * M3_FRAME_INTERVAL;
        float insert_offset = (M3_RELOAD_INSERT_FRAME - M3_RELOAD_LOOP_RESTART) * M3_FRAME_INTERVAL;

        // Shell insertion sounds
        if (csqc_m3_reload_insert_count < csqc_m3_reload_shells && reload_elapsed >= enter_dur)
        {
            float loop_elapsed = reload_elapsed - enter_dur;
            float next_insert_time = csqc_m3_reload_insert_count * loop_dur + insert_offset;
            if (loop_elapsed >= next_insert_time)
            {
                localsound("sounds/weapons/wpn_csm3/insertshell.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_m3_reload_insert_count += 1;
            }
        }

        // Pump exit sound
        if (!csqc_m3_reload_pump_played)
        {
            float pump_time = enter_dur + csqc_m3_reload_shells * loop_dur
                            + (M3_RELOAD_PUMP_FRAME - M3_RELOAD_LOOP_END) * M3_FRAME_INTERVAL;
            if (reload_elapsed >= pump_time)
            {
                localsound("sounds/weapons/wpn_csm3/pump.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_m3_reload_pump_played = TRUE;
            }
        }
    }

    SH_M3TickState(csqc_pred_time);
};

void() CSQC_PredictM3Reload =
{
    if (SH_M3TryReload(csqc_pred_time))
    {
        csqc_m3_reload_shells = min(MAX_MAG_M3 - self.mag_m3, self.ammo_m3);
        if (csqc_m3_reload_shells < 1)
            csqc_m3_reload_shells = 1;
        csqc_m3_reload_pump_played = FALSE;
        csqc_m3_reload_insert_count = 0;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_M3DisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = M3_DRAW_START + elapsed / M3_FRAME_INTERVAL; return bound(M3_DRAW_START, frame, M3_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = M3_FIRE_START + elapsed / M3_FRAME_INTERVAL; return bound(M3_FIRE_START, frame, M3_ALT_FIRE_END - 1); }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        float enter_dur = (M3_RELOAD_LOOP_RESTART - M3_RELOAD_START) * M3_FRAME_INTERVAL;
        float loop_dur = (M3_RELOAD_LOOP_END - M3_RELOAD_LOOP_RESTART) * M3_FRAME_INTERVAL;
        float total_loop = csqc_m3_reload_shells * loop_dur;

        // Phase 1: enter
        if (elapsed < enter_dur)
        {
            frame = M3_RELOAD_START + elapsed / M3_FRAME_INTERVAL;
            return bound(M3_RELOAD_START, frame, M3_RELOAD_LOOP_RESTART - 1);
        }

        // Phase 2: insert loop (N times)
        float loop_elapsed = elapsed - enter_dur;
        if (loop_elapsed < total_loop)
        {
            float in_loop = loop_elapsed - floor(loop_elapsed / loop_dur) * loop_dur;
            frame = M3_RELOAD_LOOP_RESTART + in_loop / M3_FRAME_INTERVAL;
            return bound(M3_RELOAD_LOOP_RESTART, frame, M3_RELOAD_LOOP_END - 1);
        }

        // Phase 3: pump exit
        float exit_elapsed = elapsed - enter_dur - total_loop;
        frame = M3_RELOAD_LOOP_END + exit_elapsed / M3_FRAME_INTERVAL;
        return bound(M3_RELOAD_LOOP_END, frame, M3_RELOAD_END - 1);
    }
    return M3_IDLE_FRAME;
};

void() CSQC_M3DropClear =
{
	self.mag_m3  = 0;
	self.ammo_m3 = 0;
};

void() CSQC_M3Equip =
{
	self.weapon_name         = M3_DISPLAY_NAME;
	self.weapon_viewmodel    = M3_VIEWMODEL;
	self.weapon_worldmodel   = M3_WORLDMODEL;
	self.weapon_deploy_sound = M3_DEPLOY_SOUND;
	self.csqc_predict_cmd    = CSQC_PredictM3Command;
	self.csqc_predict_reload = CSQC_PredictM3Reload;
	self.csqc_display_frame  = CSQC_M3DisplayFrame;
	self.csqc_drop_clear     = CSQC_M3DropClear;
};

#endif // CSQC
