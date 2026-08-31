// ============================================================
//  shared/weapons/sh_wpn_dodbinocs.qc  -  DoD binoculars
//
//  Slot  : SLOT_UTILITY  (impulse 4 / the utility ring)
//  Stats : none — it is a tool, not ordnance
//  Fire  : +attack raises them to the eyes and zooms; +attack again lowers them
//  Alt   : none
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  IT HAS NO WORLD MODEL AND NO PLAYER MODEL, and that is not an omission on
//  this end: dod/models ships v_binoculars.mdl and nothing else — no
//  w_binoculars.mdl, no p_binoculars.mdl (checked against all nine mounts).
//  That single fact decides the whole shape of this file:
//    * it CANNOT be dropped, so there is no W_*Drop and no weapon_drop_target
//      path — W_BinocsDrop would have to setmodel() a path that does not exist,
//      and an unprecached setmodel yields modelindex 0, which makes the engine
//      drop the entity entirely (the invisible-weapon failure sh_customdefs.qc
//      documents at length);
//    * it CANNOT be map-placed, so there is no weapon_binoculars() spawn
//      function and no W_RegisterMapWeapon;
//    * its manifest pmodel string is empty, following WMF_WEP_FLAKSHOTGUN.
//  It is given, carried and used.  That is all it can be.
//
//  IT IS A UTILITY ITEM, not a slot weapon, for the same reason the medkit is:
//  it takes up no combat slot, it has no ammunition and it does not shoot.  That
//  puts it behind the FIVE registries SLOT_UTILITY needs — the three tables and
//  the ring in sh_wpn_snowball.qc.
//
//  OWNERSHIP IS A COUNT, and the argument that used to sit here for making it
//  slot-based instead was wrong.  It said: an ammo-based rule needs the count
//  shipped through the prediction proxy (four coordinated edits, and the client
//  shows 0 forever if any one is missed), and "there is no count to ship, so
//  `slot_utility == wep` answers both questions".
//
//  That test is CIRCULAR.  slot_utility is the selection CURSOR, and
//  W_UtilityRefreshSlotBinding rebuilds the cursor by walking the utility ring
//  asking W_UtilityPlayerHasWeapon of each weapon in turn — which, for this one,
//  asked whether the cursor was already on it.  So the binoculars were owned only
//  while selected, and the first refresh after they were given (any pickup, any
//  drop, any death, any utility cycle) moved the cursor and disowned them
//  permanently.  Reported as "binoculars despawn immediately and I can't switch
//  to them?  zero ammo?" — and the zero was the literal answer.
//
//  So they ship a count after all: .ammo_dodbinocs, 1 while carried and 0 when
//  not.  All four edits are done — the wire byte, the pm_ammo_mb2 bit, both
//  baseline re-arms, the sv_confirmed_* store and the unconditional reconcile —
//  see PM_CSQC_PROXY_VERSION v29.  The field itself is declared in sh_weapons.qc
//  rather than here, because sh_wpn_snowball.qc reads it and compiles 134 lines
//  EARLIER than this file, and QC cannot forward-declare a field.
//
//  IT MUST BE IN W_FireIsServerAutonomous.  It hand-rolls its try-fire rather
//  than going through SH_StandardTryFire, so it never emits `cmd cs` and the
//  server would never call self.fire() — +attack would do nothing, silently.
//  The three AT launchers are the counter-example: they DO reach
//  SH_StandardTryFire and listing them fired two rockets per trigger pull.
//
//  MEASURED FROM dod/models/v_binoculars.mdl — 5 sequences, 49 bones:
//   [0] idle_down   3fps  2f 0.333s   <- carried, at the chest
//   [1] down_to_up 30fps 31f 1.000s
//   [2] idle_up    30fps  2f 0.033s   <- at the eyes; this is the zoomed pose
//   [3] up_to_down 30fps 31f 1.000s
//   [4] draw       45fps 31f 0.667s
//  No events at all — the model names no sounds, so the raise/lower clicks below
//  borrow weapons/rifleselect.wav rather than inventing a path.

// --- State ---
// The carry count (.ammo_dodbinocs) is declared in sh_weapons.qc — see the
// header for why it cannot live here.  The raise is a two-state latch mirrored on
// both sides through .weaponstate and .zoomstage, which the snapshot already
// carries for every scoped weapon.
.float dodbinocs_up;

const float DODBINOCS_SEQ_IDLE_DOWN = 0;
const float DODBINOCS_SEQ_UP        = 1;
const float DODBINOCS_SEQ_IDLE_UP   = 2;
const float DODBINOCS_SEQ_DOWN      = 3;
const float DODBINOCS_SEQ_DRAW      = 4;

const float DODBINOCS_FRAME_INTERVAL = 0.0333334;
const float DODBINOCS_TOGGLE_DELAY   = 0.40;

// THE ZOOM.  Field glasses, not a rifle scope — a wide magnified view rather than
// the 24 / 12 degree tunnels ZOOM_FOV_STAGE1/2 give the snipers.  40 degrees off a
// default 90 is a shade over 2x, which is about what a pair of WWII binoculars is
// worth and leaves enough field to actually spot with.
//
// Read by client/cl_main.qc's zoom-FOV branch.  The overlay it draws is the STATIC
// HUD_DrawScope (cl_hud.qc) — a fixed centred circle in a full black surround, the
// same one the G3SG1 and SG550 use — deliberately NOT the CoD state machine, whose
// overlay travels with the gun-raise and would fight an animation the binoculars
// already have.
const float DODBINOCS_ZOOM_FOV       = 40;

const float DODBINOCS_IDLE_REARM_MIN = 10;
const float DODBINOCS_IDLE_REARM_MAX = 15;

const string DODBINOCS_VIEWMODEL    = "models/v_binoculars.mdl";
const string DODBINOCS_DEPLOY_SOUND = "";
const string DODBINOCS_DISPLAY_NAME = "BINOCULARS";

// ============================================================
//  SHARED — sequence resolution
// ============================================================

float() SH_DodBinocsSeqIdleDown = { return SH_SeqForName(DODBINOCS_VIEWMODEL, "idle_down",  DODBINOCS_SEQ_IDLE_DOWN); };
float() SH_DodBinocsSeqUp       = { return SH_SeqForName(DODBINOCS_VIEWMODEL, "down_to_up", DODBINOCS_SEQ_UP); };
float() SH_DodBinocsSeqIdleUp   = { return SH_SeqForName(DODBINOCS_VIEWMODEL, "idle_up",    DODBINOCS_SEQ_IDLE_UP); };
float() SH_DodBinocsSeqDown     = { return SH_SeqForName(DODBINOCS_VIEWMODEL, "up_to_down", DODBINOCS_SEQ_DOWN); };
float() SH_DodBinocsSeqDraw     = { return SH_SeqForName(DODBINOCS_VIEWMODEL, "draw",       DODBINOCS_SEQ_DRAW); };

float() SH_DodBinocsDrawDuration = { return SH_SeqDuration(DODBINOCS_VIEWMODEL, SH_DodBinocsSeqDraw(), 0.667); };
float() SH_DodBinocsUpDuration   = { return SH_SeqDuration(DODBINOCS_VIEWMODEL, SH_DodBinocsSeqUp(),   1.000); };
float() SH_DodBinocsDownDuration = { return SH_SeqDuration(DODBINOCS_VIEWMODEL, SH_DodBinocsSeqDown(), 1.000); };

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_DodBinocsTickState =
{
    if (self.weaponstate == WS_DRAW)
    {
        float el = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;
        if (el >= SH_DodBinocsDrawDuration()) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }
    return 0;
};

// A raise or a lower.  Not SH_StandardTryFire: there is no magazine, no refire
// and no dry-fire — this is a toggle, and it is why the binoculars have to be
// listed in W_FireIsServerAutonomous (see the header).
// THE ZOOM ENGAGES AT THE END OF THE RAISE, NOT AT THE PRESS.
//
// attack_finished is the timestamp the current take ends (see the toggle below), so
// this is "the binoculars are up AND they have finished going up".  Both VMs own
// dodbinocs_up and attack_finished locally and set them from the same shared toggle,
// so the two sides agree with no wire change.
//
// The DISENGAGE side falls out for free and is already what was asked for: the flip
// clears dodbinocs_up on the first frame of up_to_down, so the view comes back the
// instant they start coming down rather than a second later.
float(float now) SH_DodBinocsZoomEngaged =
{
    return self.dodbinocs_up && now >= self.attack_finished;
};

float(float now) SH_DodBinocsTryToggle =
{
    // RISING EDGE.  Without it a held +attack flapped the binoculars up and down
    // for as long as the key was down — the toggle's only debounce was
    // attack_finished, which the toggle itself had just satisfied.
    if (!SH_StanceAltEdge(TRUE)) return 0;

    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire())  return 0;
    if (SH_ShieldBlocksFire())     return 0;
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;

    self.dodbinocs_up    = !self.dodbinocs_up;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    // The REAL take length, not a flat DODBINOCS_TOGGLE_DELAY: attack_finished has
    // to name the end of the animation for SH_DodBinocsZoomEngaged to mean
    // anything, and the two takes are read from the model.
    self.attack_finished = now + (self.dodbinocs_up ? SH_DodBinocsUpDuration()
                                                    : SH_DodBinocsDownDuration());
    // zoomstage is NOT written here any more.  It used to be latched on the press,
    // which would have slammed the scope overlay and the FOV punch on while the
    // binoculars were still down at the chest, with the whole 1 s raise playing
    // behind an already-zoomed screen.  It is derived per tick instead, below.
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void(entity player) W_DodBinocsPickupCopy = { };   // nothing to carry

void() W_DodBinocsFire =
{
    if (SH_DodBinocsTryToggle(time))
    {
        self.weaponframe   = self.dodbinocs_up ? SH_DodBinocsSeqUp() : SH_DodBinocsSeqDown();
        self.wep_nextframe = time + DODBINOCS_FRAME_INTERVAL;
        sound(self, CHAN_WEAPON, "weapons/rifleselect.wav", 0.6, ATTN_NORM);
    }
};

// The button-up half of the rising-edge latch.  .altrelease is called on every
// frame the button is up — but this weapon toggles on +attack (button0), not
// +attack2, so the clear has to live in the frame function instead, and the frame
// function has to keep running for it.  See W_DodBinocsFrame.
void() W_DodBinocsFrame =
{
    self.wep_nextframe += DODBINOCS_FRAME_INTERVAL;

    // Rising-edge clear for the +attack toggle.  button0, not button1: the
    // binoculars are the odd one out among the toggles in this tree.
    if (!self.button0)
        SH_StanceAltEdge(FALSE);

    // ZOOM STATE, derived rather than latched — see SH_DodBinocsZoomEngaged.
    self.zoomstage    = SH_DodBinocsZoomEngaged(time);
    self.sv_zoomstage = self.zoomstage;

    float result = SH_DodBinocsTickState(time);
    if (result & 1)
    {
        self.weaponframe   = self.dodbinocs_up ? SH_DodBinocsSeqIdleUp() : SH_DodBinocsSeqIdleDown();
        // DO NOT RETIRE while the binoculars are up or still moving: this
        // function is the only thing that advances the zoom state and clears the
        // edge latch, and self.wepframe only runs while wep_nextframe > 0.
        if (!self.dodbinocs_up && time >= self.attack_finished)
            self.wep_nextframe = 0;
    }
};

void() W_DodBinocsEquip =
{
    W_SetADSProfile(FALSE, "", SCOPE_CLASS_NONE);
    W_StandardEquipSetup(DODBINOCS_VIEWMODEL, DODBINOCS_DISPLAY_NAME, SH_DodBinocsSeqDraw(),
        DODBINOCS_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DodBinocsFire;
    self.reload   = __NULL__;
    self.wepframe = W_DodBinocsFrame;
    self.shoot    = __NULL__;
    self.altfire  = __NULL__;
    // Always come up stowed, whatever state they were left in.
    self.dodbinocs_up = FALSE;
    self.wep_stance_alt_held = 0;
    W_ClearZoom();
    W_SetCrosshairProfile(0.01, 0.01, 300, 1.0, FALSE);
};

// NO W_DodBinocsDrop AND NO weapon_binoculars() — see the header.  Both would
// have to name a world model that does not exist.

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictDodBinocsCommand =
{
    if (input_buttons & 1)
    {
        if (SH_DodBinocsTryToggle(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "weapons/rifleselect.wav", 0.6, ATTN_NONE);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }
    else
    {
        // Clearing half of the rising-edge latch, mirroring W_DodBinocsFrame's.
        SH_StanceAltEdge(FALSE);
    }

    // The zoom, derived from the same shared predicate the server uses.  Client
    // side this is what actually drives the overlay and the FOV — zoomstage is
    // deliberately client-local and never reconciled (cl_player.qc: "zoomstage
    // stays local"), so the client has to compute it rather than wait for it.
    self.zoomstage = SH_DodBinocsZoomEngaged(csqc_pred_time);

    SH_DodBinocsTickState(csqc_pred_time);
};

// The raise/lower transition is latched locally against cltime rather than given
// a weaponstate of its own: a toggle has no state in SH_StandardTickState, and
// inventing one would put this weapon outside every shared fire/lower/shield
// gate that keys on the standard states.  Same device as the AT launchers'
// shoulder pose, which watches the ADS envelope the same way.
float csqc_dodbinocs_up;
float csqc_dodbinocs_change;

float(float elapsed) CSQC_DodBinocsDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SH_DodBinocsSeqDraw();

    float up = predicted_player.dodbinocs_up;

    if (up != csqc_dodbinocs_up)
    {
        csqc_dodbinocs_up     = up;
        csqc_dodbinocs_change = cltime;
    }

    if (csqc_dodbinocs_change > 0)
    {
        float dur = up ? SH_DodBinocsUpDuration() : SH_DodBinocsDownDuration();
        if ((cltime - csqc_dodbinocs_change) < dur)
            return up ? SH_DodBinocsSeqUp() : SH_DodBinocsSeqDown();
        csqc_dodbinocs_change = 0;
    }

    float held = up ? SH_DodBinocsSeqIdleUp() : SH_DodBinocsSeqIdleDown();
    float idle = SH_SeqIdleDisplay(cltime, WEP_DODBINOCS, predicted_player.weaponstate,
                                   held, held,
                                   DODBINOCS_IDLE_REARM_MIN, DODBINOCS_IDLE_REARM_MAX);
    if (idle >= 0)
        return idle;

    return held;
};

void() CSQC_DodBinocsDropClear = { };

void() CSQC_DodBinocsEquip =
{
    W_SetADSProfile(FALSE, "", SCOPE_CLASS_NONE);
    self.weapon_name         = DODBINOCS_DISPLAY_NAME;
    self.weapon_viewmodel    = DODBINOCS_VIEWMODEL;
    self.weapon_worldmodel   = "";      // there is none — see the header
    self.weapon_deploy_sound = DODBINOCS_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDodBinocsCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_DodBinocsDisplayFrame;
    self.csqc_drop_clear     = CSQC_DodBinocsDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
