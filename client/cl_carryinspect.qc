// ============================================================================
//  cl_carryinspect.qc — "inspect mode" for a carried physics prop
// ============================================================================
//
//  Hold the RELOAD key while carrying a prop and the view locks: mouse motion
//  rotates the prop instead of turning the player, and the mouse wheel pushes it
//  away / pulls it closer.  Release and normal look control returns.
//
//  Structurally this is the VoIP mute mode (cl_main.qc) — a held-modifier
//  first-person mouse grab with no cursor and no menu — applied to the carry.
//
//  OWNERSHIP.  While THIS client is the carrier the orientation is client-owned and
//  predicted: we rotate the local basis (pp_rel_fwd/pp_rel_up) immediately for
//  zero-lag feel, and push ABSOLUTE state upstream at a fixed rate.  The server
//  validates and clamps it, drives the real physics body, and echoes it back — which
//  we deliberately ignore while we own it (see CSQC_PhysProp_Update).
//
//  Compiled late (after cl_physprop / cl_player / cl_spectate) so it can see the
//  pp_* mirror fields, the carry throw latch and the spectate state.
// ============================================================================

float csqc_inspect_mode;        // 1 = active: view locked, mouse drives the prop
float csqc_inspect_key_down;    // raw physical state of the rotate key — tracked ALWAYS,
                                //   so "already holding R when I grab" can't auto-enter
float csqc_inspect_dirty;       // local basis/distance changed since the last send
float csqc_inspect_next_send;   // cltime of the next allowed upstream send
float csqc_inspect_dist_want;   // local scroll target (qu offset from the default hold distance)
entity csqc_inspect_lastprop;   // carried prop last frame — a change resets the scroll target
float csqc_inspect_settle_until;// keep re-sending the final pose until this cltime (see Inspect_Exit)

// Is this key the one that activates inspect mode?  Matched on the BIND STRING, because
// reload is an edge-only impulse (WEAPON_IMPULSE_RELOAD = 6) — there is no +reload button
// to test.  "impulse 6" is what data/default.cfg binds AND what the settings-menu
// rebinder writes (m_menu.qc bindlist), so rebinding Reload just works.
// EXACT compare, never a substring: "impulse 60" would false-match.
// "+proprotate" is also honoured so a dedicated key can be bound without touching Reload.
float Inspect_IsRotateBind(float scan)
{
    string b = getkeybind(scan);
    if (b == "impulse 6")   return TRUE;
    if (b == "+proprotate") return TRUE;
    return FALSE;
}

// The prop this client is carrying, or world.  pp_carrier is only ever set on phys_files
// mirrors, so this cannot match anything else.
entity Inspect_HeldProp()
{
    if (!player_localentnum)
        return world;
    return findfloat(world, pp_carrier, player_localentnum);
}

// Push the current local state upstream as ABSOLUTE values, never deltas.
//
// sendevent goes on the RELIABLE channel here (engine PF_cs_sendevent writes to
// cls.netchan.message), so nothing is lost in transit — but the SERVER's own rate gate
// (sv_carry_rot_maxrate, CSEv_carryrot_vf) will silently discard anything arriving too
// soon after the last accepted one.  That makes absolute state load-bearing: a discarded
// update is simply superseded by the next, whereas a discarded DELTA would leave the
// physics body permanently out of step with what we are drawing.
//
// `force` bypasses the CLIENT limiter only — it cannot bypass the server's, which is why
// Inspect_Exit also arms a short retry window instead of trusting one final send.
void Inspect_Send(float force)
{
    entity prop = Inspect_HeldProp();
    if (prop == world)
        return;
    if (!prop.pp_rel_valid)
        return;

    if (!force)
    {
        if (!csqc_inspect_dirty)
            return;
        if (cltime < csqc_inspect_next_send)
            return;
    }

    float rate = cvar("cl_carry_rotate_sendrate");
    if (rate < 1)
        rate = 1;
    csqc_inspect_next_send = cltime + (1 / rate);
    csqc_inspect_dirty     = FALSE;

    sendevent("carryrot", "vf",
              CarryRot_Angles(prop.pp_rel_fwd, prop.pp_rel_up),
              csqc_inspect_dist_want);
}

void Inspect_Enter()
{
    if (csqc_inspect_mode)
        return;
    entity prop = Inspect_HeldProp();
    if (prop == world)
        return;

    csqc_inspect_mode = TRUE;
    // csqc_inspect_dist_want is maintained by Inspect_Frame (reset on each new grab), so
    // re-entering inspect mode on the same prop resumes at the distance you left it.
}

void Inspect_Exit()
{
    if (!csqc_inspect_mode)
        return;
    csqc_inspect_mode     = FALSE;
    csqc_inspect_key_down = FALSE;   // so a stranded-mode exit still leaves a clean edge for re-entry

    // Converge the server on the final pose.  One send is NOT enough: the server's rate
    // gate (25 ms at the default sv_carry_rot_maxrate 40) rejects anything arriving too
    // soon after the last accepted update, and releasing the key within that window is
    // common.  There is no ack to test, so re-send for a short window instead — sends are
    // 50 ms apart, so the second attempt is guaranteed to clear a 25 ms gate.  The state
    // is absolute and idempotent, so repeating it is free of side effects.
    Inspect_Send(TRUE);
    csqc_inspect_settle_until = cltime + 0.4;
}

// Apply a mouse delta to the held prop's local basis.
void Inspect_Rotate(float dx, float dy)
{
    entity prop = Inspect_HeldProp();
    if (prop == world)
        return;
    if (!prop.pp_rel_valid)
        return;

    float spd = cvar("cl_carry_rotate_speed");
    if (spd <= 0)
        spd = 0.35;
    if (cvar("cl_carry_rotate_invert"))
        dy = dy * -1;

    // Both axes are CONSTANT in the carry frame (which yaws with the view):
    //   mouse X about world up      -> turntable spin
    //   mouse Y about the view right -> tip toward / away from the camera
    CarryRot_SpinBasis(prop.pp_rel_fwd, prop.pp_rel_up, '0 0 1', dx * spd * -1);
    CarryRot_SpinBasis(crot_oF,         crot_oU,        '0 1 0', dy * spd);
    prop.pp_rel_fwd = crot_oF;
    prop.pp_rel_up  = crot_oU;
    csqc_inspect_dirty = TRUE;
}

void Inspect_Scroll(float dir)
{
    float step = cvar("cl_carry_dist_step");
    if (step <= 0)
        step = 12;
    csqc_inspect_dist_want = csqc_inspect_dist_want + dir * step;
    // Client-side clamp for immediate feel; the server re-clamps authoritatively
    // (CSEv_carryrot_vf), including a per-prop floor a flat minimum can't express.
    float dmin = cvar("sv_carry_dist_min");
    float dmax = cvar("sv_carry_dist_max");
    if (csqc_inspect_dist_want < dmin) csqc_inspect_dist_want = dmin;
    if (csqc_inspect_dist_want > dmax) csqc_inspect_dist_want = dmax;
    csqc_inspect_dirty = TRUE;
}

// Per-frame guard + sender.  Called from CSQC_UpdateView.
//
// EVERY exit path has to restore the view, or the player is left unable to look around.
// Key-up covers the normal case; this covers drop, throw, the sv_carry_drop_dist
// force-drop, the prop being removed, death and spectate.  Note that re-entry needs a
// FRESH key-down edge, so being dropped while still holding the key does not re-lock.
// `notmenu` is CSQC_UpdateView's third argument.  It is named `menushown` at the call
// site, but that name is a MISNOMER: the engine passes
// !Key_Dest_Has(kdm_menu|kdm_cwindows), i.e. it is TRUE during normal gameplay and FALSE
// when the menu or console has focus.  Taking the name at face value made this guard fire
// every frame and kill inspect mode instantly.
void Inspect_Frame(float notmenu)
{
    entity held = Inspect_HeldProp();

    // Reset the local push/pull target whenever the carried prop CHANGES (fresh grab, or
    // released).  Carry_TryGrab zeroes carry_dist_want/carry_dist_ofs server-side, so both
    // ends start from the default hold distance and stay in step as the wheel moves it.
    // Tracked locally rather than derived from the streamed pp_hold_dist, because
    // sv_carry_hold_dist is an SV-side cvar and simply does not exist in CSQC.
    if (held != csqc_inspect_lastprop)
    {
        csqc_inspect_lastprop  = held;
        csqc_inspect_dist_want = 0;
    }

    // Settle retry window — runs even after the mode is off (see Inspect_Exit).
    if (csqc_inspect_settle_until > 0)
    {
        if (cltime < csqc_inspect_settle_until)
        {
            csqc_inspect_dirty = TRUE;   // re-arm: the server's rate gate may have dropped the last one
            Inspect_Send(FALSE);
        }
        else
            csqc_inspect_settle_until = 0;
    }

    if (!csqc_inspect_mode)
        return;

    // The menu/console taking focus can SWALLOW the rotate key's key-up, which would
    // otherwise strand the mode with the view locked and the mouse eaten.
    if (!notmenu)                             { Inspect_Exit(); return; }

    if (!predicted_player)                    { Inspect_Exit(); return; }
    if (!predicted_player.pm_carrying)        { Inspect_Exit(); return; }
    if (getstati(STAT_HEALTH) <= 0)           { Inspect_Exit(); return; }
    if (Spectate_IsActive())                  { Inspect_Exit(); return; }
    if (held == world)                        { Inspect_Exit(); return; }

    Inspect_Send(FALSE);
}

// Input hook — called from CSQC_InputEvent.  Returns TRUE to consume the event.
float Inspect_InputEvent(float evtype, float scanx, float chary, float devid)
{
    // Track the rotate key's PHYSICAL state unconditionally, even when not carrying.
    // Entry then requires a fresh press: without this, holding Reload and then grabbing a
    // prop would silently lock your view.
    if (evtype == IE_KEYDOWN)
    {
        if (Inspect_IsRotateBind(scanx))
        {
            float was_down = csqc_inspect_key_down;
            csqc_inspect_key_down = TRUE;
            if (!was_down)
            {
                if (predicted_player)
                if (predicted_player.pm_carrying)
                {
                    Inspect_Enter();
                    // Consumed => the engine never runs the bind, so no reload impulse
                    // fires while inspecting.  Costs nothing when not carrying: we fall
                    // through and reload works normally.
                    if (csqc_inspect_mode)
                        return TRUE;
                }
            }
            else if (csqc_inspect_mode)
                return TRUE;   // key auto-repeat while inspecting
        }
    }
    else if (evtype == IE_KEYUP)
    {
        if (Inspect_IsRotateBind(scanx))
        {
            csqc_inspect_key_down = FALSE;
            if (csqc_inspect_mode)
            {
                Inspect_Exit();
                return TRUE;
            }
        }
    }

    if (!csqc_inspect_mode)
        return FALSE;

    // --- active: the mouse belongs to the prop, not the camera ---
    if (evtype == IE_MOUSEDELTA)
    {
        Inspect_Rotate(scanx, chary);
        // Consuming the delta is the whole view lock: it never reaches the engine's
        // viewangle integrator, so the view simply does not move.  Do NOT also touch
        // input_angles — that double-counts (see the documented door-yaw bug in
        // cl_player.qc) and would make the view drift while rotating.
        return TRUE;
    }

    if (evtype == IE_KEYDOWN)
    {
        // Wheel: push/pull.  Consumed ONLY in this mode, so nextwep/prevwep keep working
        // the rest of the time, including while carrying without the modifier.
        if (scanx == K_MWHEELUP)   { Inspect_Scroll( 1); return TRUE; }
        if (scanx == K_MWHEELDOWN) { Inspect_Scroll(-1); return TRUE; }

        // Escape / console exit explicitly, then pass the key through so the menu or
        // console still opens.  Both can swallow the rotate key's key-UP, which would
        // otherwise strand the mode with the view locked and the mouse eaten.
        if (scanx == K_ESCAPE)
        {
            Inspect_Exit();
            return FALSE;
        }
        if (getkeybind(scanx) == "toggleconsole")
        {
            Inspect_Exit();
            return FALSE;
        }

        // Swallow primary fire so a click during inspection doesn't THROW the prop.
        // KEYDOWN only, never KEYUP: consuming the release would leave +attack latched
        // "down" in the engine if the press happened before the mode was entered.
        string cb = getkeybind(scanx);
        if (cb == "+attack")  return TRUE;
        if (scanx == K_MOUSE1) return TRUE;
    }

    return FALSE;
}
