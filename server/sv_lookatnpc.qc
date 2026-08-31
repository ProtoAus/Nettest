// ============================================================================
//  server/sv_lookatnpc.qc  -  "what am I looking at" readout, monster half
// ============================================================================
//
//  client/cl_lookatname.qc has always been able to name the PLAYER under your
//  crosshair.  It resolves them by tracing against player_visual_proxy entities
//  — CSQC entities the mod spawns itself — and pulls the name from
//  getplayerkeyvalue().  Neither half of that reaches a monster:
//
//    * a monster is a plain engine-networked entity with no CSQC counterpart
//      (there is not one SendEntity in sv_monsters.qc), so it is in neither the
//      findchain nor the findfloat set the player path uses;
//    * and there is no player slot to read a name out of.
//
//  CSQC could do the IDENTIFICATION on its own — getentity() plus the
//  modelindex whitelist the server already publishes for the bullet trace is
//  exactly the machinery cl_monstertrace.qc uses — but it cannot get the HEALTH.
//  FTE's getentity enum has 37 members (common/pr_common.h:1020-1060) and none
//  of them is health; the packet entity state simply does not carry it, and
//  smuggling it through a render field (.skin, .colormod, .fatness) would add
//  delta bytes to EVERY client's snapshot of that monster instead of to the one
//  client actually looking at it.
//
//  So the health has to be unicast either way, and once you are unicasting the
//  health there is no reason to make the client ask first.  The server traces,
//  which also means:
//    - no request/response round trip, so the readout is not one RTT stale;
//    - the server's trace is the authoritative one (same .v_angle, same world),
//      so the tag names what you would actually shoot;
//    - and it is change-gated, so standing still looking at an undamaged
//      monster sends zero bytes.
//
//  The client still owns all the DRAWING and the hold/flicker window, and
//  anchors the world-space label off getentity() so the label tracks the
//  monster at render rate rather than at the 10 Hz this pulses.
// ============================================================================

.float  lan_next;        // per-player throttle stamp
.entity lan_target;      // the monster last reported to this client
.float  lan_sent_hp;
.float  lan_sent_max;
.float  lan_resend;      // next `time` an UNCHANGED but still-live target is re-sent

// 10 Hz, matching the client's own LOOKAT_PULSE_INTERVAL (cl_lookatname.qc:28)
// so the player tag and the NPC tag appear and clear at the same cadence.
const float LOOKAT_NPC_INTERVAL = 0.1;
// Deliberately shorter than the player tag's 4096: a name floating over a
// monster you cannot resolve visually is noise, and this trace runs server-side
// on every player every tenth of a second.
const float LOOKAT_NPC_RANGE    = 2048;

// THE HEARTBEAT, and without it the tag simply expires while you are still aiming
// at the monster.
//
// The two halves of this feature disagreed about who was in charge.  The server is
// EDGE-driven: the change gate below sends a packet when the target or its health
// changes and otherwise stays silent forever, which is a feature — an undamaged
// monster costs nothing.  The client is a DEAD-MAN'S SWITCH: it stamps
// lookat_npc_last_seen only when a packet arrives (cl_lookatname.qc:115) and
// clears the tag once LOOKAT_HOLD_TIME (0.9 s, :30) elapses without one.
//
// So: aim at an idle, undamaged NPC.  One packet on acquire, then silence, then
// 0.9 s later the client gives up — and nothing can ever bring it back, because
// from the server's point of view nothing has changed.  That is the reported
// "displays, then stops after a second even if I'm holding over the NPC", and the
// 0.9 matches the reported ~1 s exactly.
//
// That hold window was copied from the PLAYER tag, where it is correct: the player
// tag re-traces client-side at 10 Hz and re-stamps itself on every hit
// (cl_lookatname.qc:180-251).  The NPC tag has no such poll, so the timer has
// nothing to reset it.
//
// 0.4 puts two heartbeats inside the client's window, so one can be lost and the
// tag still holds.  It must stay comfortably under LOOKAT_HOLD_TIME — if it ever
// creeps above it, the symptom changes from a permanent disappearance to a ~1 Hz
// blink, which is much harder to recognise.  Steady-state cost is the 9 bytes
// cl_main.qc:2058 already documents, at 2.5 Hz, and only while a player is
// actually aiming at a live monster.
const float LOOKAT_NPC_REFRESH  = 0.4;

// IS THIS MONSTER SOMETHING THE PLAYER CAN ACTUALLY SEE?
//
// The trace is the only filter this readout had, and a trace answers the wrong
// question on a map that hides monsters behind non-solid scenery.  th_ep1_01
// buries eleven zombies under the graveyard "in the grave", waiting for the
// scripted_sequence that plays their climb-out; the ground over them is
// func_illusionary (75 of them on this map), which is SOLID_NOT by definition and
// therefore invisible to a traceline.  So the crosshair reached straight through
// the turf, found a live zombie, and floated a name and a health bar over a patch
// of empty grass.
//
// SF_MON_WAIT_FOR_SCRIPT is the exact statement of "this monster is not part of
// the map yet" - Half-Life's own MonsterInit refuses to start such a monster's
// AI at all until a script claims it - and .ai_script_played is what makes the
// flag a runtime question rather than a permanent one: it latches the first time
// any script releases the actor, so the zombie that has climbed out of its grave
// is taggable from that moment on, which is the behaviour asked for.
//
// EF_NODRAW is checked in the same breath because it is the other way a monster
// can be present and unseeable, and the answer for it is the same either way.
float(entity m) LookatNPC_Hidden =
{
    if ((m.spawnflags & SF_MON_WAIT_FOR_SCRIPT) && !m.ai_script_played)
        return TRUE;
    if (m.effects & EF_NODRAW)
        return TRUE;
    return FALSE;
};

void(entity p) LookatNPC_Tick =
{
    // Bots have no netchan, and writing to one spams "msg_entity: not a client"
    // every pulse — the same guard TrackTrain_SendHud needs for the same reason
    // (sv_func_traincontrols.qc:77-78).
    if (!SV_PlayerHasNetchan(p))
        return;
    if (time < p.lan_next)
        return;
    p.lan_next = time + LOOKAT_NPC_INTERVAL;

    entity hit = world;
    if (!p.is_dead)
    {
        makevectors(p.v_angle);
        vector eye = p.origin + p.view_ofs;
        traceline(eye, eye + v_forward * LOOKAT_NPC_RANGE, MOVE_NORMAL, p);
        // FL_MONSTER + alive + solid.  The solid test is what keeps a corpse
        // out (Monster_Killed drops it to SOLID_CORPSE), and the CLIENT reaches
        // the same conclusion for free from the inverted GE_ABSMIN/GE_ABSMAX
        // box — see the header of cl_monstersolid.qc:38-47 — so both ends agree
        // about corpses without spending a byte saying so.
        if (trace_ent && trace_ent != world
            && (trace_ent.flags & FL_MONSTER)
            && trace_ent.health > 0
            && trace_ent.solid != SOLID_NOT
            && !LookatNPC_Hidden(trace_ent))
            hit = trace_ent;
    }

    // Change gate: TrackTrain_SendHud's `if (plyr.tt_hud_sent == state+1) return;`
    // (sv_func_traincontrols.qc:72) widened from one value to three.
    // The `!hit` term is load-bearing.  Without it a player looking at a wall
    // (hit == world == lan_target) would emit a 9-byte "entnum 0" packet every
    // 0.4 s forever, for every connected player.  With it, the no-target case
    // keeps the original pure change gate: send the clear once, then silence.
    if (hit == p.lan_target
        && hit.health     == p.lan_sent_hp
        && hit.max_health == p.lan_sent_max
        && (!hit || time < p.lan_resend))
        return;

    float newtarget = (hit != p.lan_target);
    p.lan_target   = hit;
    p.lan_sent_hp  = hit.health;
    p.lan_sent_max = hit.max_health;
    p.lan_resend   = time + LOOKAT_NPC_REFRESH;

    msg_entity = p;
    WriteByte (MSG_ONE, SVC_CGAMEPACKET);
    WriteByte (MSG_ONE, CSQC_EVENT_LOOKAT_NPC);
    WriteShort(MSG_ONE, hit ? num_for_edict(hit) : 0);
    if (hit)
    {
        WriteShort(MSG_ONE, bound(0, rint(hit.health),     32767));
        // A monster whose max_health was never seated (nothing outside
        // Monster_Build sets it, and the tentacle/nihilanth build themselves)
        // would divide by zero on the HUD bar, so floor it at the current HP.
        float mx = hit.max_health;
        if (mx < hit.health) mx = hit.health;
        if (mx <= 0)         mx = 1;
        WriteShort(MSG_ONE, bound(0, rint(mx), 32767));
        WriteByte (MSG_ONE, newtarget);
        if (newtarget)
            WriteString(MSG_ONE, Monster_DisplayName(hit));
    }

    // Gated on the TARGET CHANGE, not on every send, so a monster losing health
    // does not spam.  Worth having at all for the reason cl_monstertrace.qc:44-48
    // gives about its own counters: a HUD label leaves no trace in a headless log,
    // so "the trace ran and found nothing" and "the trace never ran" are otherwise
    // the same observation — which is exactly how a wire feature ships broken.
    if (newtarget && cvar("sv_ai_debug"))
        dprint(sprintf("[lookat] %s -> %s\n", p.netname,
                       hit ? sprintf("%s ent=%g hp=%g/%g", Monster_DisplayName(hit),
                                     num_for_edict(hit), hit.health, hit.max_health)
                           : "(nothing)"));
};
