// ============================================================================
//  cl_prophunt_rotate.qc — Prop Hunt: free 3-axis rotation of your disguise
// ============================================================================
//
//  While disguised as a prop, the RELOAD key drives three gestures (gated to
//  disguised hiders so a seeker's reload is untouched):
//
//    TAP        -> toggle the rotation lock (no-snap: unlocking preserves the pose)
//    HOLD       -> "inspect" free rotate: the view locks, the mouse spins the prop
//                  on all axes (lie it down), the pose commits on release
//    DOUBLE-TAP -> reset the prop upright
//
//  Structurally a sibling of cl_carryinspect.qc (the carried-prop inspect mode):
//  same physical-key tracking, same view-lock-by-consuming-IE_MOUSEDELTA, same
//  rate-limited absolute-state sendevent.  The orientation is CLIENT-OWNED and
//  predicted here (prot_rel_fwd/up) so the local prop rotates zero-ping; the
//  server (CSEv_proprot_v / CSEv_propgest_f) validates + echoes to everyone else.
//
//  Reuses the shared basis math in sh_carryrot.qc (CarryRot_*), and the compose
//  helper PH_PoseAngles.  The disguise predraw (cl_player.qc) reads this module's
//  pose via the forward-declared PropRot_HaveLocalPose / PropRot_LocalPoseAngles.
//
//  Compiled after cl_player / cl_prophunt so it can see predicted_player + the
//  disguise fields; the predraw reaches back via cl_customdefs.qc forward decls.
// ============================================================================

// --- physical-key + gesture state (file scope) ---
//
// GESTURE MODEL (all discrete gestures resolve on the key's RELEASE / after its window, never
// mid-hold — so HOLDING the key to rotate can never flip your lock status):
//   HOLD  (key down past holdtime)          -> free 3-axis rotate; RELEASE commits, no toggle
//   TAP   (quick press+release, lone)        -> toggle the lock (fires once the dbl-tap window shuts)
//   DBL-TAP (2nd fresh press within taptime) -> reset upright (the only press-edge action)
float  prot_key_down;       // raw physical state of the rotate key (tracked even when not disguised)
float  prot_mode;           // 1 = active HOLD rotate: view locked, mouse drives the prop
float  prot_press_time;     // cltime of the current key-down (hold-vs-tap timing)
float  prot_press_dead;     // this press must yield NO gesture (phantom guard, or spent by a double-tap)
float  prot_pending_tap;    // a lone quick tap awaiting the double-tap window before it becomes a lock toggle
float  prot_last_up_time;   // cltime of the last quick release (double-tap detection)
float  prot_dirty;          // basis changed since the last upstream send
float  prot_next_send;      // cltime of the next allowed send
float  prot_settle_until;   // keep re-sending the final pose until this cltime (server rate-gate slack)

// --- client-owned orientation (mirrors the server ph_rel_fwd/up + lock) ---
vector prot_rel_fwd;        // model +X in the carry frame (yaw0 = v_angle_y + 180)
vector prot_rel_up;         // model +Z in the carry frame
float  prot_locked;         // 0 = loose (yaw follows the view), 1 = committed world-absolute
float  prot_locked_yaw0;    // frozen view yaw (v_angle_y) while committed
float  prot_have;           // 1 = seeded (currently disguised)

// Is this key the rotate key?  Matched on the bind STRING (reload is an edge-only
// impulse 6 with no button to test) — same as cl_carryinspect.qc.
float PropRot_IsRotateBind(float scan)
{
    string b = getkeybind(scan);
    if (b == "impulse 6")   return TRUE;
    if (b == "+proprotate") return TRUE;
    return FALSE;
}

// Am I (locally) a live disguised hider who should own the rotate key?
//
// CRITICAL: the disguise flag rides our VISUAL PROXY (read from Wire A onto the proxy at
// cl_player.qc:~5007), NOT predicted_player — predicted_player never carries
// ph_disguise_modelindex, so testing it there was ALWAYS false and left this whole module
// inert (no hold, no local pose; the un-consumed reload key even spammed the server-side
// impulse-6 lock fallback, which is what flickered the pose locked/unlocked).  Find our own
// proxy (vis_owner_entnum == our slot) and test IT instead.
float PropRot_Disguised()
{
    if (!player_localentnum)         return FALSE;
    if (getstati(STAT_HEALTH) <= 0)  return FALSE;
    if (Spectate_IsActive())         return FALSE;
    entity proxy = findfloat(world, vis_owner_entnum, player_localentnum);
    if (!proxy)                                    return FALSE;
    if (proxy.classname != "player_visual_proxy")  return FALSE;
    if (!proxy.ph_disguise_modelindex)             return FALSE;
    if (proxy.vis_is_dead)                          return FALSE;
    return TRUE;
}

// Predraw hooks (forward-declared in cl_customdefs.qc so the earlier-compiled
// disguise predraw can call them).
float PropRot_HaveLocalPose()
{
    return prot_have;
}
vector PropRot_LocalPoseAngles(float view_yaw)
{
    float yaw0 = (prot_locked ? prot_locked_yaw0 : view_yaw) + 180;
    return PH_PoseAngles(prot_rel_fwd, prot_rel_up, yaw0);
}

void PropRot_Seed()
{
    prot_rel_fwd = '-1 0 0';   // matches PropHunt_Possess: upright pose == old flat facing
    prot_rel_up  = '0 0 1';
    prot_locked  = 0;
    prot_have    = 1;
    prot_pending_tap = 0;
    // If the rotate key is ALREADY physically held as the disguise begins (holding R while
    // pressing +use to possess), mark this press dead so the time-based hold-promote in
    // PropRot_Frame can't fire on it — a fresh release + press is required.  (Entry here is
    // time-gated, not fresh-edge like carryinspect, so was_down alone doesn't cover this.)
    if (prot_key_down)
        prot_press_dead = TRUE;
}

// --- upstream ---
void PropRot_Send(float force)
{
    if (!prot_have)
        return;
    if (!force)
    {
        if (!prot_dirty)             return;
        if (cltime < prot_next_send) return;
    }
    float rate = cvar("cl_carry_rotate_sendrate");
    if (rate < 1) rate = 1;
    prot_next_send = cltime + (1 / rate);
    prot_dirty     = FALSE;

    // Send the frozen frame yaw ALONGSIDE the basis so the server composes the identical
    // world pose it (and everyone else) will see — never re-derive it from the live server
    // yaw, which drifts during the post-release settle window while the view is free.
    sendevent("proprot", "vf", CarryRot_Angles(prot_rel_fwd, prot_rel_up), prot_locked_yaw0);
}

void PropRot_SendGesture(float mode, float frame_yaw)
{
    sendevent("propgest", "ff", mode, frame_yaw);
}

// --- gestures ---
void PropRot_DoLockToggle()
{
    vector va = (vector)getproperty(VF_CL_VIEWANGLES);
    if (prot_locked)
    {
        // UNLOCK with no-snap re-anchor (mirror of PropHunt_ToggleLock server-side):
        // re-express the frozen world pose in the LIVE view frame so it continues from
        // exactly where it is, then resumes yaw-following.
        float lyaw0 = prot_locked_yaw0 + 180;
        float vyaw0 = va_y + 180;
        vector wF = CarryRot_FromFrame(prot_rel_fwd, lyaw0);
        vector wU = CarryRot_FromFrame(prot_rel_up,  lyaw0);
        prot_rel_fwd = CarryRot_ToFrame(wF, vyaw0);
        prot_rel_up  = CarryRot_ToFrame(wU, vyaw0);
        prot_locked  = 0;
    }
    else
    {
        prot_locked      = 1;
        prot_locked_yaw0 = va_y;   // freeze the frame; the basis is already the shown pose
    }
    PropRot_SendGesture(1, va_y);   // server re-anchors to the SAME frame we did
}

void PropRot_DoReset()
{
    vector va = (vector)getproperty(VF_CL_VIEWANGLES);
    prot_rel_fwd = '-1 0 0';
    prot_rel_up  = '0 0 1';
    prot_locked  = 0;
    PropRot_SendGesture(2, va_y);
}

void PropRot_EnterHold()
{
    if (prot_mode)
        return;
    prot_mode = TRUE;
    // Posing commits (world-absolute); freeze the frame at the current view so the mouse
    // alone changes the pose.  The view is locked below, so this yaw stays constant.
    vector va = (vector)getproperty(VF_CL_VIEWANGLES);
    prot_locked      = 1;
    prot_locked_yaw0 = va_y;
    prot_dirty       = TRUE;
}

void PropRot_ExitHold()
{
    if (!prot_mode)
        return;
    prot_mode     = FALSE;
    prot_key_down = FALSE;
    // Converge the server on the final pose despite its rate gate (see cl_carryinspect.qc).
    PropRot_Send(TRUE);
    prot_settle_until = cltime + 0.4;
}

void PropRot_Rotate(float dx, float dy)
{
    float spd = cvar("cl_carry_rotate_speed");
    if (spd <= 0) spd = 0.35;
    if (cvar("cl_carry_rotate_invert"))
        dy = dy * -1;

    // Same two carry-frame axes cl_carryinspect uses: mouse X = turntable about world up,
    // mouse Y = tip about the view-right (which is constant (0,1,0) in the +180 frame).
    CarryRot_SpinBasis(prot_rel_fwd, prot_rel_up, '0 0 1', dx * spd * -1);
    CarryRot_SpinBasis(crot_oF,      crot_oU,     '0 1 0', dy * spd);
    prot_rel_fwd = crot_oF;
    prot_rel_up  = crot_oU;
    prot_dirty   = TRUE;
}

// Per-frame guard + timers.  Called from CSQC_UpdateView.
void PropRot_Frame(float notmenu)
{
    // Seed / unseed as the disguise turns on and off.
    if (PropRot_Disguised())
    {
        if (!prot_have)
            PropRot_Seed();
    }
    else if (prot_have)
    {
        if (prot_mode) PropRot_ExitHold();
        prot_have        = 0;
        prot_pending_tap = 0;
        prot_press_dead  = 0;
        // NOTE: prot_key_down is left as the true PHYSICAL state (only real KEYUP clears
        // it) so re-disguising while still holding the key can't phantom-enter rotate.
    }

    // Settle retry window (runs even after the mode is off — server may have rate-dropped
    // the last send).
    if (prot_settle_until > 0)
    {
        if (cltime < prot_settle_until)
        {
            prot_dirty = TRUE;
            PropRot_Send(FALSE);
        }
        else
            prot_settle_until = 0;
    }

    if (!prot_have)
        return;

    // A press held past the threshold becomes a free HOLD rotate.  Entering cancels any
    // armed tap (the key is clearly not a tap) so no stray lock toggle fires on release.
    if (prot_key_down && !prot_mode && !prot_press_dead
        && (cltime - prot_press_time) >= cvar("cl_prop_rotate_holdtime"))
    {
        prot_pending_tap = 0;
        PropRot_EnterHold();
    }

    // A lone tap that outlived the double-tap window (key already released) is a single tap
    // -> toggle the lock.  Guarded on !prot_key_down so it can only ever fire on/after the
    // RELEASE — holding the key never flips the lock.
    if (prot_pending_tap && !prot_key_down
        && (cltime - prot_last_up_time) > cvar("cl_prop_rotate_taptime"))
    {
        prot_pending_tap = 0;
        PropRot_DoLockToggle();
    }

    if (!prot_mode)
        return;

    // Active hold — every exit path must restore the view.
    if (!notmenu)                              { PropRot_ExitHold(); return; }
    if (!PropRot_Disguised())                  { PropRot_ExitHold(); return; }

    PropRot_Send(FALSE);
}

// Input hook — called from CSQC_InputEvent.  Returns TRUE to consume the event.
float PropRot_InputEvent(float evtype, float scanx, float chary, float devid)
{
    // Track the rotate key's PHYSICAL state UNCONDITIONALLY (like cl_carryinspect), even
    // when NOT disguised — so a disguise that begins while the key is already held cannot
    // auto-enter rotate (a fresh press edge is required).  Only ACT on / CONSUME the key
    // while disguised, so a seeker's reload is untouched.
    if (evtype == IE_KEYDOWN && PropRot_IsRotateBind(scanx))
    {
        float was_down = prot_key_down;
        prot_key_down = TRUE;
        if (!PropRot_Disguised())
            return FALSE;               // not us — state tracked, reload runs normally
        if (!was_down)
        {
            // A second fresh press within the window of the last quick release = DOUBLE TAP
            // -> reset.  This is the ONLY action taken on a press edge; lock/unlock is
            // deferred to release so holding the key can't disturb the lock.
            if (prot_pending_tap
                && (cltime - prot_last_up_time) <= cvar("cl_prop_rotate_taptime"))
            {
                prot_pending_tap = 0;
                prot_press_dead  = TRUE;   // this press is spent; its release does nothing
                PropRot_DoReset();
            }
            else
            {
                prot_press_time = cltime;  // start the hold/tap clock (gesture resolves on release)
                prot_press_dead = FALSE;
            }
        }
        return TRUE;   // consume so impulse 6 (reload) never fires while disguised
    }
    if (evtype == IE_KEYUP && PropRot_IsRotateBind(scanx))
    {
        prot_key_down = FALSE;
        if (!PropRot_Disguised())
            return FALSE;
        if (prot_mode)                     // released a HOLD -> commit the pose, no lock toggle
        {
            PropRot_ExitHold();
            return TRUE;
        }
        if (prot_press_dead)               // phantom / double-tap-spent press -> ignore
        {
            prot_press_dead = FALSE;
            return TRUE;
        }
        // A quick release (below the hold threshold) is a TAP: arm a pending tap.  Frame
        // promotes it to a lock toggle once the double-tap window closes; a second fresh
        // press within the window (above) cancels it into a reset instead.
        if ((cltime - prot_press_time) < cvar("cl_prop_rotate_holdtime"))
        {
            prot_pending_tap  = TRUE;
            prot_last_up_time = cltime;
        }
        return TRUE;
    }

    // Everything below only matters during an active hold that is still ours.
    if (!prot_mode || !PropRot_Disguised())
        return FALSE;

    // --- active hold: the mouse belongs to the prop, not the camera ---
    if (evtype == IE_MOUSEDELTA)
    {
        PropRot_Rotate(scanx, chary);
        return TRUE;   // consuming the delta IS the view lock (see cl_carryinspect.qc)
    }

    if (evtype == IE_KEYDOWN)
    {
        // Let Escape / console still open, but exit cleanly first so the view isn't
        // stranded locked (they can swallow the key-up).
        if (scanx == K_ESCAPE)                    { PropRot_ExitHold(); return FALSE; }
        if (getkeybind(scanx) == "toggleconsole") { PropRot_ExitHold(); return FALSE; }
        // Swallow primary fire so a click mid-pose does nothing odd.
        if (getkeybind(scanx) == "+attack")       return TRUE;
        if (scanx == K_MOUSE1)                    return TRUE;
    }

    return FALSE;
}
