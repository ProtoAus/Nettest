//
//  sv_doors.qc  –  shared door/button helpers + sliding func_door
//
//  This file owns the cross-entity helpers consumed by sv_buttons.qc,
//  sv_doors_rotating.qc, sv_trigger_hurt.qc and sv_trigger_gravity.qc:
//   - HL/GoldSrc sound-lookup tables (Door_Lookup{Move,Stop,Locked,Unlocked}Sound,
//     Button_LookupSound, Door_PrecacheIfReal)
//   - Generic Mover_Start (linear translation)
//   - Trigger_UseTargets (target-chain firing helper)
//   - Shared field declarations (.float dmg, .float movesnd, .string noise_locked, ...)
//
//  Then it implements the sliding `func_door` itself.  Rotating doors,
//  buttons and trigger_hurt / trigger_gravity each live in their own
//  file under server/.
//
//  Compile order in sv_progs.src: this file MUST load before the
//  per-entity files because they extern its helpers.
//

// Forward decls — sh_pmove.qc compiles AFTER this file in sv_progs.src,
// so the moving-brush list helpers it defines need to be predeclared
// here for Mover_Start / Mover_TravelTick to reference them.
// Sven InventoryRules gate — defined in sv_item_inventory.qc (position 265),
// which compiles after this file; the KEY FIELDS it reads live in
// sv_customdefs.qc for exactly that reason.
float(entity rules, entity who) Inv_Gate;                            // sv_item_inventory.qc
void(entity c) MovingBrush_AddToList;
void(entity c) MovingBrush_RemoveFromList;

// Geometry-aware per-tick push for doors + buttons.  Defined in
// sv_platform_carry.qc (compiles after us in sv_progs.src).  Uses
// the PM_TRIGGER_PROBE_DIM dimension-bit trick to confirm the
// player's bbox actually intersects this brush's BSP geometry —
// not just the AABB — before pushing.  Replaces the old bbox-
// overlap Mover_PushPlayers loop so doors push by mesh, not by
// trigger-box.  On wedge it invokes self.blocked() (door_blocked
// applies dmg + reverses, or grinds on UNBLOCKABLE).
float() Mover_GeometryBlockPush;

// Stand-on-top platform carry — players whose feet trace down to
// this brush get locked 1:1 to the brush's per-tick translation.
// Also handles the "rode the brush into a wall" case: trace fails,
// player stops at the wall, brush keeps moving past them.  Lives
// in sv_platform_carry.qc alongside the geometry push.
float() Mover_PlatformCarry;

// ============================================================================
//  Shared helpers
// ============================================================================

// HL/GoldSrc map keys for door + button sound selection.
//   movesnd / stopsnd      — door open / close sound pair (index → WAV).
//   locked_sound / unlocked_sound — feedback when an entity is in
//     locked / unlocked state.  Currently precached + reachable via
//     self.noise_locked / self.noise_unlocked but the door's
//     "locked" state machine isn't fully wired yet — mappers can
//     set them and the resolved string will be on the entity for
//     future hooks.
.float movesnd;
.float stopsnd;
.float locked_sound;
.float unlocked_sound;
.string noise_locked;
.string noise_unlocked;

void() SetMovedir;   // defined in sv_push.qc

// Declared authoritatively in sv_triggers.qc, which compiles AFTER this file
// (sv_progs.src: sv_doors.qc then sv_triggers.qc).  Identical field/prototype
// re-declarations share the same slot in QC, so declaring them here lets the
// door's master gate compile without reordering the whole chain.
.string master;
float(string master_name, entity who) IsMasterTriggered;

// useType pass-through globals — the GoldSrc trigger suite (sv_triggers.qc
// and the per-entity files compiled after it) sets these before each
// .use() call to communicate USE_OFF / USE_ON / USE_TOGGLE semantics and
// the firing entity (multisource needs the caller to dedupe inputs).
// sub_use_type == USE_UNSET (-1) falls back to USE_TOGGLE inside the loop
// below — preserves behaviour for legacy callers (button / breakable / etc.)
// that don't know about useType yet.  The sentinel is NOT 0: USE_OFF is 0, and
// using it for "unset" silently promoted every explicit Off in the mod to a
// Toggle.  See sv_customdefs.qc.  worldspawn seeds the global (sv_main.qc) and
// SV_PlayerTryUse re-seeds it per press (sv_use.qc).
float  sub_use_type;       // declared here so sv_doors.qc compiles standalone
entity sub_use_caller;
// Set by SUB_DelayedFire (sv_triggers.qc) on its throwaway temp entity so
// Trigger_UseTargets below can report the ORIGINAL caller as sub_use_caller.
// Declared here rather than there because sv_triggers.qc compiles after us.
.entity delayed_origcaller;
// USE_OFF / USE_ON / USE_SET / USE_TOGGLE moved to sv_customdefs.qc so the
// files that compile BEFORE this one (notably sv_breakable.qc) can name them
// when firing chains through SUB_UseTargets.

void(entity caller, entity triggerer) Trigger_UseTargets =
{
    entity target_entity;
    entity oldself;
    entity oldactivator;
    entity oldcaller;
    float  oldusetype;
    float  olddirect;
    float  oldtouch;

    if (!caller.target)
        return;

    oldactivator = activator;
    oldcaller    = sub_use_caller;
    oldusetype   = sub_use_type;
    olddirect    = sv_use_is_player_direct;
    oldtouch     = sv_use_is_player_touch;
    activator    = triggerer;

    // The targets fired by this chain are activated INDIRECTLY (the
    // caller is some other entity, not a player +use trace), so the
    // "is this a direct player +use?" flag must be FALSE for them
    // regardless of whether the chain was kicked off by a player.
    // Without this, a button's synchronous fire (BUTTON_DONT_MOVE
    // routes button_wait → Trigger_UseTargets directly inside
    // SV_PlayerTryUse where the flag is still TRUE) would be seen by
    // the door as a direct player press rather than a chain fire —
    // which is what NO_TRIGGER / USE_ONLY discriminate on.
    // ...and the same for the touch flag, for the same reason: a door opened by
    // a shoulder fires its own target chain, and a second, unrelated locked door
    // downstream of that chain must not click.
    sv_use_is_player_direct = FALSE;
    sv_use_is_player_touch  = FALSE;

    // Default useType for legacy callers — they invoke this two-arg
    // form without setting sub_use_type, so treat as toggle (the HL
    // default for SUB_UseTargets).
    //
    // THE SENTINEL IS USE_UNSET (-1), NOT 0.  This test used to read
    // `sub_use_type == 0`, and USE_OFF is 0, so every explicit Off in the mod
    // was rewritten to Toggle right here — see the long note on USE_UNSET in
    // sv_customdefs.qc.  Anything reaching this function without having set the
    // global gets USE_UNSET now (worldspawn seeds it, sv_use.qc re-seeds it per
    // player press) and still lands on USE_TOGGLE, which is HL's default for
    // SUB_UseTargets.
    if (sub_use_type == USE_UNSET)
        sub_use_type = USE_TOGGLE;

    target_entity = find(world, targetname, caller.target);
    float dbg = cvar("sv_debug_use");
    while (target_entity)
    {
        if (target_entity != caller && target_entity.use)
        {
            if (dbg)
            {
                print(sprintf("[chain] %s(\"%s\") -> %s(\"%s\")  useType=%g\n",
                              caller.classname, caller.targetname,
                              target_entity.classname, target_entity.targetname,
                              sub_use_type));
            }
            oldself = self;
            self = target_entity;
            // multisource reads this to identify WHICH input reported.
            // For a delayed fire the caller is the throwaway "delayed_use"
            // temp entity, which a strict multisource has never registered
            // and would therefore ignore — so report the entity that
            // actually scheduled the fire (stamped by SUB_DelayedFire).
            sub_use_caller = caller.delayed_origcaller ? caller.delayed_origcaller : caller;
            self.use();
            self = oldself;
        }
        target_entity = find(target_entity, targetname, caller.target);
    }

    activator               = oldactivator;
    sub_use_caller          = oldcaller;
    sub_use_type            = oldusetype;
    sv_use_is_player_direct = olddirect;
    sv_use_is_player_touch  = oldtouch;
};

// ============================================================================
//  HL/GoldSrc sound lookup tables — shared by func_door, func_door_rotating
//  and func_button.  Map keys movesnd / stopsnd / locked_sound /
//  unlocked_sound (and func_button's `sounds`) carry small integer
//  indices that resolve to specific WAV paths in sound/doors/ and
//  sound/buttons/.  Values 0 always map to common/null.wav (silence).
//  Unknown indices fall back to silence so a typo doesn't crash on
//  precache_sound("").
// ============================================================================

string(float idx) Door_LookupMoveSound =
{
    if (idx == 1)  return "doors/doormove1.wav";
    if (idx == 2)  return "doors/doormove2.wav";
    if (idx == 3)  return "doors/doormove3.wav";
    if (idx == 4)  return "doors/doormove4.wav";
    if (idx == 5)  return "doors/doormove5.wav";
    if (idx == 6)  return "doors/doormove6.wav";
    if (idx == 7)  return "doors/doormove7.wav";
    if (idx == 8)  return "doors/doormove8.wav";
    if (idx == 9)  return "doors/doormove9.wav";
    if (idx == 10) return "doors/doormove10.wav";
    return "common/null.wav";
};

string(float idx) Door_LookupStopSound =
{
    if (idx == 1) return "doors/doorstop1.wav";
    if (idx == 2) return "doors/doorstop2.wav";
    if (idx == 3) return "doors/doorstop3.wav";
    if (idx == 4) return "doors/doorstop4.wav";
    if (idx == 5) return "doors/doorstop5.wav";
    if (idx == 6) return "doors/doorstop6.wav";
    if (idx == 7) return "doors/doorstop7.wav";
    if (idx == 8) return "doors/doorstop8.wav";
    return "common/null.wav";
};

string(float idx) Door_LookupLockedSound =
{
    if (idx == 2)  return "buttons/button2.wav";
    if (idx == 8)  return "buttons/button8.wav";
    if (idx == 10) return "buttons/button10.wav";
    if (idx == 11) return "buttons/button11.wav";
    if (idx == 12) return "buttons/latchlocked1.wav";
    return "common/null.wav";
};

string(float idx) Door_LookupUnlockedSound =
{
    if (idx == 1)  return "buttons/button1.wav";
    if (idx == 3)  return "buttons/button3.wav";
    if (idx == 4)  return "buttons/button4.wav";
    if (idx == 5)  return "buttons/button5.wav";
    if (idx == 6)  return "buttons/button6.wav";
    if (idx == 7)  return "buttons/button7.wav";
    if (idx == 8)  return "buttons/button8.wav";
    if (idx == 9)  return "buttons/button9.wav";
    if (idx == 10) return "buttons/button10.wav";
    if (idx == 13) return "buttons/latchunlocked1.wav";
    if (idx == 14) return "buttons/lightswitch2.wav";
    return "common/null.wav";
};

// func_button's `sounds` key uses the GoldSrc button index space
// (subset of the unlocked-sound table plus a couple of extras).
string(float idx) Button_LookupSound =
{
    if (idx == 1)  return "buttons/button1.wav";
    if (idx == 2)  return "buttons/button2.wav";
    if (idx == 3)  return "buttons/button3.wav";
    if (idx == 4)  return "buttons/button4.wav";
    if (idx == 5)  return "buttons/button5.wav";
    if (idx == 6)  return "buttons/button6.wav";
    if (idx == 7)  return "buttons/button7.wav";
    if (idx == 8)  return "buttons/button8.wav";
    if (idx == 9)  return "buttons/button9.wav";
    if (idx == 10) return "buttons/button10.wav";
    if (idx == 11) return "buttons/button11.wav";
    if (idx == 14) return "buttons/lightswitch2.wav";
    return "common/null.wav";
};

// Helper: precache a sound only if it's a real path (lookup returns
// "common/null.wav" for the silence sentinel so let the engine
// dedup-precache that one).
void(string snd) Door_PrecacheIfReal =
{
    if (snd != "" && snd != __NULL__)
        precache_sound(snd);
};

float(string snd) Door_IsSilentSound =
{
    if (snd == "" || snd == __NULL__)
        return TRUE;
    if (snd == "common/null.wav" || snd == "misc/null.wav" || snd == "sounds/null.wav")
        return TRUE;
    return FALSE;
};

// ---------------------------------------------------------------------------
// SV_StopChannel — actually stop a looping sound on one entity/channel.
//
// `sound(e, chan, "", 0, ATTN_NORM)` DOES NOT DO THIS, and six call sites in
// this tree believed it did.  FTE's SV_StartSound (engine/server/sv_send.c:1300):
//
//     if (!sample)          ctx.sampleidx = 0;    // the real stop path
//     else if (!*sample)    return;               // <-- an empty string, silently
//
// and QC cannot reach the first branch: PF_sound fetches the argument with
// PR_GetStringOfs, and PR_StringToNative (qclib/initlib.c:1074-1115) never
// returns NULL - a zero string offset comes back as `stringtable + 0`, which
// is a valid pointer to "".  So every one of those calls took the second
// branch and sent nothing at all.
//
// Doors got away with it by accident: Door_PlayStopSound plays noise1 on the
// SAME CHAN_VOICE, and Quake's SND_PickChannel frees whatever was on an
// ent/channel pair before starting the new sound - so the arrival sound was
// doing the stopping, not the stop.  The plat family is where it showed,
// because it is the only mover that puts its arrival sound on a DIFFERENT
// channel (CHAN_WEAPON) from its movement loop, mirroring HL's
// CHAN_STATIC/CHAN_WEAPON split.  hl_c01_a1's `ele_2` has movesnd 12
// (plats/talkmove1.wav, loop-cued) and nothing ever replaced it: the lift
// arrived, fired its chain, and kept grinding for the rest of the map.
//
// The fix is to play something real on the channel.  common/null.wav is
// GoldSrc's own silence (1244 bytes, present in both the valve and svencoop
// mounts) and is already this file's sentinel for "no sound", so it needs no
// new asset.  Precached in Door_PrecacheSounds; if a user's install somehow
// lacks it FTE late-precaches with one warning rather than failing.
const string SND_SILENCE = "common/null.wav";

void(entity e, float chan) SV_StopChannel =
{
    sound(e, chan, SND_SILENCE, 1, ATTN_NORM);
};

void() Door_StopMoveSound =
{
    // Cut the current door movement sound on CHAN_VOICE.  This matters
    // for loop-cued GoldSrc movement WAVs: if there is no stop sound to
    // replace the channel, the loop can otherwise continue after the
    // brush has arrived.
    SV_StopChannel(self, CHAN_VOICE);
};

void() Door_PlayMoveSound =
{
    if (!Door_IsSilentSound(self.noise2))
        sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);
};

void() Door_PlayStopSound =
{
    Door_StopMoveSound();
    if (!Door_IsSilentSound(self.noise1))
        sound(self, CHAN_VOICE, self.noise1, 1, ATTN_NORM);
};

// Feedback for a +use that a master rejected.  Mirrors HL's
// CBaseDoor::DoorTouch, which plays m_ls.sLockedSound with a re-press
// cooldown so mashing the key doesn't machine-gun the click.
//
// CHAN_ITEM, NOT CHAN_VOICE: CHAN_VOICE carries the move/stop loop
// (Door_PlayMoveSound / Door_PlayStopSound), and a locked click must not cut
// a neighbouring door's travel sound short.
//
// The unconditional fallback matters more than it looks.  A locked door that
// makes NO sound is indistinguishable from a +use that missed — which is
// exactly the silent-failure class of bug this whole change set exists to
// remove.  Most GoldSrc doors do set locked_sound (13 of 70 on the reference
// map), but the rest would otherwise be mute.
const string DOOR_DEFAULT_LOCKED_SND = "buttons/button2.wav";
.float door_locked_snd_time;

// Half-Life's PlayLockSounds debounce.  doors.cpp:96-98 defines
//     #define DOOR_SENTENCEWAIT 6
//     #define DOOR_SOUNDWAIT    3
//     #define BUTTON_SOUNDWAIT  0.5
// and picks between the last two on its `fbutton` argument (doors.cpp:114-117).
// This value used to be 0.5 — the BUTTON one — which was survivable while +use
// was the only way to reach a locked door.  It is not survivable from a touch
// field: SV_CheckTouchTriggers dispatches once per player per frame, so leaning
// on a locked door machine-guns the click twice a second forever.  Every caller
// here is a door, so take the door value.  (func_button has its own locked path
// in sv_buttons.qc and does not come through here.)
//
// locked_sentence / unlocked_sentence stay unimplemented: no .qc reads either
// key, there is no SENTENCEG_PlaySequentialSz equivalent, and no th_* map sets
// them — so HL's sentence half of PlayLockSounds (doors.cpp:139-152,
// DOOR_SENTENCEWAIT 6) is deliberately out of scope rather than half-ported.
const float DOOR_SOUNDWAIT = 3;

void() Door_PlayLockedSound =
{
    if (self.door_locked_snd_time > time)
        return;
    self.door_locked_snd_time = time + DOOR_SOUNDWAIT;

    if (!Door_IsSilentSound(self.noise_locked))
        sound(self, CHAN_ITEM, self.noise_locked, 1, ATTN_NORM);
    else
        sound(self, CHAN_ITEM, DOOR_DEFAULT_LOCKED_SND, 1, ATTN_NORM);
};

// `master` gate shared by func_door and func_door_rotating.  Returns TRUE
// when the door should refuse this activation (and has already given the
// player feedback).  Off by default — see sv_door_master in sh_cvar_table.qc
// for why enabling it on a map with unimplemented trigger chains is worse
// than leaving doors permissive.
float() Door_MasterBlocks =
{
    if (!self.master || self.master == "")
        return FALSE;
    if (!cvar("sv_door_master"))
        return FALSE;
    if (IsMasterTriggered(self.master, activator))
        return FALSE;

    if (cvar("sv_debug_doors"))
        dprint(sprintf("[door %s] locked by master \"%s\"\n",
                       self.targetname, self.master));
    // Only the player gets the click — a trigger chain hitting a locked door
    // should be silent.  Touch counts as a player: CBaseDoor::DoorTouch's very
    // first refusal arm is
    //     if (m_sMaster && !UTIL_IsMasterTriggered(m_sMaster, pOther))
    //         PlayLockSounds(pev, &m_ls, TRUE, FALSE);
    //                                            (doors.cpp:496-497)
    // and it does NOT return — the refusal itself lands one frame later in
    // DoorActivate's own master test (doors.cpp:532-533).  Our early return here
    // collapses the two into one step; the audible result is identical.  48 of
    // the 128 corpus doors that gain a touch field carry a master (th_ep1_01's
    // padlock doors among them), so without this arm the single most common
    // locked door in the game would be mute to a shoulder.
    if (sv_use_is_player_direct || sv_use_is_player_touch)
        Door_PlayLockedSound();
    return TRUE;
};

// ============================================================================
//  Generic mover  –  velocity-based movement toward a destination
//  Sets SendFlags so the CSQC entity gets the updated position + velocity.
// ============================================================================

// Per-mover state for the per-tick travel think — required because
// players use MOVETYPE_NONE (custom pmove), and the engine's
// WPhys_Push explicitly skips MOVETYPE_NONE entities (sv_phys.c:754-758).
// That means a sliding door phases right through the player and
// .blocked never fires.  We now run an authoritative QC push pass at
// sv_func_tickrate during travel; these fields hold the destination
// we're heading to and the move_done callback to fire once we arrive.
.vector mover_dest;
.void() mover_done_cb;
// Snapshot of the velocity the door starts moving at, captured by
// Mover_Start.  Used by the arrival check for per-tick distance
// (self.velocity may equal this throughout transit since the door
// no longer pauses on block) and by sv_platform_carry.qc's
// geometry-push direction fallback for the unlikely case where
// .blocked side-effects zeroed self.velocity briefly.
.vector mover_planned_velocity;
// The angular half of the same pause.  A func_platrot spins and translates in
// lockstep (Plat_RotStart sizes the avelocity so both finish together), but the wedge
// pause below only ever stopped the translation - so a blocked platrot kept turning
// and arrived at its end angle while still short of its end position.  Stash it here
// while paused and hand it back when the wedge clears.
.vector mover_paused_avelocity;

// Per-tick travel think — runs at sv_func_tickrate during the move.
// Two passes:
//
//   1. Mover_PlatformCarry  — players standing ON TOP ride the brush.
//                             If their swept path is partially
//                             blocked (e.g. wall in front), they
//                             stop at the wall and the brush slides
//                             past underneath; eventually the brush
//                             no longer covers their feet and they
//                             fall off the back.  Door does NOT
//                             pause for a stuck passenger — that's
//                             the desired "platform slid out from
//                             under me" behaviour.
//   2. Mover_GeometryBlockPush — players whose bbox actually
//                             intersects the brush BSP get slid one
//                             tick along velocity.  If wedged, the
//                             brush's .blocked callback fires
//                             (damage + reverse-or-grind per the
//                             door's spawnflags).
//
// Wedge-detected pause: when geometry push wedges, the door's
// velocity is zeroed for this tick UNLESS .blocked reversed the
// door's direction.  We detect reversal by sign-checking the
// velocity (.blocked → door_go_down/up → Mover_Start writes a new
// velocity in the opposite direction).  Result:
//
//   - Default door wedge → .blocked reverses → velocity flips →
//     no pause → door opens cleanly, one-shot dmg applied.
//   - UNBLOCKABLE wedge → .blocked just damages, velocity unchanged
//     → pause kicks in → door stops at the player's head, damage
//     per tick until the player dies or moves out.
//
// Engine MOVETYPE_PUSH skips MOVETYPE_NONE players so it doesn't
// fire .blocked itself; this QC path is the only way to detect
// the crush and apply damage.  Pause keeps the door visually
// stopped at the wedge instead of phasing through.
void() Mover_TravelTick =
{
    Mover_PlatformCarry();

    // Capture velocity before geometry push so we can detect
    // whether .blocked reversed the door (reverse → planned_velocity
    // changes → no pause needed) vs. no-reverse UNBLOCKABLE
    // (planned_velocity unchanged → pause needed).  Substitute
    // planned_velocity when self.velocity is 0 (paused last tick)
    // so a continued wedge still compares meaningfully.
    vector pre_velocity = self.velocity;
    if (pre_velocity == '0 0 0')
        pre_velocity = self.mover_planned_velocity;
    float wedged = Mover_GeometryBlockPush();

    // Floored at the server's real physics frame — see Mover_TickInterval in
    // sv_customdefs.qc.  A door scheduled faster than the server runs travels at
    // tick*fps of its authored speed, which on a slow server is a door that takes
    // twice as long to open as the map says.
    float tick_dt = Mover_TickInterval(40);

    if (wedged)
    {
        // Did .blocked reverse direction?  Reverse → planned_velocity
        // got rewritten by Mover_Start.  No-reverse (UNBLOCKABLE) →
        // planned_velocity unchanged; we pause velocity for this tick
        // so the engine doesn't keep advancing the door through the
        // wedged player while we damage them per tick.  This is the
        // user-requested "stop at my head and damage me" behaviour
        // for crusher doors.
        if (self.mover_planned_velocity == pre_velocity)
        {
            // First wedge tick after motion: backing off here is
            // now unnecessary since the geometry helper looks AHEAD
            // (the brush hasn't entered the player yet — we pause
            // before the next engine integration).  Keep velocity 0
            // so the engine doesn't advance into the player.
            if (self.velocity != '0 0 0')
            {
                self.velocity  = '0 0 0';
                self.SendFlags = 1;
            }
            if (self.avelocity != '0 0 0')
            {
                self.mover_paused_avelocity = self.avelocity;
                self.avelocity              = '0 0 0';
                self.SendFlags              = 1;
            }
            if (cvar("sv_debug_doors"))
                dprint(sprintf("[door %s] tick: PAUSE (wedge ahead, no reverse)\n",
                               self.targetname));
        }
        else
        {
            // Reverse fired — sync engine velocity to the new planned
            // direction so motion resumes immediately.
            if (self.velocity != self.mover_planned_velocity)
            {
                self.velocity  = self.mover_planned_velocity;
                self.SendFlags = 1;
            }
            if (cvar("sv_debug_doors"))
                dprint(sprintf("[door %s] tick: REVERSED, velocity now %v\n",
                               self.targetname, self.velocity));
        }
    }
    else
    {
        // Wedge cleared (player walked away, died, or was never
        // wedged).  Restore velocity from plan so a previously
        // paused door resumes closing.
        if (self.velocity != self.mover_planned_velocity)
        {
            self.velocity  = self.mover_planned_velocity;
            self.SendFlags = 1;
        }
        if (self.mover_paused_avelocity != '0 0 0')
        {
            self.avelocity              = self.mover_paused_avelocity;
            self.mover_paused_avelocity = '0 0 0';
            self.SendFlags              = 1;
        }
    }

    // Have we arrived?  Use the PLANNED speed for the per-tick distance
    // — current velocity is 0 while paused for a wedge and would
    // otherwise falsely register arrival.  Skip arrival while paused
    // so the door doesn't snap past a wedged player.
    float dist_remaining = vlen(self.mover_dest - self.origin);
    float per_tick = vlen(self.mover_planned_velocity) * tick_dt;
    if (!wedged && dist_remaining <= per_tick + 0.5)
    {
        // Arrival snap.  Mover_PlatformCarry already ran at the top of
        // this tick with platform_prev_origin = previous tick's origin,
        // so carried players got the engine-integrated delta but NOT
        // the snap delta about to be applied below.  Without the snap
        // fixup, players riding a door that lines up with an adjacent
        // floor end up ~0.5-2u above the floor — they "float", the
        // client-side pmove sees no ground in its 4u down-trace and
        // predicts a fall, server snaps them back via reconcile every
        // snapshot.  Capture the snap delta and apply it to every
        // currently-carried player so they land cleanly.
        vector pre_snap_origin = self.origin;
        setorigin(self, self.mover_dest);
        vector snap_delta = self.mover_dest - pre_snap_origin;
        if (snap_delta != '0 0 0')
        {
            entity p = find(world, classname, "player");
            while (p)
            {
                if (p.platform_carry == self)
                    setorigin(p, p.origin + snap_delta);
                p = find(p, classname, "player");
            }
        }
        self.velocity = '0 0 0';
        self.mover_paused_avelocity = '0 0 0';   // never resurrect a stale pause
        self.SendFlags = 1;
        // Drop out of the linear-motion list now that we're idle —
        // client predict pass should stop pushing players against
        // this brush.
        MovingBrush_RemoveFromList(self);
        void() cb = self.mover_done_cb;
        self.mover_done_cb = __NULL__;
        if (cb) cb();
        return;
    }

    // RE-SEND EVERY TICK WHILE WE ARE ACTUALLY MOVING.
    //
    // SV_InitReplicatedSolidBrush sets SendFlags once at spawn, the engine clears it
    // after the first send, and the branches above only dirty it on a state CHANGE -
    // so a mover on this tick used to ship exactly two snapshots for a whole trip:
    // one at Mover_Start and one on arrival.  The client's TRAIN branch caps its
    // extrapolation at 0.1 s (cl_brushsync.qc:282), so it advanced a tenth of a
    // second's worth, froze, and then teleported to the destination.  hl_c01_a1's
    // func_platrot travels 216 units in 2.7 s: about 8 units of visible motion out
    // of 216.
    //
    // This is the one mover tick in the tree that was missing it.  func_train
    // (sv_func_train.qc:262) carries the same line with a comment describing the
    // same report; so do func_tracktrain, func_door_rotating, func_rotating and
    // func_trackautochange.  The engine dedups sends down to the client's netrate,
    // so the cost is a snapshot per netframe, not per tick.
    if (self.velocity != '0 0 0' || self.avelocity != '0 0 0')
        self.SendFlags = 1;

    self.nextthink = self.ltime + tick_dt;
};

void(vector destination, float move_speed, void() move_done) Mover_Start =
{
    vector delta;
    float  distance;
    float  travel_time;

    delta    = destination - self.origin;
    distance = vlen(delta);

    // Fresh trip: any avelocity a previous wedge stashed belongs to the previous
    // trip's rotation and must not be handed back mid-way through this one.
    self.mover_paused_avelocity = '0 0 0';

    if (distance <= 0 || move_speed <= 0)
    {
        setorigin(self, destination);
        self.velocity              = '0 0 0';
        self.mover_planned_velocity = '0 0 0';
        self.SendFlags             = 1;
        move_done();
        return;
    }

    travel_time                = distance / move_speed;
    self.velocity              = delta * (1.0 / travel_time);
    self.mover_planned_velocity = self.velocity;   // remembered so Mover_TravelTick can pause/resume on blocking
    self.SendFlags             = 1;   // tell CSQC: new origin + velocity

    // Per-tick travel think replaces the previous one-shot move_done
    // at travel_time end.  Engine still integrates self.origin via
    // velocity each physics tick (MOVETYPE_PUSH); our think just
    // pushes players in the path and decides when we've arrived.
    self.mover_dest    = destination;
    self.mover_done_cb = move_done;
    self.think         = Mover_TravelTick;

    // Publish into the shared moving-brush list so PM_CheckMovingPushers
    // mirrors the server's push pass on the client during travel.
    // Mover_TravelTick removes the entry once we arrive.
    MovingBrush_AddToList(self);

    self.nextthink = self.ltime + Mover_TickInterval(40);
};

// ============================================================================
//  func_door  (sliding)
// ============================================================================

// ---------------------------------------------------------------------------
//  Door flags
// ---------------------------------------------------------------------------
// Everything below reads self.door_flags, NEVER self.spawnflags.  The raw bits
// mean different things depending on whether the BSP came from our own FGD or
// from Hammer, and Door_NormaliseFlags() is the single place that difference is
// resolved.  Reading .spawnflags directly anywhere else re-introduces the bug.
//
//   1    — START_OPEN: spawn pre-opened.  Auto-closes after `wait`
//           seconds unless TOGGLE/ONE_MOVEMENT pin it open.  Resets
//           to open at every round restart.  (Same bit in Half-Life.)
//   2    — RESERVED, DEAD.  Was USE_ABLE: a mod invention with no
//           Half-Life counterpart that gated direct +use.  nettest.fgd
//           defaulted it to ON, so every door we ever authored has it
//           set and every GoldSrc door lacks it — meaning the flag only
//           ever did anything on maps we did NOT author, where it
//           silently killed +use entirely.  Never reuse this bit: old
//           nettest BSPs still set it, so any new meaning would fire on
//           them retroactively.  Half-Life leaves bit 2 unused on
//           sliding doors, so leaving it inert is safe forever.
//   4    — DONT_LINK (Half-Life SF_DOOR_NO_LINK): do not group this door
//           with adjacent doors.  Honoured by Door_ShouldLink.
//   8    — PASS_THROUGH: door is non-solid (SOLID_NOT) — visible but
//           walk-through.  No proximity trigger spawned.  (HL: Passable.)
//   16   — ONE_MOVEMENT: door can activate exactly once per round.
//           Auto-return is suppressed.  Combined with `health`, this
//           gives the "shoot once to open, stays open" behaviour.
//           NOT a Half-Life flag — stripped on GoldSrc maps, where 16 is
//           Sven's "one-way" movement hint and would otherwise weld the
//           door open after a single press.
//   32   — TOGGLE: each press toggles state; no auto-close.
//           (HL SF_DOOR_NO_AUTO_RETURN.)
//   256  — USE_ONLY (Half-Life SF_DOOR_USE_ONLY): the door has no touch
//           field, i.e. walking into it does nothing.  +use and trigger
//           chains both still work.  NOTE this is the GoldSrc meaning;
//           the old mod meaning ("reject target-trigger fires") now
//           lives on DOOR_NO_TRIGGER below.
//   512  — Half-Life "Monsters can't".  Accepted and ignored; we have no
//           monsters.  Listed so nobody reuses the bit.
//   1024 — UNBLOCKABLE: when something blocks the close, the door does
//           NOT reverse — it keeps trying to close.  Combined with `dmg`
//           this becomes a continuous crusher.  Moved here off bit 4,
//           which Half-Life needs for DONT_LINK; native maps that set
//           bit 4 are aliased onto this by the normaliser so already
//           compiled BSPs keep working.
//   2048 — NO_TRIGGER: target-trigger activation is rejected; +use and
//           damage only.  This is the mod's original USE_ONLY semantic,
//           moved off 256 so 256 can carry the GoldSrc meaning.  Native
//           maps that set 256 are aliased onto this by the normaliser.
const float DOOR_START_OPEN     = 1;
const float DOOR_RESERVED_BIT2  = 2;      // dead — see above.  DO NOT REUSE.
const float DOOR_DONT_LINK      = 4;
const float DOOR_PASS_THROUGH   = 8;
const float DOOR_ONE_MOVEMENT   = 16;
const float DOOR_TOGGLE         = 32;
const float DOOR_USE_ONLY       = 256;
const float DOOR_NOMONSTERS     = 512;    // HL, accepted + ignored
const float DOOR_UNBLOCKABLE    = 1024;
const float DOOR_NO_TRIGGER     = 2048;

// Normalised flag word.  Written once by Door_NormaliseFlags() at spawn,
// read everywhere thereafter.  Shared by func_door and func_door_rotating.
.float door_flags;

// Sven Co-op's `breakable` key ("Breakable", 0/1) off the FGD's Door
// baseclass.  The real opt-in for shoot-to-open; `health` beside it is only
// the threshold ("Strength").  Read at spawn in func_door / func_door_rotating.
.float breakable;

// Translate mapper-authored .spawnflags into .door_flags.  MUST be the first
// statement of func_door / func_door_rotating, before any flag is read.
//
// Native maps keep their existing behaviour bit-for-bit: bits 4 and 256 are
// ALIASED onto their new homes rather than moved, so BSPs already compiled
// against the old FGD are unaffected.  Only GoldSrc maps get the Half-Life
// interpretation.
void() Door_NormaliseFlags =
{
    self.door_flags = self.spawnflags;

    if (!Map_IsGoldSrc())
    {
        // Authored against nettest.fgd.  Bit 4 has always meant "crusher"
        // here and bit 256 "reject trigger fires"; alias both forward and
        // clear bit 4 so it can't also read as DONT_LINK.
        if (self.spawnflags & 4)
            self.door_flags = self.door_flags | DOOR_UNBLOCKABLE;
        if (self.spawnflags & 256)
            self.door_flags = self.door_flags | DOOR_NO_TRIGGER;
        self.door_flags = self.door_flags & ~4;
    }
    else
    {
        // GoldSrc / Sven func_door.  Bit 4 stays DONT_LINK, bit 256 keeps
        // only the "no touch field" meaning (so trigger chains still reach
        // the door), and bit 16 is stripped because Hammer's func_door has
        // no such flag — Sven uses it as a movement hint and reading it as
        // ONE_MOVEMENT welds the door open after one press.
        self.door_flags = self.door_flags & ~DOOR_ONE_MOVEMENT;
    }

    if (cvar("sv_debug_doors") && self.door_flags != self.spawnflags)
        dprint(sprintf("[door %s] flags %g -> %g (%s map)\n",
                       self.classname, self.spawnflags, self.door_flags,
                       Map_IsGoldSrc() ? "goldsrc" : "native"));
};

float DOOR_STATE_BOTTOM = 0;
float DOOR_STATE_UP     = 1;
float DOOR_STATE_TOP    = 2;
float DOOR_STATE_DOWN   = 3;

// DOOR_TRIGGER_PAD_XY / DOOR_TRIGGER_PAD_Z (60 / 8) lived here and inflated the
// touch field into a halo around the door.  Half-Life installs DoorTouch on the
// door BRUSH (doors.cpp:323), so contact — not proximity — is the trigger.  The
// pads are what made walk-past opens and the every-frame reversal, and what got
// sv_door_proximity shipped at 0.  door_spawn_trigger now hugs absmin/absmax the
// way rotdoor_spawn_trigger always did.

float door_group_mark_serial;

// ONE_MOVEMENT latch — set when a door first activates this round,
// cleared by Door_RoundReset.  While set, door_use / door_use_force
// short-circuit so the door cannot re-activate until the next round.
.float door_movement_done;
// Block damage carried on the door entity itself — set from the
// mapper's "dmg" key.  Read by door_blocked.
.float dmg;

float(entity attacker, entity target, float damage) W_ApplyDamage;  // sv_weapons.qc
void() SV_InitReplicatedSolidBrush;                                // sv_brushsync.qc

void() door_go_up;
void() door_go_down;
void() door_use_force;

// sv_triggers.qc, which compiles AFTER this file.
void(entity caller, entity who, float useType) SUB_UseTargets;
float(float ts) GoldSrc_TriggerStateToUseType;

// ---------------------------------------------------------------------------
//  Sven's four end-of-travel chains  (sven-coop.fgd @BaseClass OpenClosable)
// ---------------------------------------------------------------------------
//      fireonopening  — the door STARTS opening
//      fireonopened   — it finishes opening      (alias: fireonopen)
//      fireonclosing  — it STARTS closing
//      fireonclosed   — it finishes closing      (alias: netname)
//
// The two aliases are vanilla Half-Life keys that Sven kept working, and the
// `netname` one is not decoration: th_ep1_01's bell rope is a func_door whose
// ONLY output is `netname "bellring_mngr"`, so with this unimplemented the bell
// could be pulled and never rang.  CBaseDoor fires it from DoorHitBottom
// (doors.cpp:699-701) — this file had no equivalent for func_door at all, though
// func_plat already had one in sv_goldsrc_compat.qc.
//
// `fireonopen` is declared HERE rather than beside its plat reader because this
// file compiles at sv_progs.src:185 and sv_goldsrc_compat.qc at :389; a field can
// only be declared once, and the earlier declaration is the one both can see.
.string fireonopen;
.string fireonopening;
.string fireonclosing;
.string fireonopened;
.string fireonclosed;

// Read as STRINGS, deliberately.  Every *_triggerstate in the FGD defaults to
// 2 (Toggle), and a QC .float left at 0 cannot be told from a map's explicit
// "0" (= Off) — which would silently turn every unset key into an Off.
.string fireonopening_triggerstate;
.string fireonclosing_triggerstate;
.string fireonopened_triggerstate;
.string fireonclosed_triggerstate;

void(string targ, string statestr) Door_FireChain =
{
    if (targ == "" || targ == __NULL__)
        return;

    float state = (statestr == "" || statestr == __NULL__) ? 2 : stof(statestr);

    // Throwaway relay, the same shape Plat_FireChain uses: SUB_UseTargets walks
    // the CALLER's .target, and the door's own .target is a different chain we
    // must not disturb.
    entity relay = spawn();
    relay.classname = "door_fire";
    relay.target    = targ;
    SUB_UseTargets(relay, self, GoldSrc_TriggerStateToUseType(state));
    remove(relay);
};

string() Door_ClosedTarget =
{
    if (self.fireonclosed && self.fireonclosed != "")
        return self.fireonclosed;
    return self.netname;
};

string() Door_OpenedTarget =
{
    if (self.fireonopened && self.fireonopened != "")
        return self.fireonopened;
    return self.fireonopen;
};

// Which end is "closed"?  Half-Life fires the close chain at DoorHitTop when
// SF_DOOR_START_OPEN is set and at DoorHitBottom when it is not:
//     // Fire the close target (if startopen is set, then "top" is closed)
//     if ( pev->netname && (pev->spawnflags & SF_DOOR_START_OPEN) )   // HitTop
//     if ( pev->netname && !(pev->spawnflags & SF_DOOR_START_OPEN) )  // HitBottom
//                                              (doors.cpp:644-646, :699-701)
// This tree swaps pos1/pos2 at spawn for START_OPEN (see func_door), so top and
// bottom already mean what HL means by them and the test transcribes directly.
void(float attop) Door_FireArrival =
{
    float closed = (self.door_flags & DOOR_START_OPEN) ? attop : !attop;
    if (closed)
        Door_FireChain(Door_ClosedTarget(), self.fireonclosed_triggerstate);
    else
        Door_FireChain(Door_OpenedTarget(), self.fireonopened_triggerstate);
};

// The two START-of-travel chains.  Sven-only (vanilla HL has no equivalent), so
// there is no alias key to fall back on.
void(float totop) Door_FireDeparture =
{
    float closing = (self.door_flags & DOOR_START_OPEN) ? totop : !totop;
    if (closing)
        Door_FireChain(self.fireonclosing, self.fireonclosing_triggerstate);
    else
        Door_FireChain(self.fireonopening, self.fireonopening_triggerstate);
};

void() door_hit_bottom =
{
    setorigin(self, self.pos1);
    self.velocity    = '0 0 0';
    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;
    self.SendFlags   = 1;
    Door_PlayStopSound();
    Door_FireArrival(FALSE);
};

void() door_go_down =
{
    if (self.door_state == DOOR_STATE_BOTTOM || self.door_state == DOOR_STATE_DOWN)
        return;
    self.door_state  = DOOR_STATE_DOWN;
    self.mover_state = MOVER_STATE_DOWN;
    Door_PlayMoveSound();
    Door_FireDeparture(FALSE);
    Mover_Start(self.pos1, self.speed, door_hit_bottom);
};

void() door_hit_top =
{
    setorigin(self, self.pos2);
    self.velocity    = '0 0 0';
    self.door_state  = DOOR_STATE_TOP;
    self.mover_state = MOVER_STATE_TOP;
    self.SendFlags   = 1;
    Door_PlayStopSound();
    Door_FireArrival(TRUE);
    // TOGGLE / ONE_MOVEMENT / wait<0 all suppress the auto-return.
    // ONE_MOVEMENT is the "stays open this round" semantic — even
    // damage-driven opens latch into this state until Door_RoundReset
    // clears the door_movement_done flag.
    if ((self.door_flags & DOOR_TOGGLE) || self.wait < 0)
        return;
    if (self.door_flags & DOOR_ONE_MOVEMENT)
        return;
    self.nextthink = self.ltime + self.wait;
    self.think     = door_go_down;
};

void() door_go_up =
{
    if (self.door_state == DOOR_STATE_TOP)
    {
        if (!(self.door_flags & DOOR_TOGGLE) && self.wait >= 0)
        {
            self.nextthink = self.ltime + self.wait;
            self.think     = door_go_down;
        }
        return;
    }
    if (self.door_state == DOOR_STATE_UP)
        return;
    self.door_state  = DOOR_STATE_UP;
    self.mover_state = MOVER_STATE_UP;
    Door_PlayMoveSound();
    Door_FireDeparture(TRUE);
    Mover_Start(self.pos2, self.speed, door_hit_top);
};

void() door_blocked =
{
    // Player blocker: try a slide-along-movedir push BEFORE the
    // `dmg` + reverse path runs.  Engine has already reverted door
    // origin for this tick (sv_phys.c:1068).  If we successfully
    // push the player out of the door's path, the door integrates
    // cleanly next tick — feels like the door "shoves" the player
    // along its motion instead of just reversing or grinding them.
    // If the push fails (player wedged against a wall), fall through
    // Apply block damage to the obstruction if `dmg` is set.
    //
    // Earlier versions tried a "movedir slide" first — teleport the
    // player along self.movedir (the door's OPEN direction) to nudge
    // them out of the closing brush's path before applying dmg.  In
    // practice this teleported the player INTO the descending door:
    // movedir for an up-opening door is UP, the player is BELOW the
    // closing brush, slide_dist = UP*9 pushes them upward through
    // the door's volume.  Each "successful" slide moved the player
    // deeper inside the bbox until they couldn't move any further;
    // by then the look-ahead probe found the player inside the
    // brush regardless of which direction the door was travelling,
    // and the reverse-on-block path entered an infinite oscillation
    // (close → wedge → reverse → wedge → reverse → ...).  The
    // look-ahead helper in sv_platform_carry.qc already prevents
    // the door from entering the player's bbox in the first place,
    // so the slide is both unnecessary and harmful — gone now.  No
    // takedamage gate — W_CanDamageTarget unconditionally accepts
    // targets with classname=="player" regardless of their
    // .takedamage field (which players have at 0 / DAMAGE_NO in
    // this mod because we never call SetTakedamage on them).
    // Skipping the W_ApplyDamage call on the takedamage check would
    // turn this into a no-op for every player block — i.e. the
    // "door crushes me but I don't take damage" bug.
    if (self.dmg > 0 && other != world)
    {
        if (cvar("sv_debug_doors"))
            dprint(sprintf("[door %s] blocked: applying %g dmg to %s\n",
                           self.targetname, self.dmg, other.netname));
        W_ApplyDamage(self, other, self.dmg);
    }

    // UNBLOCKABLE: don't reverse — engine keeps attempting the close
    // and the dmg above keeps killing whatever's stuck.
    if (self.door_flags & DOOR_UNBLOCKABLE)
    {
        if (cvar("sv_debug_doors"))
            dprint(sprintf("[door %s] blocked: UNBLOCKABLE, no reverse\n",
                           self.targetname));
        return;
    }

    // Default: reverse direction so the blocker can free themselves
    // and the close fails gracefully.
    if (cvar("sv_debug_doors"))
        dprint(sprintf("[door %s] blocked: reversing\n", self.targetname));
    if (self.door_state == DOOR_STATE_UP || self.door_state == DOOR_STATE_TOP)
        door_go_down();
    else
        door_go_up();
};

// ---- door group activation ----

// Adjacency / groupname-based linking.  The DONT_LINK opt-out (bit 4) is
// honoured again now that UNBLOCKABLE has moved to bit 1024 and stopped
// squatting on it — see Door_NormaliseFlags.  This matters on GoldSrc maps:
// linking there is driven purely by swept-AABB adjacency when no `groupname`
// is set, and a Hammer map with dozens of neighbouring doors relies on
// SF_DOOR_NO_LINK to keep them independent.  Without it, one press opens the
// whole cluster.
float(entity d1, entity d2) Door_ShouldLink =
{
    if (d1 == d2)                                              return FALSE;
    if (d1.door_flags & DOOR_DONT_LINK)                        return FALSE;
    if (d2.door_flags & DOOR_DONT_LINK)                        return FALSE;
    if (d1.groupname && d1.groupname[0])
        return (d2.groupname == d1.groupname);
    if (d2.groupname && d2.groupname[0])                       return FALSE;
    if (d1.cmins_x > d2.cmaxs_x || d1.cmaxs_x < d2.cmins_x) return FALSE;
    if (d1.cmins_y > d2.cmaxs_y || d1.cmaxs_y < d2.cmins_y) return FALSE;
    if (d1.cmins_z > d2.cmaxs_z || d1.cmaxs_z < d2.cmins_z) return FALSE;
    return TRUE;
};

void(entity door) Door_ActivateSingle =
{
    entity oldself;
    door.attack_finished = time + 0.1;
    oldself = self;
    if ((door.door_flags & DOOR_TOGGLE) && (door.door_state == DOOR_STATE_UP || door.door_state == DOOR_STATE_TOP))
    {
        self = door; door_go_down(); self = oldself;
        return;
    }
    self = door; door_go_up(); self = oldself;
};

void(entity seed) Door_OpenGroup =
{
    entity nextdoor;
    if (seed.door_mark == door_group_mark_serial)
        return;
    seed.door_mark = door_group_mark_serial;
    Door_ActivateSingle(seed);
    nextdoor = find(world, classname, "func_door");
    while (nextdoor)
    {
        if (nextdoor.door_mark != door_group_mark_serial && Door_ShouldLink(seed, nextdoor))
            Door_OpenGroup(nextdoor);
        nextdoor = find(nextdoor, classname, "func_door");
    }
};

void() door_use =
{
    // mp_disabledoors live admin gate (also applies to door_use_force).
    if (cvar("mp_disabledoors")) return;

    // `master` gate.  Deliberately BEFORE the attack_finished debounce below,
    // so a rejected press doesn't burn the 0.1s cooldown and the player can
    // retry the moment the master unlocks.
    if (Door_MasterBlocks()) return;

    // Sven's InventoryRules — "Prevent door being used".  Sits beside the
    // master gate for the same reason it does: a door refused for want of the
    // right item must still be openable the moment you come back holding it,
    // so this must not burn the debounce either.  func_water is a clone of
    // func_door and reaches this same function, which is why Sven lists it
    // separately in the same breath.
    if (!Inv_Gate(self, activator)) return;

    // Direct +use gate.  Half-Life's CBaseDoor::ObjectCaps grants
    // FCAP_IMPULSE_USE ONLY when SF_DOOR_USE_ONLY (256) is set; without it a
    // door is not in the player's use-trace at all and can only be opened by
    // touch or by a trigger.  hl_c01_a1's scripted entry doors are spawnflags
    // 544 (512|32) — no 256 — so a player could +use them and skip the
    // cutscene.
    //
    // This deliberately does NOT reinstate the old mod-invented USE_ABLE bit
    // (spawnflags & 2), which was wrong: no GoldSrc door sets it, so it made
    // every GoldSrc door dead to +use.  The gate is keyed on the REAL HL bit
    // and applies only to GoldSrc maps — see door_player_usable, computed at
    // spawn.  Native nettest maps keep today's permissive behaviour, which
    // matters: testing.bsp has a spawnflags-1 +use door and dualshitfire.bsp
    // has untargeted ones.
    if (sv_use_is_player_direct && !self.door_player_usable
        && cvar("sv_door_use_only"))
    {
        Door_PlayLockedSound();
        return;
    }

    // NO_TRIGGER rejects target-trigger fires.  When set, the door can
    // only be opened by direct +use (or damage) — intentionally isolated
    // from external trigger chains.  This is the mod's original bit-256
    // semantic; on GoldSrc maps 256 means "no touch field" instead and
    // the normaliser never sets NO_TRIGGER, so Hammer-authored button and
    // multi_manager chains reach the door as Half-Life intends.
    if (!sv_use_is_player_direct && (self.door_flags & DOOR_NO_TRIGGER))
        return;

    // ONE_MOVEMENT latch — already activated this round.
    if (self.door_movement_done)
        return;

    if (self.attack_finished > time)
        return;
    self.attack_finished = time + 0.1;

    // Mark the latch BEFORE the group walk so linked doors don't
    // each re-mark their own (and so a re-press during the open
    // animation doesn't slip past).
    if (self.door_flags & DOOR_ONE_MOVEMENT)
        self.door_movement_done = 1;

    Trigger_UseTargets(self, activator);
    door_group_mark_serial = door_group_mark_serial + 1;
    if (door_group_mark_serial <= 0) door_group_mark_serial = 1;
    Door_OpenGroup(self);
};

// Damage-driven open path.  Called by door_killed (on_killed callback
// when self.health drops to zero from gunfire).  Bypasses NO_TRIGGER and
// the `master` gate because damage is a separate activation channel — a
// door wired shut against both players and trigger chains can still be
// shot open if the mapper gave it health.  (6 doors on the reference Sven
// map set health for exactly this.)  ONE_MOVEMENT and mp_disabledoors
// still apply.
void() door_use_force =
{
    if (cvar("mp_disabledoors")) return;
    if (self.door_movement_done) return;
    if (self.attack_finished > time) return;
    self.attack_finished = time + 0.1;

    if (self.door_flags & DOOR_ONE_MOVEMENT)
        self.door_movement_done = 1;

    Trigger_UseTargets(self, activator);
    door_group_mark_serial = door_group_mark_serial + 1;
    if (door_group_mark_serial <= 0) door_group_mark_serial = 1;
    Door_OpenGroup(self);
};

// on_killed callback — the door's `health` reached zero from
// gunfire.  Re-arms the door for next-round use unless
// ONE_MOVEMENT pinned it open this round.
void() door_killed =
{
    activator = self.dmg_inflictor;     // shooter for kill credit / target chain

    if (self.door_flags & DOOR_ONE_MOVEMENT)
    {
        // Stop accepting damage — extra shots after the open are
        // wasted, and leaving takedamage on would let the kill
        // fire repeatedly during the same frame.
        self.takedamage = DAMAGE_NO;
    }
    else
    {
        // Re-arm so the door can be shot open again on its next
        // close cycle.
        self.health = self.max_health;
    }

    door_use_force();
};

// Port of CBaseDoor::DoorTouch (doors.cpp:485-513).  The ladder is HL's, in HL's
// order, with two additions marked below.
void() door_trigger_touch =
{
    entity oldself, oldactivator;
    float  oldtouch;
    entity door = self.owner;

    // doors.cpp:489-491 — "Ignore touches by anything but players".
    if (other.classname != "player")
        return;

    // HL's SetTouch(NULL)-while-moving, expressed as a state test.  DoorTouch
    // nulls its own touch on a successful activate (doors.cpp:511-512) and only
    // DoorHitBottom / DoorHitTop put it back (:690-695, :626-631).  Our trigger
    // is a separate persistent entity and cannot un-install itself the same way,
    // so gate on the door being at its resting pose instead.  This is what closes
    // the every-frame reversal: Door_ActivateSingle flips a TOGGLE door to
    // door_go_down whenever it is at UP/TOP, so without this a player standing in
    // contact re-fires it every 0.1 s (door_use's attack_finished debounce) and
    // the door oscillates.  START_OPEN doors swap pos1/pos2 at spawn, so BOTTOM
    // is still "at rest" for them.
    if (door.door_state != DOOR_STATE_BOTTOM)
        return;

    // NOT from Half-Life.  Same shoulder-push test rotdoor_touch uses: brushing
    // past should not open the door, only walking into it.  Ranked on the AABB
    // MIDPOINT, not .origin — a GoldSrc brush entity compiled without an ORIGIN
    // brush keeps .origin == '0 0 0', which is the normal case for a sliding
    // func_door and would put the "toward the door" vector at the map origin.
    // rotdoor_touch can use .origin because a rotating door's ORIGIN brush is
    // mandatory and baked in.
    vector to_door = ((door.absmin + door.absmax) * 0.5) - other.origin;
    if (vlen(to_door) < 0.01)
        return;                         // standing inside it
    to_door = normalize(to_door);
    if ((other.velocity * to_door) < 50)
        return;

    // doors.cpp:502-507 — "If door is somebody's target, then touching does
    // nothing.  You have to activate the owner (e.g. button)": play the locked
    // sound and return.  .door_player_usable already encodes exactly this ladder
    // and inside a touch handler it reduces to "native map OR unnamed", because
    // USE_ONLY doors never get a trigger in the first place.  Reusing it keeps
    // the two paths from drifting, and keeps the sv_door_use_only escape hatch
    // working the same way door_use does.  349 of the 578 door-family entities in
    // the th_* corpus are named without 256 — this arm is the majority case.
    if (!door.door_player_usable && cvar("sv_door_use_only"))
    {
        oldself = self;
        self = door;
        Door_PlayLockedSound();
        self = oldself;
        return;
    }

    // No flag test for USE_ONLY / PASS_THROUGH here: the trigger is only ever
    // spawned for doors that may be touch-opened (func_door screens on both).
    // door_use applies NO_TRIGGER itself — this path reaches it with
    // sv_use_is_player_direct FALSE, so a NO_TRIGGER door (native maps' aliased
    // bit 256) still rejects it there, as it should.
    oldself = self; oldactivator = activator; oldtouch = sv_use_is_player_touch;
    activator = other;                  // doors.cpp:509, m_hActivator
    sv_use_is_player_touch = TRUE;      // lets Door_MasterBlocks click
    self = door;
    door_use();
    self = oldself; activator = oldactivator; sv_use_is_player_touch = oldtouch;
};

void() door_spawn_trigger =
{
    // Half-Life installs CBaseDoor::DoorTouch on the door brush itself
    // (doors.cpp:323), so the player has to physically make contact.  Hug
    // absmin/absmax — the brush's real world bounds — rather than the swept
    // cmins/cmaxs, which span the door's whole travel and would fire from
    // wherever the door is GOING to be.  The 2 qu inflation is the same one
    // rotdoor_spawn_trigger and SV_CheckTouchTriggers' func_button arm need: a
    // solid brush stops the player just OUTSIDE its bbox, and the engine only
    // spreads submodel bounds by 1 unit, so a strict overlap test would barely
    // ever fire.
    entity trigger;
    vector center, mins, maxs;
    center  = (self.absmin + self.absmax) * 0.5;
    mins    = self.absmin - center - '2 2 2';
    maxs    = self.absmax - center + '2 2 2';
    trigger = spawn();
    setorigin(trigger, center);
    setsize(trigger, mins, maxs);
    trigger.movetype = MOVETYPE_NONE;
    trigger.solid    = SOLID_TRIGGER;
    trigger.owner    = self;
    trigger.touch    = door_trigger_touch;
};

/*QUAKED func_door (0 .5 .8) ? START_OPEN x DONT_LINK PASS_THROUGH ONE_MOVEMENT TOGGLE x x USE_ONLY x NOMONSTERS UNBLOCKABLE NO_TRIGGER
Moving brush door.  Every door +use-able unless NO_TRIGGER / a master says
otherwise; there is no "use-able" flag (see the flag notes above the
DOOR_* constants for why bit 2 is permanently dead).

START_OPEN (1):    spawns pre-opened, auto-closes after `wait`.
DONT_LINK (4):     do not group with adjacent doors (HL SF_DOOR_NO_LINK).
PASS_THROUGH (8):  brush is non-solid; players walk through it.
ONE_MOVEMENT (16): one activation per round; with `health` lets you
                    shoot it open and have it stay open.
TOGGLE (32):       each press flips state; no auto-close.
USE_ONLY (256):    no touch field — walking into the door does nothing.
                    +use and trigger chains still work (GoldSrc meaning).
NOMONSTERS (512):  Half-Life flag, accepted and ignored.
UNBLOCKABLE (1024):blocked closes do NOT reverse — combined with
                    `dmg`, becomes a continuous crusher.
NO_TRIGGER (2048): target-trigger activation rejected; +use / damage
                    only.

"angle"      opening direction
"target"     entities to fire when opened
"targetname" if set, no auto trigger is spawned; activate via use/target/damage
"speed"      movement speed (default 100)
"wait"       seconds before closing (default 3, -1 = stay open)
"lip"        remaining lip at end of move (default 8)
"distance"   explicit move distance (overrides lip calc)
"groupname"  link doors with the same name into one group
"sounds"     0=silent 1=stone 2=base 3=chain 4=metal
"dmg"        block damage (0 = no crush damage)
"health"     shootable threshold; door opens when health hits 0
*/
void() func_door =
{
    vector swap_pos;

    // MUST be first — every flag read below goes through .door_flags.
    Door_NormaliseFlags();

    if (self.sounds == 1)
    {
        if (!self.noise1) self.noise1 = "doors/drclos4.wav";
        if (!self.noise2) self.noise2 = "doors/doormv1.wav";
    }
    else if (self.sounds == 2)
    {
        if (!self.noise1) self.noise1 = "doors/hydro2.wav";
        if (!self.noise2) self.noise2 = "doors/hydro1.wav";
    }
    else if (self.sounds == 3)
    {
        if (!self.noise1) self.noise1 = "doors/stndr2.wav";
        if (!self.noise2) self.noise2 = "doors/stndr1.wav";
    }
    else if (self.sounds == 4)
    {
        if (!self.noise1) self.noise1 = "doors/ddoor2.wav";
        if (!self.noise2) self.noise2 = "doors/ddoor1.wav";
    }

    // GoldSrc movesnd / stopsnd / locked_sound / unlocked_sound
    // override the legacy `sounds` preset pair when set.  These map
    // through the Door_Lookup* tables to specific WAVs and are
    // precached unconditionally — common/null.wav is the silence
    // sentinel for index 0 / unknown values.
    if (self.movesnd > 0)        self.noise2        = Door_LookupMoveSound(self.movesnd);
    if (self.stopsnd > 0)        self.noise1        = Door_LookupStopSound(self.stopsnd);
    if (self.locked_sound > 0)   self.noise_locked  = Door_LookupLockedSound(self.locked_sound);
    if (self.unlocked_sound > 0) self.noise_unlocked = Door_LookupUnlockedSound(self.unlocked_sound);

    Door_PrecacheIfReal(self.noise1);
    Door_PrecacheIfReal(self.noise2);
    Door_PrecacheIfReal(self.noise_locked);
    Door_PrecacheIfReal(self.noise_unlocked);
    // Unconditional — Door_PlayLockedSound falls back to this whenever the
    // mapper left locked_sound unset, so it must be precached even for doors
    // that specify their own.
    precache_sound(DOOR_DEFAULT_LOCKED_SND);

    // Cached for sv_brushsync.qc's predict_block byte: a mastered door's
    // lock state is dynamic and never networked, so CSQC must not predict it.
    self.door_has_master = (self.master && self.master != "");

    // Can a player's direct +use open this door?  Read by door_use, by
    // SV_UseTarget (so a refusal doesn't swallow the press) and by the
    // predict_block byte (so CSQC doesn't animate an open we will refuse).
    //
    // Half-Life grants FCAP_IMPULSE_USE only with SF_DOOR_USE_ONLY (256).  A
    // door WITHOUT that flag is opened one of two other ways:
    //   named    -> by a trigger chain; CBaseDoor::DoorTouch explicitly bails
    //               with the locked sound, so the player cannot open it at all.
    //   unnamed  -> by walking into it (DoorTouch activates).
    //
    // The `!targetname` term is that second case.  We answer it with +use AND,
    // now, with touch: the two bugs that made touch unusable are fixed rather
    // than avoided — door_spawn_trigger hugs the brush instead of building a
    // 60-unit halo out of the SWEPT bounds, and door_trigger_touch requires
    // motion into the door and refuses while the door is off its resting pose
    // (which is what used to flip TOGGLE doors back and forth every frame).
    // sv_door_proximity now ships at 1.  +use remains as the gentler superset —
    // every door HL would open on contact still opens on a keypress too — and no
    // map can be broken by a door being MORE openable than Half-Life made it.
    // Without the term, 520 doors across the Sven corpus (507 of them GoldSrc)
    // had no activation path left at all.
    //
    // Leave this computation itself alone: it feeds sv_brushsync.qc's
    // predict_block byte, which is a +use-PREDICTION gate.  Setting it to 1 for
    // newly-touchable doors would make CSQC predict a +use the server refuses.
    //
    // Named-and-untriggered doors stay refused, which is HL-correct: 332 Sven
    // doors are named with nothing referencing them and are dead in HL too.
    // Verified against the two maps this could regress: testing.bsp is native
    // so the first term carries it, and all 11 of dualshitfire.bsp's doors are
    // named AND driven (multi_manager `strike_mm` / `strike_timer_mma` slots,
    // or a func_button) except `secret_bussy`, which its author flagged 256 by
    // hand.
    // Three statements rather than one ||-chain.  `logicops` is off mod-wide,
    // and a three-term || here silently produced 0 even with every operand
    // parenthesised and the third one measurably true — verified on
    // th_ep1_01's cellar door, which reported targetname=="" as 1 and
    // door_player_usable as 0 from the same frame.  Don't chain || on a value
    // anything depends on.
    self.door_player_usable = 0;
    if (!Map_IsGoldSrc())                     self.door_player_usable = 1;
    if (self.door_flags & DOOR_USE_ONLY)      self.door_player_usable = 1;
    if (self.targetname == "")                self.door_player_usable = 1;

    if (!self.speed) self.speed = 100;
    if (!self.wait)  self.wait  = 3;
    // lip defaults to 0 (door opens its full width).  The earlier
    // default of 8 was inherited from old Q1 func_door but felt
    // wrong on small doorways — the door would visibly hang into
    // the frame after opening.  Mappers who want a partial-open
    // can still set lip explicitly.
    // dmg defaults to 2 per blocked tick (HL CBaseDoor parity).
    // Without this, doors with UNBLOCKABLE never killed the
    // wedged player and they got stuck inside the brush forever.
    // Default-doors mostly never apply damage anyway because
    // door_blocked reverses on first block (one-shot 2 dmg nudge
    // before the open phase starts).
    if (!self.dmg)   self.dmg   = 2;

    SV_InitReplicatedSolidBrush();
    self.brush_type  = BRUSH_TYPE_DOOR;
    self.blocked = door_blocked;
    self.use     = door_use;
    self.pos1    = self.origin;

    // PASS_THROUGH: visible-but-walkable.  SOLID_NOT skips the engine's
    // collision tests entirely (including bullets); mappers wanting a
    // pass-through-to-players-but-bullet-stop should add a separate
    // clip brush.  We still keep MOVETYPE_PUSH so the door animates.
    if (self.door_flags & DOOR_PASS_THROUGH)
        self.solid = SOLID_NOT;

    // Shootable doors — `health` lets gunfire trigger an open via the
    // standard on_killed callback, the same path func_breakable uses.
    // door_killed re-arms (or latches, with ONE_MOVEMENT) appropriately.
    //
    // GoldSrc maps need an EXPLICIT opt-in, because `health` does not mean
    // "shoot open" there.  sven-coop.fgd's Door baseclass spells it out:
    //     health(integer)    : "Strength"  : 0
    //     breakable(choices) : "Breakable" : 0     [0: "No"  1: "Yes"]
    // i.e. health is only the damage threshold, and `breakable 1` is what
    // actually arms it.  Measured across the corpus: 458 GoldSrc doors carry
    // health > 0 with breakable unset, against 28 that opt in — so treating
    // health alone as the trigger made 458 doors shootable that are not.
    // hl_c01_a1 is full of them (lk2, rr1, stall1, edoor_* all sit at
    // health 1), which is why its doors were flying open to gunfire in a
    // chapter that hands the player no weapon at all.
    //
    // Native maps keep health-alone, which is what this mod's own FGD
    // documents ("health: shootable threshold") and what the QUAKED block
    // below says.  Costs nothing to keep: no door in any of the 29 maps in
    // quakers/maps sets health at all.
    if (self.health && (!Map_IsGoldSrc() || self.breakable))
    {
        self.max_health  = self.health;
        self.takedamage  = DAMAGE_YES;
        self.on_killed   = door_killed;
    }

    if (self.movedir != '0 0 0')
    {
        self.pos2   = self.pos1 + self.movedir;
        self.angles = '0 0 0';
    }
    else if (self.mangle != '0 0 0')
    {
        if (!self.distance) self.distance = 64;
        makevectors(self.mangle);
        self.movedir = v_forward;
        self.pos2    = self.pos1 + self.movedir * self.distance;
        // Third site of the same "a leftover .angles on a SOLID_BSP brush relocates
        // it about the world origin" trap — the branch above already carries this
        // line and the SetMovedir path zeroes it too, so this one was the odd one
        // out.  `mangle` is Quake-1-only, so no GoldSrc map reaches here today; it
        // is fixed because the next person to read these three branches should not
        // have to work out why two of them zero angles and one does not.
        self.angles = '0 0 0';
    }
    else
    {
        // No Q1 "auto-default to UP if angles are zero" here — that
        // legacy fallback silently rewrote angles 0 0 0 to 0 -1 0
        // (Quake's "up" sentinel) which broke HL-style horizontal
        // doors that explicitly use angles 0 0 0 to mean +X movement.
        // Mappers wanting a vertical door must set angles '0 -1 0'
        // (up) or '0 -2 0' (down) explicitly — same convention HL,
        // CS and the rest of the codebase already use.  SetMovedir
        // honours those special vectors and otherwise calls
        // makevectors(angles) → v_forward, so:
        //   angles '0 0 0'   → +X
        //   angles '0 90 0'  → +Y
        //   angles '0 180 0' → -X
        //   angles '0 270 0' → -Y
        //   angles '0 -1 0'  → +Z (up)
        //   angles '0 -2 0'  → -Z (down)
        SetMovedir();
        if (self.distance)
            self.pos2 = self.pos1 + self.movedir * self.distance;
        else
        {
            // The -2 is GoldSrc's, and it is not a fudge:
            //
            //   // Subtract 2 from size because the engine expands bboxes by 1 in
            //   // all directions
            //                                     (doors.cpp, CBaseDoor::Spawn)
            //
            // That expansion is Mod_LoadSubmodels' "spread the mins / maxs by a
            // pixel", which FTE inherits verbatim (gl_model.c:4513, :4551), so
            // .size arrives padded here by exactly the 2 the reference game
            // takes back off.  Without it every lip-derived door in the corpus
            // opened two units past where its mapper placed it.
            vector sz = self.size - '2 2 2';
            self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * sz) - self.lip);
        }
    }

    // .angles was the movement direction and has just been zeroed; the entity was
    // linked with the OLD value back in SV_InitReplicatedSolidBrush.  Re-link, or
    // the door keeps a PVS box rotated about (0,0,0) and stays invisible to clients
    // until its first move.  See BrushSync_RelinkAngles in sv_brushsync.qc.
    BrushSync_RelinkAngles();

    if (self.door_flags & DOOR_START_OPEN)
    {
        setorigin(self, self.pos2);
        swap_pos  = self.pos1;
        self.pos1 = self.pos2;
        self.pos2 = swap_pos;

        // Auto-close behaviour at map load — same logic
        // Door_RoundReset uses on subsequent rounds.  TOGGLE pins the
        // door open until pressed; ONE_MOVEMENT pins it for the
        // round; wait<0 is the legacy "stay open" sentinel.
        if (self.wait >= 0
            && !(self.door_flags & DOOR_TOGGLE)
            && !(self.door_flags & DOOR_ONE_MOVEMENT))
        {
            self.nextthink = self.ltime + self.wait;
            self.think     = door_go_up;        // close direction (post-swap)
        }
    }

    // combined bounds for proximity trigger and group-linking
    self.cmins = self.pos1 + self.mins;
    self.cmaxs = self.pos1 + self.maxs;
    if (self.pos2_x + self.mins_x < self.cmins_x) self.cmins_x = self.pos2_x + self.mins_x;
    if (self.pos2_y + self.mins_y < self.cmins_y) self.cmins_y = self.pos2_y + self.mins_y;
    if (self.pos2_z + self.mins_z < self.cmins_z) self.cmins_z = self.pos2_z + self.mins_z;
    if (self.pos2_x + self.maxs_x > self.cmaxs_x) self.cmaxs_x = self.pos2_x + self.maxs_x;
    if (self.pos2_y + self.maxs_y > self.cmaxs_y) self.cmaxs_y = self.pos2_y + self.maxs_y;
    if (self.pos2_z + self.maxs_z > self.cmaxs_z) self.cmaxs_z = self.pos2_z + self.maxs_z;

    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;

    // Auto-spawn the touch field.  Half-Life's condition is ONLY the 256 bit:
    //     if (SF_DOOR_USE_ONLY) SetTouch(NULL); else SetTouch(DoorTouch);
    //                                     (doors.cpp:317-323)
    // — the flag's whole meaning in GoldSrc is "this door has no touch field".
    // It used to be the mod-invented USE_ABLE bit here instead, which is dead.
    //
    // The `!self.targetname` term used to be here too and is NOT Half-Life's: a
    // named door keeps its touch field precisely so DoorTouch can answer a
    // shoulder with the locked click (doors.cpp:502-507).  door_trigger_touch now
    // makes that answer, so the term is gone.
    //
    // PASS_THROUGH is kept: a SOLID_NOT brush cannot be walked into, and
    // func_water forces that bit (sv_water.qc), so all 53 corpus pools stay out of
    // this.  Do NOT "simplify" that term away — it is the only thing keeping them
    // out now that the targetname term has gone.
    if (cvar("sv_door_proximity")
        && !(self.door_flags & DOOR_USE_ONLY)
        && !(self.door_flags & DOOR_PASS_THROUGH))
        door_spawn_trigger();
};

// Round restart — restore every door to its initial pose, re-arm
// shootable doors, and re-schedule the START_OPEN auto-close.
// Called from RoundRestart in sv_main.qc.
void() Door_RoundReset =
{
    entity d = find(world, classname, "func_door");
    while (d)
    {
        d.door_movement_done = 0;
        d.attack_finished    = 0;
        d.velocity           = '0 0 0';
        d.think              = __NULL__;
        d.nextthink          = 0;

        // Snap to pos1 — for non-START_OPEN doors that's the closed
        // position; for START_OPEN doors pos1/pos2 were swapped at
        // spawn so pos1 is the OPEN position.  Either way, "BOTTOM"
        // is the door's initial state.
        setorigin(d, d.pos1);
        d.door_state  = DOOR_STATE_BOTTOM;
        d.mover_state = MOVER_STATE_BOTTOM;
        d.SendFlags   = 1;

        if (d.max_health)
        {
            d.health     = d.max_health;
            d.takedamage = DAMAGE_YES;
        }

        // Re-arm the START_OPEN auto-close timer for this round.
        if ((d.door_flags & DOOR_START_OPEN)
            && d.wait >= 0
            && !(d.door_flags & DOOR_TOGGLE)
            && !(d.door_flags & DOOR_ONE_MOVEMENT))
        {
            d.nextthink = d.ltime + d.wait;
            d.think     = door_go_up;
        }

        d = find(d, classname, "func_door");
    }
};

// ============================================================================
//  Team spawn point stubs
//
//  Empty QC functions so the engine keeps these entities at map load
//  (entities with no matching QC function get dropped).  Their classnames
//  are the spawn-search anchors for PlayerGetSpawnPointEntity.
// ============================================================================

// No longer empty stubs.  Spawn_PointInit (sv_player.qc) seeds the GoldSrc
// "Start Off" spawnflag and installs the .use that toggles the point on and
// off.  Without a .use, Trigger_UseTargets skips these entirely, which is why
// every `trigger_relay -> spawn_startN` chain in the Sven maps did nothing.
void() Spawn_PointInit;      // sv_player.qc — compiles after this file

void() info_player_blue = { Spawn_PointInit(); };
void() info_player_red = { Spawn_PointInit(); };
void() info_player_start_blue = { info_player_blue(); };
void() info_player_start_red = { info_player_red(); };
void() info_player_team1 = { info_player_blue(); };
void() info_player_team2 = { info_player_red(); };

// CS-style fallback spawn — empty stub so the engine keeps the entity
// at map load.  PlayerGetSpawnPointEntity falls back to
// info_player_deathmatch as the RED/T-side primary CS spawn classname.
// info_player_start already has its own QC function in sv_player.qc.
void() info_player_deathmatch = { Spawn_PointInit(); };
