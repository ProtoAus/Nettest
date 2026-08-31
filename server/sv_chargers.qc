//
//  sv_chargers.qc  –  func_healthcharger / func_recharge
//
//  The wall-mounted health station and the HEV suit charger.  Only 5
//  placements across 3 of the 22 They Hunger / pizza maps (and no func_recharge
//  at all in that set), but they are the two broadest unimplemented classnames
//  across the whole 156-map corpus — 58 and 45 maps respectively — so they are
//  done here while the pickup work is open.  A charger is a pickup with a rate
//  limit and a refill timer, which is the same shape Pickup_RespawnDelay
//  already models for map items.
//
//  Source of truth: halflife/dlls/healthkit.cpp CWallHealth (:120) and
//  h_battery.cpp CRecharge (:31).  Sven's extra keys come from the BaseCharger
//  FGD block (sven-coop.fgd:1668): CustomJuice, CustomRechargeTime,
//  TriggerOnEmpty, TriggerOnRecharged, and the three sound overrides.
//
//  THE ONE REAL DIVERGENCE IS HOW THE PLAYER HOLDS IT DOWN, and it is a
//  property of this mod's input path, not a choice.  Half-Life's chargers are
//  FCAP_CONTINUOUS_USE: the engine calls Use() every frame the player holds
//  +use.  Here +use arrives as `impulse 11`, fired once on the rising edge only
//  (client/cl_player.qc:414 gates it on the button not already being down), so
//  a Use-per-press charger would need the player to mash the key ~10 times a
//  second to charge at HL's rate.
//
//  sv_momentary.qc already solved this exact problem for the turn-wheels:
//  PM_BTN_USE is set continuously in input_buttons while the key is held, so a
//  per-frame poll from PlayerPreThink can see the hold that the impulse cannot.
//  Charger_TickInteraction below is Momentary_TickInteraction's shape, and it
//  is called from the same place for the same reason.
//

// sv_brushsync.qc / sv_triggers.qc.
void() SV_InitReplicatedSolidBrush;

// GoldSrcFX_Count comes from sv_goldsrc_effects.qc and is NOT re-declared here
// — see the note on the same call in sv_checkpoint.qc.

// Per-map census.  One line, once, only on a map that has a charger.
float chg_reported;

void() Charger_Report =
{
    if (chg_reported)
        return;

    float a = GoldSrcFX_Count("func_healthcharger");
    float b = GoldSrcFX_Count("func_recharge");
    if (!a && !b)
        return;      // latch AFTER this — see the note on GoldSrcFX_Report

    chg_reported = TRUE;
    print(sprintf("[charger] func_healthcharger=%g func_recharge=%g\n", a, b));
};

// Same literal, same reason as MOM_BTN_USE (sv_momentary.qc:67): PM_BTN_USE
// lives in shared/sh_pmove.qc, which compiles after us.
const float CHG_BTN_USE = 128;

// gSkillData defaults — skill.cfg's sk_healthcharger / sk_suitcharger on skill
// 2, which is what the maps were balanced against.
const float CHARGER_HEALTH_JUICE = 50;
const float CHARGER_SUIT_JUICE   = 75;

// multiplay_gamerules.cpp:846 / :851.  In single-player HL both return 0
// ("never recharges"); the multiplayer rules refill after 60 s, and this mod is
// always multiplayer, so 60 is the behaviour that applies.
const float CHARGER_RECHARGE_TIME = 60;

const string SND_HEALTH_START = "items/medshot4.wav";
const string SND_HEALTH_LOOP  = "items/medcharge4.wav";
const string SND_HEALTH_DENY  = "items/medshotno1.wav";
const string SND_SUIT_START   = "items/suitchargeok1.wav";
const string SND_SUIT_LOOP    = "items/suitcharge1.wav";
const string SND_SUIT_DENY    = "items/suitchargeno1.wav";

// Sven BaseCharger keys — lower case for the case-fold (see the note at the
// head of sv_goldsrc_effects.qc).
.float  customjuice;
.float  customrechargetime;
.string triggeronempty;
.string triggeronrecharged;
.string customdeniedsound;
.string customstartsound;
.string customloopsound;

const float CHARGER_KIND_HEALTH = 0;
const float CHARGER_KIND_SUIT   = 1;

.float  chg_kind;
.float  chg_juice;          // m_iJuice
.float  chg_capacity;
.float  chg_next_charge;    // m_flNextCharge — the 0.1 s rate governor
.float  chg_on;             // m_iOn: 0 off, 1 started, 2 looping
.float  chg_sound_time;     // m_flSoundTime
.float  chg_idle_at;        // when the hold stopped, so Off() can run late
.string chg_snd_start;
.string chg_snd_loop;
.string chg_snd_deny;

void() Charger_RechargeThink;

// Fire a Sven trigger-on-X chain by targetname.  These are plain target names
// rather than the entity's own `target`, so the normal SUB_UseTargets walk does
// not reach them.
void(entity chg, string name) Charger_FireNamed =
{
    if (name == "" || !name)
        return;

    entity oldself = self;
    entity oldact  = activator;
    entity e = find(world, targetname, name);
    while (e)
    {
        if (e.use)
        {
            self      = e;
            activator = chg;
            self.use();
        }
        e = find(e, targetname, name);
    }
    self      = oldself;
    activator = oldact;
};

// healthkit.cpp:255 — stop the loop, and start the refill timer if we ran dry.
void(entity chg) Charger_Off =
{
    // THERE IS NO stopsound() BUILTIN IN THESE DEFS.  The way this codebase
    // silences a loop is to re-issue the same sample on the same channel at
    // volume 0 — AmbientGeneric_Stop (sv_ambient_generic.qc:498) fades to
    // exactly that, and sound() on an occupied channel replaces what is
    // playing.  Both loop samples (items/medcharge4.wav 0.80 s,
    // items/suitcharge1.wav 2.06 s) carry WAV loop cue points, which is what
    // makes one sound() call hum indefinitely and why silencing it matters.
    if (chg.chg_on > 1)
        sound(chg, CHAN_VOICE, chg.chg_snd_loop, 0, ATTN_NORM);
    chg.chg_on = 0;

    if (chg.chg_juice > 0)
        return;

    float delay = chg.customrechargetime;
    if (delay <= 0)
        delay = CHARGER_RECHARGE_TIME;

    // A NEGATIVE CustomRechargeTime IS "NEVER", not "immediately".  Sven uses
    // the same sign convention on the pickup delays (see Pickup_RespawnDelay in
    // sv_weapons.qc), and HL's single-player rules return 0 for the same
    // meaning.  Reading a negative as a tiny delay would turn a one-shot
    // charger into an infinite one.
    if (chg.customrechargetime < 0)
        return;

    chg.think     = Charger_RechargeThink;
    chg.nextthink = time + delay;
};

void() Charger_RechargeThink =
{
    self.chg_juice = self.chg_capacity;
    self.frame     = 0;
    self.SendFlags = 1;          // .frame is replicated — see sv_brushsync.qc
    // healthkit.cpp:246 plays the start sound on refill; h_battery.cpp does not.
    if (self.chg_kind == CHARGER_KIND_HEALTH)
        sound(self, CHAN_ITEM, self.chg_snd_start, 1, ATTN_NORM);
    Charger_FireNamed(self, self.triggeronrecharged);
    self.think     = __NULL__;
    self.nextthink = 0;
};

// The deny beep, rate-limited to HL's 0.62 s so holding +use at an empty
// charger is one beep rather than a machine gun.
void(entity chg) Charger_Deny =
{
    if (chg.chg_sound_time > time)
        return;
    chg.chg_sound_time = time + 0.62;
    sound(chg, CHAN_ITEM, chg.chg_snd_deny, 1, ATTN_NORM);
};

// One charge tick.  Returns TRUE if the player is being served, which is what
// keeps the loop sound running.
float(entity chg, entity player) Charger_Serve =
{
    if (chg.chg_juice <= 0)
    {
        chg.frame     = 1;
        chg.SendFlags = 1;
        Charger_Off(chg);
        Charger_Deny(chg);
        return FALSE;
    }

    // Already full — HL keeps charging (TakeHealth just returns 0 and no juice
    // is spent), so the station hums but gives nothing.  Say so with the deny
    // beep instead: a silent no-op at a full-health station reads as broken.
    float cap  = player.max_health ? player.max_health : 100;
    float full;
    float topping_medkit = FALSE;
    if (chg.chg_kind == CHARGER_KIND_HEALTH)
        full = (player.health >= cap);
    else
        full = (player.armor >= SUIT_ARMOR_MAX);
    // Sven's manual, on the medkit: "You can also refill it quickly using
    // wall-mounted health chargers ONCE YOUR OWN HEALTH IS FULL."  That last
    // clause is why this sits inside the full branch rather than beside the
    // health grant below — the station tops you up first and only starts
    // feeding the medkit when there is nothing left to heal.  A health station
    // only, and out of the same juice pool, so it is not free.
    if (full && chg.chg_kind == CHARGER_KIND_HEALTH
        && W_UtilityEntityOwns(player, WEP_MEDKIT)
        && player.ammo_medkit < MAX_AMMO_MEDKIT)
    {
        full = FALSE;
        topping_medkit = TRUE;
    }
    if (full)
    {
        Charger_Deny(chg);
        return FALSE;
    }

    // Start / loop sounds, healthkit.cpp:216-227.
    if (!chg.chg_on)
    {
        chg.chg_on = 1;
        sound(chg, CHAN_ITEM, chg.chg_snd_start, 1, ATTN_NORM);
        chg.chg_sound_time = time + 0.56;
    }
    if (chg.chg_on == 1 && chg.chg_sound_time <= time)
    {
        chg.chg_on = 2;
        // CHAN_VOICE rather than HL's CHAN_STATIC: this is the channel
        // Charger_Off's volume-0 re-issue can silence, and the loop MUST be
        // silenceable or its WAV cue points run it until the map ends.
        sound(chg, CHAN_VOICE, chg.chg_snd_loop, 1, ATTN_NORM);
    }

    // The 0.1 s rate governor — one point per tick, which is what makes a
    // charger take five seconds rather than being instant.
    if (chg.chg_next_charge > time)
        return TRUE;
    chg.chg_next_charge = time + 0.1;

    if (topping_medkit)
    {
        // Health is already at the cap; the point goes into the medkit instead.
        if (!SH_MedkitChargerTopUp(player))
            return TRUE;            // filled between the test and here
    }
    else if (chg.chg_kind == CHARGER_KIND_HEALTH)
        player.health = min(cap, player.health + 1);
    else
        player.armor = min(SUIT_ARMOR_MAX, player.armor + 1);

    chg.chg_juice = chg.chg_juice - 1;
    if (chg.chg_juice <= 0)
    {
        chg.frame     = 1;
        chg.SendFlags = 1;
        Charger_FireNamed(chg, chg.triggeronempty);
        Charger_Off(chg);
        return FALSE;
    }
    return TRUE;
};

// ---------------------------------------------------------------------------
//  Per-frame held-+use poll.  Called from PlayerPreThink for each alive player,
//  exactly where Momentary_TickInteraction is called and for the same reason.
//
//  The aim test is a forward tracebox like the momentary wheels use, not a
//  radius search: a charger is a wall panel, and a radius test would let a
//  player charge through the wall behind it.
// ---------------------------------------------------------------------------
const float CHARGER_USE_RANGE = 80;

.entity chg_active;          // ON THE PLAYER: the charger they are holding

void(entity player) Charger_TickInteraction =
{
    entity chg = world;

    if ((input_buttons & CHG_BTN_USE) && player.health > 0)
    {
        makevectors(player.v_angle);
        vector start = player.origin + player.view_ofs;
        tracebox(start, '-8 -8 -8', '8 8 8',
                 start + v_forward * CHARGER_USE_RANGE, MOVE_NORMAL, player);
        if (trace_ent.classname == "func_healthcharger"
         || trace_ent.classname == "func_recharge")
            chg = trace_ent;
    }

    entity prev = player.chg_active;

    if (chg != world)
    {
        Charger_Serve(chg, player);
        chg.chg_idle_at   = time + 0.25;
        player.chg_active = chg;
        // Aimed away from the one we were holding — shut that one up now
        // rather than waiting out its idle window.
        if (prev != world && prev != chg)
            Charger_Off(prev);
        return;
    }

    if (prev != world)
    {
        // healthkit.cpp:212 gives the charger a 0.25 s Off() think on every
        // Use, so releasing +use for a single frame does not chop the loop.
        // Same window, driven from this side.
        if (time >= prev.chg_idle_at)
        {
            Charger_Off(prev);
            player.chg_active = world;
        }
    }
};

// ---------------------------------------------------------------------------
//  Spawn
// ---------------------------------------------------------------------------
void(float kind) Charger_SpawnCommon =
{
    self.chg_kind = kind;

    if (kind == CHARGER_KIND_HEALTH)
    {
        self.chg_snd_start = SND_HEALTH_START;
        self.chg_snd_loop  = SND_HEALTH_LOOP;
        self.chg_snd_deny  = SND_HEALTH_DENY;
        self.chg_capacity  = CHARGER_HEALTH_JUICE;
    }
    else
    {
        self.chg_snd_start = SND_SUIT_START;
        self.chg_snd_loop  = SND_SUIT_LOOP;
        self.chg_snd_deny  = SND_SUIT_DENY;
        self.chg_capacity  = CHARGER_SUIT_JUICE;
    }

    // sven-coop.fgd:1680-1682 — per-entity sound overrides.
    if (self.customstartsound  != "" && self.customstartsound)
        self.chg_snd_start = self.customstartsound;
    if (self.customloopsound   != "" && self.customloopsound)
        self.chg_snd_loop  = self.customloopsound;
    if (self.customdeniedsound != "" && self.customdeniedsound)
        self.chg_snd_deny  = self.customdeniedsound;

    // sven-coop.fgd:1674.  BOTH corpus placements that set CustomJuice set it
    // to 0, which is the FGD's default and means "use the skill value" — so a
    // strictly-positive test is required, not a non-zero one.
    if (self.customjuice > 0)
        self.chg_capacity = self.customjuice;

    precache_sound(self.chg_snd_start);
    precache_sound(self.chg_snd_loop);
    precache_sound(self.chg_snd_deny);

    SV_InitReplicatedSolidBrush();
    self.chg_juice = self.chg_capacity;
    self.frame     = 0;
};

/*QUAKED func_healthcharger (0 .8 .3) ?
Wall health station.  Hold +use to charge.

"CustomJuice"         total health it can hand out (default 50)
"CustomRechargeTime"  refill delay in seconds; negative = never (default 60)
"TriggerOnEmpty"      targetname fired when it runs dry
"TriggerOnRecharged"  targetname fired when it refills
"CustomStartSound" / "CustomLoopSound" / "CustomDeniedSound"
*/
void() func_healthcharger =
{
    Charger_SpawnCommon(CHARGER_KIND_HEALTH);
};

/*QUAKED func_recharge (0 .4 .9) ?
HEV suit charger.  Hold +use to charge armour.

Keys as func_healthcharger; default juice is 75.
*/
void() func_recharge =
{
    Charger_SpawnCommon(CHARGER_KIND_SUIT);
};
