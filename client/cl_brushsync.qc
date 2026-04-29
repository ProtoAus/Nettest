//
//  cl_brushsync.qc  –  CSQC solid brush entity + door/button prediction
//
//  Receives brush entities from the server and rebuilds them as SOLID_BSP
//  for client-side prediction traces.
//
//  Doors and buttons receive pos1/pos2/speed/state parameters so the client
//  can predict their movement instantly (before the server confirms).
//

// Client-side door/button fields
.float brush_type;      // BRUSH_TYPE_*
.float mover_state;     // MOVER_STATE_*
.vector pos1;           // closed/bottom position
.vector pos2;           // open/top position
.float speed;           // movement speed
.float door_locked;     // TRUE if door has DOOR_LOCKED spawnflag
.float brush_material;  // BREAKABLE_* code (0 = default/concrete);
                        // read by Impact_ClassifyLocal for per-surface
                        // particle effects on the local shooter.
.float brush_health;    // Current HP of breakable brushes, snapshotted
                        // from server on every damaging shot. CSQC
                        // subtracts predicted damage against this to
                        // decide whether a shot would break the brush.
.float brush_max_health;  // Original max HP; used by CSQC gib spawn to
                          // scale debris-piece damage/count on predicted
                          // breaks (matches server's BreakableSpawnDebris).
.float brush_cnt;         // Mapper/spawn-default gib count. Mirrors
                          // self.cnt on the server breakable.
.float brush_broken_predicted;  // Local flag: the shooter predicted a
                                // break on this brush. Gates duplicate
                                // predicted break sounds until the next
                                // server snapshot either confirms
                                // (broken=1) or corrects (health>0).
.float brush_broken_confirmed;  // Server-side truth: set when either
                                // CSQC_EVENT_BRUSH_DESTROY arrives or a
                                // solid_brush snapshot has broken=1. The
                                // prediction-timeout in cl_bulletimpact
                                // checks this before un-hiding a brush,
                                // so a slow-but-real server confirmation
                                // doesn't get clobbered.

// Use impulse constant (must match server's CheckImpulses case)
const float USE_IMPULSE = 11;

// Use trace distance (must match server's PLAYER_USE_TRACE_LENGTH)
const float CSQC_USE_TRACE_LENGTH = 96;

// ============================================================
//  Brush sync update (called by engine when server sends entity)
// ============================================================

void() CSQC_SolidBrush_Update =
{
    float mdlindex;
    vector org, ang, emins, emaxs, vel;
    float alpha_value;
    float effect_flags;
    float btype;
    float sv_state;

    // Server writes the precache index (readshort) instead of the model
    // path — setmodelindex below resolves it back.
    mdlindex = readshort();
    org = readvector();
    ang = readvector();
    emins = readvector();
    emaxs = readvector();
    // alpha byte biased 0..255 → 0..1 float; effects packed into short.
    alpha_value  = readbyte() * (1.0 / 255.0);
    effect_flags = readshort();
    vel = readvector();

    btype = readbyte();
    sv_state = 0;
    if (btype == BRUSH_TYPE_DOOR || btype == BRUSH_TYPE_BUTTON)
    {
        self.pos1  = readvector();
        self.pos2  = readvector();
        self.speed = readfloat();
        sv_state   = readbyte();
        self.door_locked = readbyte();
    }

    // Material byte (BREAKABLE_*). 0 for non-breakable brushes. Read by
    // Impact_ClassifyLocal in cl_bulletimpact.qc.
    self.brush_material = readbyte();

    // Current HP of the breakable. Used by CSQC_BulletImpact to decide
    // whether the attacker's predicted damage would break the brush.
    self.brush_health     = readshort();
    self.brush_max_health = readshort();
    self.brush_cnt        = readbyte();

    // Broken flag — func_breakable sets this when destroyed and clears
    // it on round restart. Client flips drawmask/solid instead of
    // remove()-ing, so the entity slot survives for the next round.
    float broken = readbyte();
    self.brush_broken_confirmed = broken;

    // Clear the predicted-break flag ONLY when the server resets the
    // brush to full HP — the unambiguous "round restart" / initial-spawn
    // signal (server-side health can only monotonically decrease via
    // damage, so any partial HP value is the server catching up to our
    // predicted damage rather than contradicting it). Preserving the
    // flag across catch-up snapshots prevents the brush from briefly
    // reappearing between "server processed shot 1" and "server processed
    // shot 2" at high ping + rapid fire — CSQC locked in the break at
    // shot 2 and shouldn't un-hide just because an intermediate partial
    // HP value arrives.
    if (!broken && self.brush_max_health > 0 && self.brush_health >= self.brush_max_health)
        self.brush_broken_predicted = 0;

    // Always setmodelindex — the conditional "only on model change"
    // variant left the render binding stale after a drawmask=0 →
    // drawmask=MASK_ENGINE transition (breakable reset), so the brush
    // stayed invisible even though the model index hadn't changed. An
    // unconditional rebind on every snapshot is cheap (model is already
    // precached by virtue of being in the BSP submodel list) and reliable.
    setmodelindex(self, mdlindex);
    setsize(self, emins, emaxs);

    // Keep the brush hidden if EITHER the server confirmed broken OR we
    // predicted a break locally that hasn't been rolled back by a full-HP
    // reset. The brush_broken_predicted gate is what stops catch-up
    // snapshots (broken=0, partial HP) from briefly un-hiding a brush
    // the attacker already saw shatter.
    float hide = (broken || self.brush_broken_predicted);
    self.movetype    = MOVETYPE_NOCLIP;
    self.solid       = hide ? SOLID_NOT : SOLID_BSP;
    self.drawmask    = hide ? 0 : MASK_ENGINE;
    self.angles      = ang;
    self.alpha       = alpha_value;
    self.effects     = effect_flags;

    if (self.brush_type == btype
        && (btype == BRUSH_TYPE_DOOR || btype == BRUSH_TYPE_BUTTON)
        && self.mover_state == sv_state
        && (sv_state == MOVER_STATE_UP || sv_state == MOVER_STATE_DOWN))
    {
        // Server and client agree on direction — keep whichever position
        // is further along toward the destination.
        vector dest;
        if (sv_state == MOVER_STATE_UP)
            dest = self.pos2;
        else
            dest = self.pos1;

        float server_dist = vlen(dest - org);
        float client_dist = vlen(dest - self.origin);

        if (client_dist < server_dist)
            self.velocity = vel;   // client ahead — keep position
        else
        {
            self.velocity = vel;
            setorigin(self, org);
        }
    }
    else
    {
        // Server disagrees or static brush — accept server state fully.
        // This corrects mispredictions where the client started a mover
        // the server never activated.
        self.velocity    = vel;
        self.mover_state = sv_state;
        setorigin(self, org);
    }

    self.brush_type = btype;

    // Post-update diagnostic — shows final state after parsing, so we can
    // see if the server sent a bogus origin or model for a breakable.
    if (cvar("sv_debug_ent_types"))
    {
        print(sprintf("  [brush %g] model='%s' origin=%v mins=%v maxs=%v btype=%g mat=%g\n",
                      self.entnum, self.model, self.origin, self.mins, self.maxs,
                      self.brush_type, self.brush_material));
    }
};

// ============================================================
//  Client-side door/button prediction
// ============================================================

// Start a mover moving toward a destination (client-side equivalent of Mover_Start)
void(entity ent, vector destination) CSQC_MoverPredict =
{
    vector delta;
    float distance;

    delta    = destination - ent.origin;
    distance = vlen(delta);

    if (distance <= 0 || ent.speed <= 0)
    {
        ent.velocity = '0 0 0';
        setorigin(ent, destination);
        return;
    }

    ent.velocity = delta * (ent.speed / distance);
};

// Predict a single door or button activation (client-side equivalent of
// door_go_up / button_fire).  Does NOT handle door groups — groups are
// corrected when the server snapshot arrives.
void(entity hit) CSQC_PredictMoverActivate =
{
    // Bhop gamemode: server clears door/button .use/.touch/.blocked so the
    // brush is inert (sv_doors.qc spawn paths). If we predicted locally
    // anyway, the server would never move the brush, never dirty its
    // SendFlags, never snapshot a "you got it wrong" — the predicted
    // open/closed state would stick on the client until map change.
    // Treat bhop +use on a brush as a no-op to match server.
    if (getstatf(STAT_GAMEMODE) == GAMEMODE_BHOP)
        return;

    // Already moving? Don't re-trigger (matches server guard)
    if (hit.mover_state == MOVER_STATE_UP || hit.mover_state == MOVER_STATE_DOWN)
        return;

    if (hit.mover_state == MOVER_STATE_BOTTOM)
    {
        hit.mover_state = MOVER_STATE_UP;
        CSQC_MoverPredict(hit, hit.pos2);
    }
    else if (hit.mover_state == MOVER_STATE_TOP)
    {
        // Buttons return on their own timer — server rejects re-activation
        // from TOP state (button_fire guards against UP/TOP).  Only doors
        // can be toggled back from TOP.
        if (hit.brush_type == BRUSH_TYPE_BUTTON)
            return;

        hit.mover_state = MOVER_STATE_DOWN;
        CSQC_MoverPredict(hit, hit.pos1);
    }
};

// Forward decl from cl_weapons.qc (compiled later in cl_progs.src).
void(entity w) CSQC_PredictPickupWeapon;

// Try to predict door/button activation OR weapon pickup via +use trace.
// Called from CSQC_PredictWeaponCommand context (self = predicted_player).
// Matches the server's SV_PlayerTryUse: tracebox first, then cone fallback.
void() CSQC_PredictUse =
{
    vector use_start, use_end;
    entity hit, best, e, w, best_w;
    float best_dot, dot, w_best_dot;

    makevectors(input_angles);
    use_start = self.origin + self.view_ofs;
    use_end   = use_start + v_forward * CSQC_USE_TRACE_LENGTH;

    // Match server: tracebox with expanded hull, not traceline
    tracebox(use_start, '-8 -8 -8', '8 8 8', use_end, MOVE_NORMAL, self);

    hit = trace_ent;
    if (hit && hit != world
        && (hit.brush_type == BRUSH_TYPE_DOOR || hit.brush_type == BRUSH_TYPE_BUTTON))
    {
        if (hit.brush_type == BRUSH_TYPE_DOOR && hit.door_locked)
            return;
        CSQC_PredictMoverActivate(hit);
        return;
    }

    // Cone fallback: pick the closest-aligned usable entity (matches server)
    best = world;
    best_dot = 0.7;
    e = findradius(use_start, CSQC_USE_TRACE_LENGTH);
    while (e)
    {
        if (e != self
            && (e.brush_type == BRUSH_TYPE_DOOR || e.brush_type == BRUSH_TYPE_BUTTON)
            && !(e.brush_type == BRUSH_TYPE_DOOR && e.door_locked))
        {
            dot = normalize(e.origin - use_start) * v_forward;
            if (dot > best_dot)
            {
                best_dot = dot;
                best = e;
            }
        }
        e = e.chain;
    }

    // Dropped-weapon scan — proxies are SOLID_NOT so the tracebox above
    // can't hit them (otherwise the local player would also collide with
    // them on walk-through). Walk dropped_weapon_list and pick the best
    // cone-aligned one. Mirrors the server's combined cone in SV_PlayerTryUse.
    best_w = world;
    w_best_dot = 0.7;
    w = dropped_weapon_list;
    float guard = 0;
    while (w)
    {
        entity nxt = w.dropped_weapon_next;
        guard = guard + 1;
        if (guard > 4096) break;

        if (!w.dropped_weapon_predicted_taken
            && cltime >= w.dropped_weapon_pickup_time
            && vlen(self.origin - w.origin) < CSQC_USE_TRACE_LENGTH)
        {
            dot = normalize(w.origin - use_start) * v_forward;
            if (dot > w_best_dot)
            {
                w_best_dot = dot;
                best_w = w;
            }
        }
        w = nxt;
    }

    // Whichever (door/button vs weapon) is most centered wins. If both
    // tied near the threshold, weapon pickup gets priority — matches the
    // intuition that a weapon at your feet is the obvious target.
    if (best_w && (best == world || w_best_dot >= best_dot))
        CSQC_PredictPickupWeapon(best_w);
    else if (best)
        CSQC_PredictMoverActivate(best);
};

// Proximity door prediction removed — iterating all entities per frame
// caused runaway loop errors. Touch-triggered doors will open with the
// server's normal latency. Use-triggered doors (+use) are predicted
// instantly via CSQC_PredictUse traceline above.
