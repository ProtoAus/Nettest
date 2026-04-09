// ============================================================
//  shared/weapons/sh_wpn_hlshotgun.qc  -  HL Shotgun
//
//  Slot  : SLOT_PRIMARY  (impulse 1 / key 1)
//  Stats : 8-shell tube, 24 reserve, pump-action
//  Fire  : multi-pellet hitscan, linear damage falloff
//  Alt   : Double-barrel (fires 2 shells, 16 pellets)
//  Reload: Shell-by-shell insertion (frame-driven loop)
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

// --- Ammo fields ---
.float mag_shotgun;
.float ammo_shotgun;

// --- Animation frames ---
const float HLSG_FRAME_INTERVAL       = 0.05;   // 1/20

const float HLSG_DRAW_START           = 1;
const float HLSG_DRAW_END             = 10;

const float HLSG_FIRE_START           = 11;
const float HLSG_FIRE_END             = 31;
const float HLSG_FIRE_PUMP_FRAME      = 21;
const float HLSG_FIRE_DELAY           = 0.75;

const float HLSG_DBLFIRE_START        = 34;
const float HLSG_DBLFIRE_END          = 52;
const float HLSG_DBLFIRE_PUMP_FRAME   = 46;
const float HLSG_DBLFIRE_DELAY        = 0.9;

const float HLSG_RELOAD_START         = 54;
const float HLSG_RELOAD_LOOP_RESTART  = 61;
const float HLSG_RELOAD_INSERT_FRAME  = 66;
const float HLSG_RELOAD_LOOP_END      = 71;
const float HLSG_RELOAD_PUMP_FRAME    = 75;
const float HLSG_RELOAD_END           = 82;

const float HLSG_IDLE_FRAME           = 10;   // DRAW_END

const float MAX_MAG_SHOTGUN           = 8;
const float MAX_AMMO_SHOTGUN          = 24;

// --- Balance ---
const float HLSG_PELLETS              = 8;
const float HLSG_DBL_PELLETS          = 16;
const float HLSG_SPREAD               = 0.08;
const float HLSG_DBL_SPREAD           = 0.12;
const float HLSG_PELLET_CLOSE_DAMAGE  = 6;
const float HLSG_PELLET_MIN_DAMAGE    = 3;
const float HLSG_PELLET_FALLOFF_RANGE = 1024;
const float HLSG_DRYFIRE_DELAY        = 0.2;

// --- Pre-computed durations ---
const float HLSG_DRAW_DURATION        = (HLSG_DRAW_END - HLSG_DRAW_START) * HLSG_FRAME_INTERVAL;
const float HLSG_FIRE_DURATION        = (HLSG_FIRE_END - HLSG_FIRE_START) * HLSG_FRAME_INTERVAL;
const float HLSG_DBLFIRE_DURATION     = (HLSG_DBLFIRE_END - HLSG_DBLFIRE_START) * HLSG_FRAME_INTERVAL;

// ============================================================
//  SHARED — state machine
//  Handles draw/fire/special→idle. Reload is frame-driven on server.
// ============================================================

float(float now) SH_ShotgunTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE || self.weaponstate == WS_RELOAD)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= HLSG_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= HLSG_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    if (self.weaponstate == WS_SPECIAL)
    {
        if (elapsed >= HLSG_DBLFIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

float(float now) SH_ShotgunTryFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_shotgun <= 0)
    { self.attack_finished = now + HLSG_DRYFIRE_DELAY; return -1; }

    self.mag_shotgun     -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + HLSG_FIRE_DELAY;
    return 1;
};

float(float now) SH_ShotgunTryDoubleFire =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (now < self.attack_finished) return 0;

    if (self.mag_shotgun < 2)
    { self.attack_finished = now + HLSG_DRYFIRE_DELAY; return -1; }

    self.mag_shotgun     -= 2;
    self.weaponstate      = WS_SPECIAL;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + HLSG_DBLFIRE_DELAY;
    return 1;
};

float(float now) SH_ShotgunTryReload =
{
    if (self.weaponstate != WS_IDLE) return 0;
    if (self.mag_shotgun >= MAX_MAG_SHOTGUN || self.ammo_shotgun <= 0) return 0;

    self.weaponstate     = WS_RELOAD;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_ShotgunPickupCopy =
{ player.mag_shotgun = self.mag_shotgun; player.ammo_shotgun = self.ammo_shotgun; };

void(float pellets, float spread_val) W_ShotgunFirePellets =
{
    vector src, dir, end;
    float sx, sy, i, dist, damage;

    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;

    for (i = 0; i < pellets; i++)
    {
        sx = (random() * 2 - 1) * spread_val;
        sy = (random() * 2 - 1) * spread_val;
        dir = normalize(v_forward + v_right * sx + v_up * sy);
        end = src + dir * 8192;

        W_WeaponTraceLine(src, end);

        if (trace_fraction < 1.0)
        {
            dist = vlen(trace_endpos - src);
            if (W_CanDamageTarget(trace_ent))
            {
                damage = W_LinearDamageFalloff(dist, HLSG_PELLET_CLOSE_DAMAGE, HLSG_PELLET_MIN_DAMAGE, HLSG_PELLET_FALLOFF_RANGE);
                W_ApplyDamage(self, trace_ent, damage);
            }
            else
                W_ImpactEffect(trace_endpos);
        }
    }
};

void() W_ShotgunFire =
{
    float r = SH_ShotgunTryFire(time);
    if (r == 1)
    {
        self.weaponframe = HLSG_FIRE_START;
        self.wep_nextframe = time + HLSG_FRAME_INTERVAL;
        W_ShotgunFirePellets(HLSG_PELLETS, HLSG_SPREAD);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire1.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_ShotgunAltFire =
{
    float r = SH_ShotgunTryDoubleFire(time);
    if (r == 1)
    {
        self.weaponframe = HLSG_DBLFIRE_START;
        self.wep_nextframe = time + HLSG_FRAME_INTERVAL;
        W_ShotgunFirePellets(HLSG_DBL_PELLETS, HLSG_DBL_SPREAD);
        sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire2.wav", 1, ATTN_NORM);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
};

void() W_ShotgunReload =
{
    if (SH_ShotgunTryReload(time))
    { self.weaponframe = HLSG_RELOAD_START; self.wep_nextframe = time + HLSG_FRAME_INTERVAL; }
};

void() W_ShotgunFrame =
{
    self.weaponframe += 1;
    self.wep_nextframe += HLSG_FRAME_INTERVAL;

    // --- Draw ---
    if (self.weaponstate == WS_DRAW)
    {
        if (self.weaponframe >= HLSG_DRAW_END)
        {
            self.weaponframe = HLSG_IDLE_FRAME;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Single fire ---
    if (self.weaponstate == WS_FIRE)
    {
        if (self.weaponframe == HLSG_FIRE_PUMP_FRAME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/cock.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 46 36', '240 720 120');
        }

        if (self.weaponframe >= HLSG_FIRE_END)
        {
            self.weaponframe = HLSG_IDLE_FRAME;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Double fire ---
    if (self.weaponstate == WS_SPECIAL)
    {
        if (self.weaponframe == HLSG_DBLFIRE_PUMP_FRAME)
        {
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/cock.wav", 1, ATTN_NORM);
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 46 36', '240 720 120');
            W_ShellEffect(SHELL_SHOTGUN2, '8 6 -4', '6 52 42', '240 720 120');
        }

        if (self.weaponframe >= HLSG_DBLFIRE_END)
        {
            self.weaponframe = HLSG_IDLE_FRAME;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // --- Shell-by-shell reload (frame-driven loop) ---
    if (self.weaponstate == WS_RELOAD)
    {
        // Insert a shell at the insert frame
        if (self.weaponframe == HLSG_RELOAD_INSERT_FRAME
            && self.mag_shotgun < MAX_MAG_SHOTGUN && self.ammo_shotgun > 0)
        {
            self.mag_shotgun += 1;
            self.ammo_shotgun -= 1;

            float snd_roll = random();
            if (snd_roll < 0.333)
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/reload1.wav", 1, ATTN_NORM);
            else if (snd_roll < 0.666)
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/reload2.wav", 1, ATTN_NORM);
            else
                sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/reload3.wav", 1, ATTN_NORM);
        }

        // At loop end: restart loop if more shells needed, otherwise continue to pump
        if (self.weaponframe >= HLSG_RELOAD_LOOP_END)
        {
            if (self.mag_shotgun < MAX_MAG_SHOTGUN && self.ammo_shotgun > 0)
            {
                self.weaponframe = HLSG_RELOAD_LOOP_RESTART;
                return;
            }
        }

        // Pump sound during exit
        if (self.weaponframe == HLSG_RELOAD_PUMP_FRAME)
            sound(self, CHAN_AUTO, "sounds/weapons/wpn_hlshotgun/cock.wav", 1, ATTN_NORM);

        // Reload complete
        if (self.weaponframe >= HLSG_RELOAD_END)
        {
            self.weaponframe = HLSG_IDLE_FRAME;
            self.weaponstate = WS_IDLE;
            self.wep_anim_start = 0;
            self.wep_nextframe = 0;
        }
        return;
    }

    // Fallback
    self.weaponframe = HLSG_IDLE_FRAME;
    self.weaponstate = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe = 0;
};

void() W_ShotgunEquip =
{
    self.weaponmodel = SH_WeaponViewModel(WEP_HLSHOTGUN);
    self.weapon_name = "SHOTGUN";
    self.weapon_draw_start_frame = HLSG_DRAW_START;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_SHOT;
    self.fire = W_ShotgunFire; self.reload = W_ShotgunReload; self.wepframe = W_ShotgunFrame;
    self.altfire = W_ShotgunAltFire; self.altrelease = __NULL__;
    self.shoot = __NULL__; self.special = __NULL__;
    self.weaponstate = WS_DRAW; self.wep_action_id += 1;
    self.wep_anim_start = time; self.weaponframe = HLSG_DRAW_START;
    self.wep_nextframe = time + HLSG_FRAME_INTERVAL;
    W_SetCrosshairProfile(HLSG_SPREAD, 0, 320, 2.0, TRUE);
};

void() W_ShotgunDrop =
{
    entity tgt = weapon_drop_target;
    tgt.mag_shotgun = self.mag_shotgun; tgt.ammo_shotgun = self.ammo_shotgun;
    self.mag_shotgun = 0; self.ammo_shotgun = 0;
    setmodel(tgt, "models/weapons/wpn_hlshotgun/w_shotgun.mdl");
    setsize(tgt, '-16 -16 0', '16 16 32');
    tgt.classname = "weapon_hlshotgun"; tgt.solid = SOLID_NOT; tgt.movetype = MOVETYPE_TOSS;
    tgt.weapon = WEP_HLSHOTGUN; tgt.weapon_slot = SLOT_PRIMARY;
    tgt.weap_draw = W_ShotgunEquip; tgt.weap_drop_func = W_ShotgunDrop;
    tgt.pickupcopy = W_ShotgunPickupCopy; tgt.touch = weapon_touch;
    tgt.think = weapon_become_solid; tgt.nextthink = time + 0.7;
};

void() weapon_hlshotgun =
{
    setmodel(self, "models/weapons/wpn_hlshotgun/w_shotgun.mdl");
    setsize(self, '-16 -16 0', '16 16 32');
    self.classname = "weapon_hlshotgun"; self.solid = SOLID_TRIGGER; self.movetype = MOVETYPE_TOSS;
    self.weapon = WEP_HLSHOTGUN; self.weapon_slot = SLOT_PRIMARY;
    self.weap_draw = W_ShotgunEquip; self.weap_drop_func = W_ShotgunDrop;
    self.pickupcopy = W_ShotgunPickupCopy; self.touch = weapon_touch;
    self.mag_shotgun = MAX_MAG_SHOTGUN; self.ammo_shotgun = MAX_AMMO_SHOTGUN;
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_hlsg_reload_shells;
float csqc_hlsg_reload_pump_played;
float csqc_hlsg_reload_insert_count;   // how many insert sounds played so far

// Pre-computed pump sound times (elapsed from fire start)
const float HLSG_FIRE_PUMP_TIME    = (HLSG_FIRE_PUMP_FRAME - HLSG_FIRE_START) * HLSG_FRAME_INTERVAL;
const float HLSG_DBLFIRE_PUMP_TIME = (HLSG_DBLFIRE_PUMP_FRAME - HLSG_DBLFIRE_START) * HLSG_FRAME_INTERVAL;

float csqc_hlsg_pump_played;
float csqc_hlsg_casing_spawned;

void() CSQC_PredictShotgunCommand =
{
    float r;

    // Alt-fire: double barrel
    if (input_buttons & 4)
    {
        r = SH_ShotgunTryDoubleFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_hlsg_pump_played = FALSE;
            csqc_hlsg_casing_spawned = FALSE;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire2.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(HLSG_DBL_PELLETS, HLSG_DBL_SPREAD);
            }
        }
    }

    if (input_buttons & 1)
    {
        r = SH_ShotgunTryFire(csqc_pred_time);
        if (r == 1)
        {
            CSQC_MarkPendingWeaponAck();
            csqc_hlsg_pump_played = FALSE;
            csqc_hlsg_casing_spawned = FALSE;
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/wpn_hlshotgun/fire1.wav", 1, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
                CSQC_PredictedShotgunImpact(HLSG_PELLETS, HLSG_SPREAD);
            }
        }
        else if (r == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            { sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NONE); CSQC_RecordPredictedWeaponSound(); }
        }
    }

    // Predicted pump sound and shell casing at the correct frame time after fire
    if ((!csqc_hlsg_pump_played || !csqc_hlsg_casing_spawned)
        && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float elapsed = csqc_pred_time - self.wep_anim_start;

        if (self.weaponstate == WS_FIRE && elapsed >= HLSG_FIRE_PUMP_TIME)
        {
            if (!csqc_hlsg_pump_played)
            { localsound("sounds/weapons/wpn_hlshotgun/cock.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsg_pump_played = TRUE; }
            if (!csqc_hlsg_casing_spawned)
            {
                CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                csqc_hlsg_casing_spawned = TRUE;
            }
        }
        else if (self.weaponstate == WS_SPECIAL && elapsed >= HLSG_DBLFIRE_PUMP_TIME)
        {
            if (!csqc_hlsg_pump_played)
            { localsound("sounds/weapons/wpn_hlshotgun/cock.wav"); CSQC_RecordPredictedAutoSound(); csqc_hlsg_pump_played = TRUE; }
            if (!csqc_hlsg_casing_spawned)
            {
                CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 46 36', '8 14 14', '240 720 120', '120 240 180');
                CSQC_SpawnCasing("models/weapons/shotgunshell2.mdl", '8 6 -4', '6 52 42', '8 14 14', '240 720 120', '120 240 180');
                csqc_hlsg_casing_spawned = TRUE;
            }
        }
    }

    // Predicted reload sounds — shell insertion + pump exit
    if (self.weaponstate == WS_RELOAD && !pm_suppress_sounds && self.wep_anim_start > 0)
    {
        float reload_elapsed = csqc_pred_time - self.wep_anim_start;
        float enter_dur = (HLSG_RELOAD_LOOP_RESTART - HLSG_RELOAD_START) * HLSG_FRAME_INTERVAL;
        float loop_dur = (HLSG_RELOAD_LOOP_END - HLSG_RELOAD_LOOP_RESTART) * HLSG_FRAME_INTERVAL;
        float insert_offset = (HLSG_RELOAD_INSERT_FRAME - HLSG_RELOAD_LOOP_RESTART) * HLSG_FRAME_INTERVAL;

        // Shell insertion sounds (one per loop iteration)
        if (csqc_hlsg_reload_insert_count < csqc_hlsg_reload_shells && reload_elapsed >= enter_dur)
        {
            float loop_elapsed = reload_elapsed - enter_dur;
            float next_insert_time = csqc_hlsg_reload_insert_count * loop_dur + insert_offset;
            if (loop_elapsed >= next_insert_time)
            {
                float snd_roll = random();
                if (snd_roll < 0.333)
                    localsound("sounds/weapons/wpn_hlshotgun/reload1.wav");
                else if (snd_roll < 0.666)
                    localsound("sounds/weapons/wpn_hlshotgun/reload2.wav");
                else
                    localsound("sounds/weapons/wpn_hlshotgun/reload3.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_hlsg_reload_insert_count += 1;
            }
        }

        // Pump exit sound
        if (!csqc_hlsg_reload_pump_played)
        {
            float pump_time = enter_dur + csqc_hlsg_reload_shells * loop_dur
                            + (HLSG_RELOAD_PUMP_FRAME - HLSG_RELOAD_LOOP_END) * HLSG_FRAME_INTERVAL;
            if (reload_elapsed >= pump_time)
            {
                localsound("sounds/weapons/wpn_hlshotgun/cock.wav");
                CSQC_RecordPredictedAutoSound();
                csqc_hlsg_reload_pump_played = TRUE;
            }
        }
    }

    SH_ShotgunTickState(csqc_pred_time);
};

void() CSQC_PredictShotgunReload =
{
    if (SH_ShotgunTryReload(csqc_pred_time))
    {
        csqc_hlsg_reload_shells = min(MAX_MAG_SHOTGUN - self.mag_shotgun, self.ammo_shotgun);
        if (csqc_hlsg_reload_shells < 1)
            csqc_hlsg_reload_shells = 1;
        csqc_hlsg_reload_pump_played = FALSE;
        csqc_hlsg_reload_insert_count = 0;
        CSQC_MarkPendingWeaponAck();
    }
};

float(float elapsed) CSQC_ShotgunDisplayFrame =
{
    float frame;
    if (predicted_player.weaponstate == WS_DRAW)
    { frame = HLSG_DRAW_START + elapsed / HLSG_FRAME_INTERVAL; return bound(HLSG_DRAW_START, frame, HLSG_DRAW_END - 1); }
    if (predicted_player.weaponstate == WS_FIRE)
    { frame = HLSG_FIRE_START + elapsed / HLSG_FRAME_INTERVAL; return bound(HLSG_FIRE_START, frame, HLSG_FIRE_END - 1); }
    if (predicted_player.weaponstate == WS_SPECIAL)
    { frame = HLSG_DBLFIRE_START + elapsed / HLSG_FRAME_INTERVAL; return bound(HLSG_DBLFIRE_START, frame, HLSG_DBLFIRE_END - 1); }
    if (predicted_player.weaponstate == WS_RELOAD)
    {
        float enter_dur = (HLSG_RELOAD_LOOP_RESTART - HLSG_RELOAD_START) * HLSG_FRAME_INTERVAL;
        float loop_dur = (HLSG_RELOAD_LOOP_END - HLSG_RELOAD_LOOP_RESTART) * HLSG_FRAME_INTERVAL;
        float exit_dur = (HLSG_RELOAD_END - HLSG_RELOAD_LOOP_END) * HLSG_FRAME_INTERVAL;
        float total_loop = csqc_hlsg_reload_shells * loop_dur;

        // Phase 1: enter
        if (elapsed < enter_dur)
        {
            frame = HLSG_RELOAD_START + elapsed / HLSG_FRAME_INTERVAL;
            return bound(HLSG_RELOAD_START, frame, HLSG_RELOAD_LOOP_RESTART - 1);
        }

        // Phase 2: insert loop (N times)
        float loop_elapsed = elapsed - enter_dur;
        if (loop_elapsed < total_loop)
        {
            float in_loop = loop_elapsed - floor(loop_elapsed / loop_dur) * loop_dur;
            frame = HLSG_RELOAD_LOOP_RESTART + in_loop / HLSG_FRAME_INTERVAL;
            return bound(HLSG_RELOAD_LOOP_RESTART, frame, HLSG_RELOAD_LOOP_END - 1);
        }

        // Phase 3: pump exit
        float exit_elapsed = elapsed - enter_dur - total_loop;
        frame = HLSG_RELOAD_LOOP_END + exit_elapsed / HLSG_FRAME_INTERVAL;
        return bound(HLSG_RELOAD_LOOP_END, frame, HLSG_RELOAD_END - 1);
    }
    return HLSG_IDLE_FRAME;
};

#endif // CSQC
