//
//  sv_buttons.qc  –  func_button (+ button_sparker child for SPARKS spawnflag)
//
//  Replicated SOLID_BSP button.  Spawn registers with
//  SV_InitReplicatedSolidBrush so the CSQC world has a matching
//  SOLID_BSP entity for client-side prediction; whenever the
//  velocity / position changes, SendFlags is set to push the new
//  state through the brushsync wire.
//

// ---------------------------------------------------------------------------
// Externs from earlier compile units.
// ---------------------------------------------------------------------------
void() SetMovedir;                                                   // sv_push.qc
void() SV_InitReplicatedSolidBrush;                                  // sv_brushsync.qc
void(entity caller, entity triggerer) Trigger_UseTargets;            // sv_doors.qc
void(vector destination, float move_speed, void() move_done) Mover_Start;  // sv_doors.qc
string(float idx) Door_LookupLockedSound;                            // sv_doors.qc
string(float idx) Door_LookupUnlockedSound;                          // sv_doors.qc
string(float idx) Button_LookupSound;                                // sv_doors.qc
void(string snd) Door_PrecacheIfReal;                                // sv_doors.qc
// Sven InventoryRules gate — defined in sv_item_inventory.qc (position 265),
// which compiles after this file; the KEY FIELDS it reads are in
// sv_customdefs.qc for exactly that reason.
float(entity rules, entity who) Inv_Gate;                            // sv_item_inventory.qc

// Shared fields — declared authoritatively in sv_doors.qc.
// Redeclared here so this file compiles standalone; QC accepts
// duplicate `.float foo;` decls and they share storage.
.float locked_sound;
.float unlocked_sound;
.string noise_locked;
.string noise_unlocked;

// Sven func_button "Use Type" (sven-coop.fgd:2174).  Values map 1:1 onto the
// USE_* enum in sv_doors.qc; FGD default is 3 (Toggle).  Undeclared until now,
// which meant the engine dropped the key on all 117 buttons that set it.
.float use_type;

// ============================================================================
//  func_button
// ============================================================================

float BUTTON_STATE_BOTTOM = 0;
float BUTTON_STATE_UP     = 1;
float BUTTON_STATE_TOP    = 2;
float BUTTON_STATE_DOWN   = 3;

// Spawnflags
//   1   — DONT_MOVE: button fires its targets without physically
//          moving.  Useful for keypads / scripted no-motion triggers.
//   32  — TOGGLE: button stays at the top after the first press;
//          the next press reverses it back to BOTTOM.  Each press
//          fires Trigger_UseTargets so attached entities can latch
//          on the toggle edges.
//   64  — SPARKS: continuously emits sparks + a randomised electrical
//          break sound at the button's centre, ~1 s cadence.  Drives
//          a tiny child entity ("button_sparker") that holds the
//          recurring think so it doesn't conflict with the button's
//          own movement think slot.
//   256 — TOUCH_ACTIVATES: a player touching the brush activates it.
//          Default off — buttons are +use-only unless this is set.
const float BUTTON_DONT_MOVE       = 1;
const float BUTTON_TOGGLE          = 32;
const float BUTTON_SPARKS          = 64;
const float BUTTON_TOUCH_ACTIVATES = 256;

// Sven/GoldSrc func_button uses the SAME four bits with the same meanings
// (sven-coop.fgd:2166-2172), so unlike func_door there is nothing to
// normalise here.  What DOES differ is the double-fire below.

// TRUE on native maps, FALSE on GoldSrc ones.  Decided once at spawn.
//
// This mod re-fires the target chain in button_return so a plain button
// produces a momentary PULSE on light entities (press = on, auto-return =
// off).  Half-Life's CBaseButton::ButtonReturn does NOT do that — it fires
// only in ButtonWait.  On a GoldSrc map the extra fire is actively harmful:
// a multisource input toggles ON at button_wait and straight back OFF `wait`
// seconds later, so a multi-button AND-gate can never latch.  Measured on
// -sp_campaign_portal: 77 buttons feed a multisource, 75 of them with
// wait 0.5, and 18 carry neither DONT_MOVE nor TOGGLE — exactly this case.
.float button_refire_on_return;

void() button_fire;
void() button_return;
void() button_done;

void() button_done =
{
    setorigin(self, self.pos1);
    self.velocity      = '0 0 0';
    self.button_state  = BUTTON_STATE_BOTTOM;
    self.mover_state   = MOVER_STATE_BOTTOM;
    self.frame         = 0;
    self.SendFlags     = 1;

    if (self.max_health)
        self.health = self.max_health;
};

void() button_return =
{
    self.button_state = BUTTON_STATE_DOWN;
    self.mover_state  = MOVER_STATE_DOWN;
    // Re-fire targets when the button starts heading back down.
    // This is what makes a non-TOGGLE button produce a momentary
    // pulse on light entities: press → light toggles on, button
    // auto-returns after `wait` → re-fire toggles light back off.
    // TOGGLE buttons skip the auto-return path entirely
    // (button_wait gates on TOGGLE) so the light stays in its
    // new state.  Other target classes — doors, breakables,
    // other buttons — handle their own state via `.use` and are
    // either idempotent on repeat or actively want the toggle.
    // GoldSrc maps skip this entirely — see button_refire_on_return.
    if (self.button_refire_on_return)
    {
        sub_use_type = self.use_type ? self.use_type : USE_TOGGLE;
        Trigger_UseTargets(self, self.enemy);
    }
    // DONT_MOVE: collapse the return into the done callback so we
    // don't spin the mover with a zero-distance move.
    if (self.spawnflags & BUTTON_DONT_MOVE)
    {
        button_done();
        return;
    }
    Mover_Start(self.pos1, self.speed, button_done);
};

void() button_wait =
{
    // DONT_MOVE skips origin/velocity touch — pos2 == pos1 in spawn
    // for these buttons but we don't want to call setorigin on a
    // brush whose physical position should never change.
    if (!(self.spawnflags & BUTTON_DONT_MOVE))
    {
        setorigin(self, self.pos2);
        self.velocity = '0 0 0';
    }
    self.button_state = BUTTON_STATE_TOP;
    self.mover_state  = MOVER_STATE_TOP;
    self.frame        = 1;
    self.SendFlags    = 1;
    // use_type: Sven's key maps 1:1 onto our USE_* enum (0 Off / 1 On /
    // 2 Set / 3 Toggle, sven-coop.fgd:2174) — no transposition, unlike
    // `triggerstate`.  FGD default is 3, which is USE_TOGGLE anyway.
    //
    // The ternary below has the same shape as the sub_use_type bug USE_UNSET
    // closes (sv_customdefs.qc), and for a FIELD it cannot be fixed the same
    // way: FTE binds a declared field straight from the keyvalue, so an absent
    // `use_type` and an explicit `use_type 0` are both 0 by the time the spawn
    // function runs, and telling them apart would mean routing the key through
    // the ED_ParseUnknownEpair hook the way sv_multi_manager.qc does.
    //
    // Measured before leaving it alone: 1019 `use_type` keys across the 137-map
    // corpus (Sven + local + vanilla) — 995 of value 3, 22 of 2, 2 of 1, and
    // ZERO of 0.  No map asks a button to fire an explicit Off, so this is
    // latent.  If one ever does, the harvest-hook route above is the fix.
    //
    // SUB_UseTargets rather than the bare walker: func_button inherits
    // Targetx, so `killtarget` and `delay` are real keys the two-arg form
    // silently drops.  Measured: 16 of pizza_ya_san1's 30 buttons carry a
    // killtarget that never fired, plus 3 delays across pizza and portal.
    SUB_UseTargets(self, self.enemy, self.use_type ? self.use_type : USE_TOGGLE);

    if (self.wait < 0)
        return;
    // TOGGLE: stay at TOP until the next press reverses us. Without
    // this gate we'd schedule an automatic return and the toggle
    // semantics would only hold for `wait` seconds.
    if (self.spawnflags & BUTTON_TOGGLE)
        return;

    self.nextthink = self.ltime + self.wait;
    if (self.spawnflags & BUTTON_DONT_MOVE)
        self.think = button_done;       // no motion phase, just reset state
    else
        self.think = button_return;
};

void() button_blocked =
{
};

void() button_fire =
{
    // Live gate: mp_disabledoors suppresses ALL button activation
    // regardless of how the press got here (use, touch, damage).
    // Bhop forces this on via the StartFrame gamemode block in
    // sv_main.qc; admins can also flip it in any other mode.
    if (cvar("mp_disabledoors")) return;

    // `master` gate.  func_button carries a master key in Sven's FGD
    // (sven-coop.fgd:2147) and 80 buttons across the target maps use it,
    // but this entity never checked it — every multisource-locked button
    // fired regardless.  Placed BEFORE the TOGGLE-reverse and re-press
    // gates so a rejected press changes no state at all.
    //
    // IsMasterTriggered returns TRUE for an unknown master name, so a
    // mapper typo can't brick a button.
    if (!IsMasterTriggered(self.master, self.enemy))
    {
        if (self.noise_locked)
            sound(self, CHAN_VOICE, self.noise_locked, 1, ATTN_NORM);
        return;
    }

    // TOGGLE-reverse: a press against an already-pressed button
    // reverses it instead of being ignored.  We re-fire the click
    // sound on the reverse so the player hears each edge.
    if ((self.spawnflags & BUTTON_TOGGLE)
        && (self.button_state == BUTTON_STATE_TOP
            || self.button_state == BUTTON_STATE_UP))
    {
        if (self.noise)
            sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);
        button_return();
        return;
    }

    // Standard "ignore re-press while already up" gate.
    if (self.button_state == BUTTON_STATE_UP || self.button_state == BUTTON_STATE_TOP)
        return;

    if (self.noise)
        sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);

    // DONT_MOVE: skip the motion phase entirely and route straight
    // into button_wait so the targets fire and the wait timer / TOGGLE
    // semantics stay identical to the moving case.
    if (self.spawnflags & BUTTON_DONT_MOVE)
    {
        button_wait();
        return;
    }

    self.button_state = BUTTON_STATE_UP;
    self.mover_state  = MOVER_STATE_UP;
    Mover_Start(self.pos2, self.speed, button_wait);
};

void() button_use =
{
    // Sven's InventoryRules — func_button and func_rot_button are both on the
    // list of classes it gates ("Prevent button being used").
    if (!Inv_Gate(self, activator))
        return;
    self.enemy = activator;
    button_fire();
};

void() button_touch =
{
    if (other.classname != "player")
        return;
    if (!Inv_Gate(self, other))
        return;
    // TOUCH_ACTIVATES gate — buttons no longer fire on touch by
    // default, mappers must opt in.  +use-only is the standard
    // GoldSrc / HL behaviour.
    if (!(self.spawnflags & BUTTON_TOUCH_ACTIVATES))
        return;
    self.enemy = other;
    button_fire();
};

// SPARKS — child entity that lives next to a func_button and emits a
// scattered te_spark + electronic break sound on a 1.5..3.5 s cadence.
// Lives on its own .think slot so it doesn't fight the button's
// movement think.  Removed automatically if the parent button
// vanishes (e.g. round restart that re-spawned the brush).
void() button_spark_think =
{
    entity btn = self.owner;
    if (!btn || btn == world || btn.classname != "func_button")
    {
        remove(self);
        return;
    }

    vector centre = (btn.absmin + btn.absmax) * 0.5;
    vector outward;
    if (btn.movedir != '0 0 0')
        outward = btn.movedir * -1;     // away from press direction
    else
        outward = '0 0 1';
    // Emit at the bbox centre — the previous "+ outward * 16" push
    // looked too high on ceiling-mounted / vertically-pressed buttons
    // and was offset on irregularly-shaped brushes.  outward is still
    // shipped as the wire normal so CSQC sprays particles away from
    // the press face.
    vector spawn_pos = centre;

    vector jitter = [(random() - 0.5) * 4, (random() - 0.5) * 4, (random() - 0.5) * 4];
    vector emit   = spawn_pos + jitter;

    // Route through CSQC so we hit the same particle path the user
    // already confirmed works (weapons.metal_impact for electronic
    // surfaces).  te_spark from SSQC rendered nothing in this engine
    // config — pointparticles via the loaded particle config does.
    //
    // 3 normal bytes: -1..1 → 1..255 byte (128 = 0).  CSQC reverses
    // it to a unit vector and uses it as outward velocity.
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_BUTTON_SPARK);
    WriteCoord(MSG_MULTICAST, emit_x);
    WriteCoord(MSG_MULTICAST, emit_y);
    WriteCoord(MSG_MULTICAST, emit_z);
    WriteByte(MSG_MULTICAST, bound(0, rint(outward_x * 127 + 128), 255));
    WriteByte(MSG_MULTICAST, bound(0, rint(outward_y * 127 + 128), 255));
    WriteByte(MSG_MULTICAST, bound(0, rint(outward_z * 127 + 128), 255));
    multicast(emit, MULTICAST_PVS);

    // Pull only HL1 / HL3 from the breakable-circuit pool (already
    // precached in sh_customdefs.qc).  The full 8-sample pool was
    // too varied and noisy for a long-running idle sparker.
    string pick;
    if (random() < 0.5)
        pick = "sounds/debris/break_eletronichl1.wav";
    else
        pick = "sounds/debris/break_eletronichl3.wav";
    sound(btn, CHAN_AUTO, pick, 0.2, ATTN_NORM);

    self.nextthink = time + 1.5 + random() * 2.0;   // 1.5 - 3.5 s
};

/*QUAKED func_button (0 .5 .8) ? DONT_MOVE x x x x TOGGLE SPARKS x x TOUCH_ACTIVATES
+use, shoot, or (with TOUCH_ACTIVATES) touch to activate.  Moves in
the entity's angle direction, fires targets, waits, and optionally
returns.

DONT_MOVE (1):       fires targets without physical motion.
TOGGLE (32):         stays at top until pressed again (each press fires).
SPARKS (64):         emits sparks + electrical noise every ~1 s.
TOUCH_ACTIVATES (256): a player walking into the brush activates it.

"angle"    opening direction
"target"   entities to fire when pressed
"speed"    movement speed (default 40)
"wait"     seconds before returning (default 1, -1 = never)
"lip"      remaining lip at end of move (default 4)
"distance" explicit move distance (overrides lip calc)
"sounds"   0=steam 1=wood 2=metallic 3=in-out
*/
void() func_button =
{
    string default_noise;

    // HL/GoldSrc-style press sound table — value 0 = silence, 1..14
    // map onto buttons/buttonN.wav (and a couple of named WAVs).
    // This is the HL convention; the legacy Q1 indices (1=switch21,
    // 2=switch02, 3=switch04) only kick in when the mapper hasn't
    // set a value covered by the HL table — i.e., as a sounds=0
    // fallback or for legacy maps using indices we don't recognise.
    string hl_press = Button_LookupSound(self.sounds);
    if (hl_press != "common/null.wav" && self.sounds > 0)
        default_noise = hl_press;
    else if (self.sounds == 1)
        default_noise = "buttons/switch21.wav";
    else if (self.sounds == 2)
        default_noise = "buttons/switch02.wav";
    else if (self.sounds == 3)
        default_noise = "buttons/switch04.wav";
    else
        default_noise = "buttons/airbut1.wav";

    if (!self.noise)
        self.noise = default_noise;
    precache_sound(self.noise);

    // locked_sound / unlocked_sound on buttons too — same lookup
    // tables as doors.  Stored on the entity for future hooks.
    if (self.locked_sound > 0)   self.noise_locked   = Door_LookupLockedSound(self.locked_sound);
    if (self.unlocked_sound > 0) self.noise_unlocked = Door_LookupUnlockedSound(self.unlocked_sound);
    Door_PrecacheIfReal(self.noise_locked);
    Door_PrecacheIfReal(self.noise_unlocked);

    if (!self.speed) self.speed = 40;
    if (!self.wait)  self.wait  = 1;
    if (!self.lip)   self.lip   = 4;

    SV_InitReplicatedSolidBrush();
    self.brush_type   = BRUSH_TYPE_BUTTON;
    self.button_state = BUTTON_STATE_BOTTOM;
    self.mover_state  = MOVER_STATE_BOTTOM;

    // See button_refire_on_return: HL fires only in ButtonWait; our extra
    // pulse in button_return is a native-map behaviour we keep bit-for-bit.
    self.button_refire_on_return = !Map_IsGoldSrc();

    // Tell CSQC this button can refuse a press, so client prediction
    // doesn't animate a locked button and then snap it back.  Same field
    // and same wire byte the doors already use (sv_brushsync.qc) — no
    // protocol change, only the value differs.
    self.door_has_master = (self.master != "" && self.master != __NULL__);

    // .use is always wired — the actual mp_disabledoors check lives
    // in button_fire so the cvar can toggle live without a map
    // restart.  .touch is gated on the TOUCH_ACTIVATES spawnflag so
    // by default players have to +use the button explicitly.
    self.blocked = button_blocked;
    self.use     = button_use;
    if (self.spawnflags & BUTTON_TOUCH_ACTIVATES)
        self.touch = button_touch;

    // Shootable button: when the mapper sets `health`, hits accumulate
    // damage and Q1's killed-callback triggers button_fire → activate +
    // reset health to max (not "break").  CSQC's predict-break path
    // gates on brush_type == BRUSH_TYPE_STATIC so it doesn't mistake
    // buttons for func_breakables and play the break sound + hide the
    // brush locally.
    if (self.health)
    {
        self.max_health = self.health;
        self.takedamage = DAMAGE_YES;
    }
    self.pos1 = self.origin;

    // SetMovedir RUNS FOR EVERY BUTTON, NOT JUST MOVING ONES, and hoisting it here
    // is the whole fix for "the button is invisible and non-collidable but I can
    // still +use it".
    //
    // SetMovedir (sv_push.qc:25) is the ONLY thing that zeroes .angles, and GoldSrc
    // overloads `angles` on a mover to mean its movement DIRECTION, not a rotation of
    // the brushwork.  The two branches below used to skip it, so a DONT_MOVE button
    // kept the mapper's angles on a SOLID_BSP brush - and a GoldSrc submodel compiled
    // without an ORIGIN brush carries ABSOLUTE world bounds with .origin '0 0 0', so
    // World_LinkEdict (engine/server/world.c:585-622) rotates that box about the world
    // origin.  hl_c01_a1's `ele_top_bttn` (mins -1873 -2786 -1120, angles '0 90 0')
    // linked at x 2784..2786 - about 4650 units from the brush.  PVS leafs come from
    // that box, so it never reaches a client; the narrowphase rotates the same way, so
    // traces miss it.
    //
    // Half-Life never had this bug because CBaseButton::Spawn calls SetMovedir(pev)
    // UNCONDITIONALLY at buttons.cpp:465 - before SET_MODEL - and applies the
    // DONT_MOVE pos2 collapse afterwards at :490-492.  Same order here now.
    //
    // Measured: 278 of the corpus's 2011 DONT_MOVE buttons also carry a non-zero
    // angles key, across 31 maps (stadium4 83, polar_rescue 80, tf_original 43,
    // hl_c01_a1 7, hl_c02_a1 7, hl_c06 6).
    //
    // A mapper-supplied `movedir` still wins, so save it across the call: SetMovedir
    // derives movedir FROM angles and would otherwise overwrite it.
    vector premovedir = self.movedir;
    SetMovedir();
    if (premovedir != '0 0 0')
        self.movedir = premovedir;

    // DONT_MOVE: pin pos2 to pos1 so any code path that touches pos2
    // (button_wait's setorigin guard, defensive Mover_Start) becomes
    // a no-op even if a future caller forgets the spawnflag check.
    if (self.spawnflags & BUTTON_DONT_MOVE)
    {
        self.pos2 = self.pos1;
    }
    else if (premovedir != '0 0 0')
    {
        // An explicit `movedir` key IS the offset, not a direction to scale - 29
        // func_buttons in the corpus set one.  Unchanged from before the hoist.
        self.pos2 = self.pos1 + self.movedir;
    }
    else if (self.distance)
    {
        self.pos2 = self.pos1 + self.movedir * self.distance;
    }
    else
    {
        // Same -2 as func_door and momentary_door, same reason: CBaseButton::Spawn
        // takes back the pixel Mod_LoadSubmodels spreads submodel bounds by.
        vector sz = self.size - '2 2 2';
        self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * sz) - self.lip);
    }

    // Same ordering trap as func_door: SV_InitReplicatedSolidBrush linked this brush
    // with .angles still holding the mapper's press DIRECTION, and SetMovedir has
    // only just zeroed it.  Without a re-link the button carries a PVS box rotated
    // about (0,0,0) and never reaches CSQC until it first moves.
    BrushSync_RelinkAngles();

    // SPARKS: spawn a child sparker entity that lives alongside the
    // button.  Owner-linked so button_spark_think can clean itself up
    // if the button is somehow removed.  The breakable-circuit
    // sound set is already precached in sh_customdefs.qc.
    if (self.spawnflags & BUTTON_SPARKS)
    {
        entity sp = spawn();
        sp.classname  = "button_sparker";
        sp.owner      = self;
        sp.think      = button_spark_think;
        sp.nextthink  = time + random() * 1.0;   // stagger starts
    }
};
