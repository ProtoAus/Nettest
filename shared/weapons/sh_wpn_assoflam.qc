// ============================================================
//  shared/weapons/sh_wpn_assoflam.qc  -  pizza_ya_san SOFLAM (airstrike laser)
//
//  Slot  : SLOT_UTILITY  (impulse 5 / key 5)
//  Stats : 5 calls, no magazine, 15 s cooldown
//  Fire  : paint a target under open sky, wait 5 s, 8 mortars land on it
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================
//
//  PROVENANCE: svencoop_downloads/scripts/maps/pizza_ya_san/weapon_as_soflam.as
//  ("SOFLAM - AirStrike", credited in the script to Nero's AirStrike plugin) and
//  svencoop_downloads/models/pizza_ya_san/{v,p,w}_soflam.mdl.
//
//  Not implemented at all before this — server/sv_goldsrc_ammo.qc:722 declared
//  it out of scope in as many words ("a laser designator with no counterpart in
//  this mod at all").
//
//  THE SKY TEST IS THE MECHANIC.  :182-212 traces forward, rejects if you are
//  aiming AT sky, then traces straight UP from the impact point and rejects
//  unless THAT hits sky.  So the target must be a real surface with open air
//  above it — you cannot call a strike on something indoors, and that single
//  rule is what makes the weapon a tactical object rather than a rocket
//  launcher with a delay.
//
//  THE CYAN BONUS IS THE OTHER HALF.  :214-281 draws the laser red normally and
//  CYAN while you keep it within BONUS_RANGE of the live strike point, and
//  :301 doubles the shells per tick while it is cyan.  Painting the target
//  through the barrage is worth 16 shells instead of 8, which is the reason to
//  stand still and keep looking at the thing you just called down on.

// --- Ammo field: ammo_soflam, declared in sh_weapons.qc with the other
//     UTILITY pools (sv_weapons.qc drives that slot long before this file). ---

// --- Sequence indices, read out of pizza_ya_san/v_soflam.mdl (4 seqs) --------
// Durations are (numframes-1)/fps, what frameduration() reports
// (gl_hlmdl.c:1542).  The script's own anim enum has exactly these four.
const float SOFLAM_SEQ_IDLE  = 0;   // idle,  2.000 s (121f @ 60)  LOOPING
const float SOFLAM_SEQ_DRAW  = 1;   // draw,  0.983 s  (60f @ 60)
const float SOFLAM_SEQ_FIRE  = 2;   // fire,  0.983 s  (60f @ 60)
const float SOFLAM_SEQ_FIRE2 = 3;   // fire2, 0.983 s  (60f @ 60)

const float SOFLAM_FRAME_INTERVAL = 0.05;

// --- The script's constants, :12-21 ---
const float SOFLAM_MAX_CARRY     = 5;      // given and maximum both
const float SOFLAM_DELAY         = 15;     // cooldown between calls
const float SOFLAM_STRIKE_CNT    = 8;      // shells per strike
const float SOFLAM_STRIKE_IV     = 0.75;   // between shells
const float SOFLAM_STRIKE_BEFORE = 5;      // delay from call to first shell
const float SOFLAM_BONUS_RANGE   = 120;    // keep the laser this close to double up
const float SOFLAM_SPREAD        = 150;    // primary
const float SOFLAM_SPREAD_WIDE   = 500;    // secondary, "wide range"

const float SOFLAM_TRACE_RANGE   = 8192;

// A mortar is a shell dropped from above, so it needs its own numbers rather
// than the grenade launcher's — bigger radius, more damage, and it arrives with
// downward velocity so it detonates on the ground rather than bouncing.
const float SOFLAM_MORTAR_HEIGHT = 2048;
const float SOFLAM_MORTAR_SPEED  = 1400;
const float SOFLAM_MORTAR_RADIUS = 220;
const float SOFLAM_MORTAR_DAMAGE = 130;
const float SOFLAM_MORTAR_MIN    = 30;

// --- State durations, taken from the sequences themselves ---
const float SOFLAM_DRAW_DURATION = 0.983;
const float SOFLAM_FIRE_DURATION = 0.983;

const string SOFLAM_VIEWMODEL    = "models/pizza_ya_san/v_soflam.mdl";
const string SOFLAM_WORLDMODEL   = "models/pizza_ya_san/w_soflam.mdl";
const string SOFLAM_DEPLOY_SOUND = "";
const string SOFLAM_DISPLAY_NAME = "SOFLAM";

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_SoflamTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SOFLAM_DRAW_DURATION) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SOFLAM_FIRE_DURATION) { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// Hand-rolled — no magazine, and the action is a server-side strike rather than
// a shot.  That pair of properties is why WEP_ASSOFLAM appears in
// W_FireIsServerAutonomous (sh_weapons.qc); without it +attack never reaches the
// server at all under the shipped sv_trust_clienthits.
#ifdef SSQC
float(entity e) W_SoflamFindTarget;   // defined below
#endif

// A refused designation costs this rather than the full SOFLAM_DELAY — the
// weapon's own comment always claimed "a bad designation costs nothing but the
// animation"; now there is no animation either, and the cost is real but small.
const float SOFLAM_DRYFIRE_DELAY = 0.5;

float() SH_SoflamCanCall =
{
#ifdef CSQC
    return getstatf(STAT_CAN_SOFLAM);
#else
    return W_SoflamFindTarget(self);
#endif
};

float(float now) SH_SoflamTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW)
        return 0;
    if (now < self.attack_finished)
        return 0;
    if (self.ammo_soflam <= 0)
        return 0;

    // IS THERE ANYTHING TO DESIGNATE?  Without this the full call take played
    // and the server answered with "negative" — the same defect as the medkit,
    // on the same W_FireIsServerAutonomous line, and the predicate is likewise
    // server-only (W_SoflamFindTarget walks entities the client cannot see), so
    // it is mirrored as STAT_CAN_SOFLAM rather than re-derived.
    //
    // This ALSO fixes a second, quieter bug.  W_SoflamCall's refusal path tries
    // to roll the cooldown back — "a bad designation costs nothing but the
    // animation" — but that write is server-side only, and the client's own
    // attack_finished and csqc_fire_guard stay at the full SOFLAM_DELAY because
    // reconcile never writes them back (client/cl_player.qc:1022).  The rollback
    // was invisible and the player ate the whole lockout anyway.  Refusing here,
    // on both sides, with the short delay, makes the comment true at last.
    if (!SH_SoflamCanCall())
    {
        self.attack_finished  = now + SOFLAM_DRYFIRE_DELAY;
#ifdef CSQC
        self.csqc_fire_guard  = now + SOFLAM_DRYFIRE_DELAY;
#endif
        return -1;
    }

    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + SOFLAM_DELAY;
#ifdef CSQC
    self.csqc_fire_guard  = now + SOFLAM_DELAY;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// The live strike, so the laser can tell whether it is being kept on target.
.vector soflam_strike_pos;
.float  soflam_strike_end;    // 0 = no strike running
.float  soflam_strike_spread;

void(entity player) W_SoflamPickupCopy =
{
    player.ammo_soflam = bound(0, player.ammo_soflam + self.ammo_soflam, SOFLAM_MAX_CARRY);
};

// Sky both ways: the shot must land on a real surface, and that surface must
// have open air above it.  .as:182-212.
//
// Returns TRUE and sets soflam_strike_pos, or FALSE with the reason already
// sounded by the caller.
float(entity p) W_SoflamFindTarget =
{
    makevectors(p.v_angle);
    vector src = p.origin + p.view_ofs;
    traceline(src, src + v_forward * SOFLAM_TRACE_RANGE, MOVE_NORMAL, p);

    // Aiming at the sky itself designates nothing.  Sky is detected the way the
    // rest of this tree detects it — by sampling just BEHIND the impact plane
    // (sv_weapons.qc:1037), because a traceline stops AT the sky brush and the
    // point in front of it is still open air.
    if (trace_fraction >= 1)
        return FALSE;
    if (pointcontents(trace_endpos + trace_plane_normal * -2) == CONTENT_SKY)
        return FALSE;

    vector hit = trace_endpos;

    // ...and the strike has to be able to reach it: straight up from the impact
    // must leave the map.  Anything else — a ceiling, a walkway, a shelf — means
    // there is no line for the shells and the call is refused.
    traceline(hit + '0 0 1', hit + '0 0 8192', MOVE_NORMAL, p);
    if (trace_fraction < 1
        && pointcontents(trace_endpos + trace_plane_normal * -2) != CONTENT_SKY)
        return FALSE;

    p.soflam_strike_pos = hit;
    return TRUE;
};

void() W_SoflamMortarExplode =
{
    float saved_dim = dimension_send;
    if (self.owner)
        dimension_send = dimension_send & ~self.owner.dimension_seen;
    te_explosion(self.origin + '0 0 8');
    dimension_send = saved_dim;

    W_RadiusExplode(self.origin, SOFLAM_MORTAR_RADIUS,
                    SOFLAM_MORTAR_DAMAGE, SOFLAM_MORTAR_MIN,
                    900, 400, self.owner);
    remove(self);
};

void() W_SoflamMortarTouch =
{
    W_SoflamMortarExplode();
};

void() W_SoflamMortarTick =
{
    self.SendFlags |= 1;
    if (time >= self.proj_fuse_end)
    {
        W_SoflamMortarExplode();
        return;
    }
    self.nextthink = time + Toss_NextThinkInterval();
};

// One shell, dropped from SOFLAM_MORTAR_HEIGHT above a scattered point.
// `caller` rather than `owner`: .owner is a field, and QC puts fields and
// locals in one namespace, so a parameter of that name is a redeclaration.
void(entity caller, vector at, float spread) W_SoflamDropMortar =
{
    vector org = at;
    org_x = org_x + (random() * 2 - 1) * spread;
    org_y = org_y + (random() * 2 - 1) * spread;
    org_z = org_z + SOFLAM_MORTAR_HEIGHT;

    entity m = spawn();
    m.owner     = caller;
    m.classname = "proj_soflam_mortar";
    m.movetype  = MOVETYPE_TOSS;
    m.solid     = SOLID_BBOX;
    setmodel(m, "models/weapons/wpn_grenadelauncher/grenade.mdl");
    setsize(m, '-2 -2 -2', '2 2 2');
    setorigin(m, org);
    // Straight down, with a little randomised speed so eight shells do not
    // arrive in one perfectly simultaneous rank.
    m.velocity  = '0 0 -1' * (SOFLAM_MORTAR_SPEED * (0.85 + random() * 0.3));
    m.avelocity = '300 200 100';
    m.gravity   = 1;
    m.touch     = W_SoflamMortarTouch;
    m.proj_type     = PROJ_TYPE_GRENADE;
    m.SendEntity    = projectile_SendEntity;
    m.SendFlags     = 1;
    m.proj_fuse_end = time + 12;    // backstop; it should hit the ground first
    m.think         = W_SoflamMortarTick;
    m.nextthink     = time + Toss_NextThinkInterval();
};

// The barrage.  Runs on a relay entity rather than on the player, so it keeps
// going if they die, switch weapons or walk away — an airstrike that is called
// off because the caller changed weapons is not an airstrike.
void() W_SoflamStrikeThink =
{
    entity caller = self.owner;

    // Cyan bonus: two shells per tick while the caller is still painting within
    // BONUS_RANGE of the strike point.  .as:301.
    float count = 1;
    if (caller && caller.soflam_strike_end > time
        && vlen(caller.soflam_strike_pos - self.origin) <= SOFLAM_BONUS_RANGE)
        count = 2;

    float i;
    for (i = 0; i < count; i = i + 1)
        W_SoflamDropMortar(caller, self.origin, self.aiment ? SOFLAM_SPREAD_WIDE : SOFLAM_SPREAD);

    self.cnt = self.cnt - 1;
    if (self.cnt <= 0)
    {
        if (caller)
            caller.soflam_strike_end = 0;
        remove(self);
        return;
    }
    self.nextthink = time + SOFLAM_STRIKE_IV;
};

void(float wide) W_SoflamCall =
{
    if (!W_SoflamFindTarget(self))
    {
        // The script's own refusal — an hgrunt saying no.
        sound(self, CHAN_WEAPON, "hgrunt/negative.wav", 1, ATTN_NORM);
        // Not a spent call: the cooldown is rolled back so a bad designation
        // costs nothing but the animation.
        self.attack_finished = time + 0.5;
        return;
    }

    self.ammo_soflam = self.ammo_soflam - 1;
    self.soflam_strike_end = time + SOFLAM_STRIKE_BEFORE
                                  + SOFLAM_STRIKE_CNT * SOFLAM_STRIKE_IV;

    // Radio acknowledgement — the script picks one of three.
    float r = random();
    if (r < 0.333)      sound(self, CHAN_VOICE, "hgrunt/roger.wav", 1, ATTN_NORM);
    else if (r < 0.666) sound(self, CHAN_VOICE, "hgrunt/yessir.wav", 1, ATTN_NORM);
    else                sound(self, CHAN_VOICE, "hgrunt/affirmative.wav", 1, ATTN_NORM);

    entity strike = spawn();
    strike.classname = "soflam_strike";
    strike.owner     = self;
    strike.cnt       = SOFLAM_STRIKE_CNT;
    strike.aiment    = wide ? self : world;   // carries the wide-spread flag
    setorigin(strike, self.soflam_strike_pos);
    strike.think     = W_SoflamStrikeThink;
    strike.nextthink = time + SOFLAM_STRIKE_BEFORE;
};

// `== 1` / `== -1` throughout, never truthiness — -1 is truthy in QC, so a bare
// `if (SH_SoflamTryFire(time))` would animate the refusal this gate exists to
// suppress.
void() W_SoflamFire =
{
    float r = SH_SoflamTryFire(time);
    if (r == 1)
    {
        self.weaponframe   = SOFLAM_SEQ_FIRE;
        self.wep_nextframe = time + SOFLAM_FRAME_INTERVAL;
        W_SoflamCall(FALSE);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "hgrunt/negative.wav", 1, ATTN_NORM);
};

void() W_SoflamFire2 =
{
    float r = SH_SoflamTryFire(time);
    if (r == 1)
    {
        self.weaponframe   = SOFLAM_SEQ_FIRE2;
        self.wep_nextframe = time + SOFLAM_FRAME_INTERVAL;
        W_SoflamCall(TRUE);
    }
    else if (r == -1)
        sound(self, CHAN_WEAPON, "hgrunt/negative.wav", 1, ATTN_NORM);
};

void() W_SoflamFrame =
{
    // NO `self.weaponframe += 1` — weaponframe is a sequence index and the
    // engine advances the sub-frame itself from .frame1time.
    self.wep_nextframe += SOFLAM_FRAME_INTERVAL;

    float result = SH_SoflamTickState(time);
    if (result & 1)
    {
        // idle carries STUDIO_LOOPING, so the resting pose is safe to hold.
        self.weaponframe   = SOFLAM_SEQ_IDLE;
        self.wep_nextframe = 0;   // idle retire
    }
};

void() W_SoflamEquip =
{
    W_StandardEquipSetup(SOFLAM_VIEWMODEL, SOFLAM_DISPLAY_NAME, SOFLAM_SEQ_DRAW,
        SOFLAM_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_SoflamFire;
    self.altfire  = W_SoflamFire2;
    self.reload   = __NULL__;
    self.wepframe = W_SoflamFrame;
    self.shoot    = W_SoflamFire;
    self.weapon_uses_sequences = TRUE;
    W_SetCrosshairProfile(0, 0, 0, 1, FALSE);
};

void() W_SoflamDrop =
{
    entity tgt = weapon_drop_target;

    setmodel(tgt, SOFLAM_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname      = "weapon_as_soflam";
    tgt.solid          = SOLID_NOT;
    tgt.movetype       = MOVETYPE_TOSS;
    tgt.weapon         = WEP_ASSOFLAM;
    tgt.weapon_slot    = SLOT_UTILITY;
    tgt.weap_draw      = W_SoflamEquip;
    tgt.weap_drop_func = W_SoflamDrop;
    tgt.pickupcopy     = W_SoflamPickupCopy;
    tgt.ammo_soflam    = self.ammo_soflam;
    self.ammo_soflam   = 0;
    tgt.touch          = weapon_touch;
    tgt.dropped_spin   = 0;
    tgt.think          = weapon_become_solid;
    tgt.nextthink      = time + 0.7;
};

void() weapon_as_soflam =
{
    setmodel(self, SOFLAM_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname      = "weapon_as_soflam";
    self.solid          = SOLID_TRIGGER;
    self.movetype       = MOVETYPE_TOSS;
    self.weapon         = WEP_ASSOFLAM;
    self.weapon_slot    = SLOT_UTILITY;
    self.weap_draw      = W_SoflamEquip;
    self.weap_drop_func = W_SoflamDrop;
    self.pickupcopy     = W_SoflamPickupCopy;
    if (!self.ammo_soflam)
        self.ammo_soflam = SOFLAM_MAX_CARRY;
    self.touch          = weapon_touch;
    self.dropped_spin   = 0;
    W_RegisterMapWeapon(weapon_as_soflam);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictSoflamCommand =
{
    // Nothing about the strike is predicted — it is a server-side chain of
    // spawns over ten seconds, and there is nothing a client could usefully
    // guess about it.  Only the animation and the long cooldown run here.
    // NOT gated on pm_suppress_sounds.  That flag means "this is a prediction
    // REPLAY, do not re-emit audio" — it does not mean "do not predict".  Gating
    // the try-fire itself on it meant every reconcile reset to the confirmed
    // state and then replayed the buffered commands WITHOUT this branch, so the
    // predicted weaponstate never re-entered WS_FIRE and the viewmodel sat idle
    // no matter how hard the trigger was held.  There is no sound to suppress in
    // here anyway; the gate was pure loss.
    if (input_buttons & 1)
    {
        // `== 1`: a refusal must not claim an ack for a call that never went out.
        if (SH_SoflamTryFire(csqc_pred_time) == 1)
            CSQC_MarkPendingWeaponAck();
    }

    SH_SoflamTickState(csqc_pred_time);
};

float(float elapsed) CSQC_SoflamDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SOFLAM_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SOFLAM_SEQ_FIRE;
    return SOFLAM_SEQ_IDLE;   // LOOPING — safe to hold
};

void() CSQC_SoflamDropClear =
{
};

void() CSQC_SoflamEquip =
{
    self.weapon_name         = SOFLAM_DISPLAY_NAME;
    self.weapon_viewmodel    = SOFLAM_VIEWMODEL;
    self.weapon_worldmodel   = SOFLAM_WORLDMODEL;
    self.weapon_deploy_sound = SOFLAM_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictSoflamCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_SoflamDisplayFrame;
    self.csqc_drop_clear     = CSQC_SoflamDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
