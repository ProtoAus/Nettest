//
//  sv_goldsrc_entities.qc  —  the remaining GoldSrc/Sven point entities
//
//  Split out of sv_goldsrc_compat.qc, which is the "keep unknown classnames
//  alive" shim plus the small stubs.  These three are real implementations and
//  big enough to want their own file:
//
//    target_cdaudio            play / stop a music track          (th_ep1_00 x1)
//    trigger_entity_iterator   per-match activator broadcast      (th_ep1_00 x1)
//    game_player_equip         hand out weapons / ammo / items    (th_ep1_00 x1)
//
//  Compile order: AFTER sv_triggers.qc (SUB_UseTargets, IsMasterTriggered,
//  GoldSrc_TriggerStateToUseType) and AFTER sv_player_weaponstrip.qc.
//

// Defined in sv_player.qc, which compiles after this file.
void(float wep) W_GiveWeaponToSlot;

// ---------------------------------------------------------------------------
// target_cdaudio — play / stop a CD track.
//
// Sven's FGD (:5565) is three keys: targetname, and `health` as the track
// number with -1 = Stop.  The `radius` proximity key the Half-Life SDK had is
// COMMENTED OUT in Sven's FGD, so there is no auto-trigger: the entity only
// responds to being fired, and every use-type behaves the same.
//
// Track numbering: svencoop/media/tracklist.txt starts at 1 = "empty", so
// track N is media/Half-Life<N-1>.mp3 (2 -> Half-Life01.mp3).  That off-by-one
// is Sven's, not ours.  sv_cdaudio_pathfmt lets a server point somewhere else
// without a rebuild; setting it empty falls back to the engine's own
// `cd loop N`, which is what a real CD or a mounted Quake soundtrack wants.
// ---------------------------------------------------------------------------
void() target_cdaudio_use =
{
    float track = self.health;
    string cmd;

    if (track < 0)
        cmd = "cd stop\n";
    else
    {
        string fmt = cvar_string("sv_cdaudio_pathfmt");
        if (fmt != "")
            cmd = sprintf("music %s\n", sprintf(fmt, track - 1));
        else
            cmd = sprintf("cd loop %g\n", track);
    }

    entity p = find(world, classname, "player");
    while (p)
    {
        if (clienttype(p) == CLIENTTYPE_REAL)
            stuffcmd(p, cmd);
        p = find(p, classname, "player");
    }

    if (cvar("sv_debug_use"))
        print(sprintf("[target_cdaudio] track=%g -> %s", track, cmd));
};

/*QUAKED target_cdaudio (1 .9 .5) (-8 -8 -8) (8 8 8)
Plays a music track on every client when fired.

"targetname"  name
"health"      track number; -1 = stop

No spawnflags.  Sven has no proximity radius on this entity.
*/
void() target_cdaudio =
{
    if (!self.health)
        self.health = -1;       // FGD default is "Stop"
    self.use = target_cdaudio_use;
};

// ---------------------------------------------------------------------------
// trigger_entity_iterator — Sven-only, no Half-Life equivalent.
//
// Iterates every entity matching its filters and fires `target` ONCE PER
// MATCH, with the matched entity as the !activator.  That activator forgery is
// the entire point: it is how a map says "for each living player, run this
// chain on them".
//
// th_ep1_00's single instance is exactly that:
//     classname_filter "player", status_filter 1 (living),
//     triggerstate 1 (On), target "equip_suit"
//
// Filters AND together.  delay_between_triggers 0 fires the whole matched set
// in one frame; non-zero paces it, in which case the match set is captured up
// front so it cannot change underneath us mid-run.
// ---------------------------------------------------------------------------
.string name_filter;
.string classname_filter;
.float  status_filter;          // 0 any, 1 living, 2 dead
.float  delay_between_triggers;
.float  run_mode;               // 0 once, 1 once/multi-threaded, 2 toggle loop
.string trigger_after_run;
.float  maximum_runs;
.float  delay_between_runs;
.float  ei_runs;                // completed passes
.float  ei_running;
.entity ei_worker_next;         // captured-match chain (lives on worker ents)
.entity ei_worker_ent;

const float EI_RUN_ONCE    = 0;
const float EI_RUN_ONCE_MT = 1;
const float EI_RUN_TOGGLE  = 2;

float(entity src, entity e) EntIterator_Matches =
{
    if (e == src || e == world)
        return FALSE;
    if (src.name_filter != "" && e.targetname != src.name_filter)
        return FALSE;
    if (src.classname_filter != "" && e.classname != src.classname_filter)
        return FALSE;
    if (src.status_filter == 1 && e.health <= 0)
        return FALSE;
    if (src.status_filter == 2 && e.health > 0)
        return FALSE;
    return TRUE;
};

// Fire `target` once with `who` as the activator.
void(entity src, entity who) EntIterator_FireOne =
{
    entity oldact = activator;
    activator = who;
    SUB_UseTargets(src, who, GoldSrc_TriggerStateToUseType(src.triggerstate));
    activator = oldact;
};

void() EntIterator_EndRun;
void() EntIterator_RunPass;

void() EntIterator_StepWorker =
{
    entity src = self.owner;
    if (!src || wasfreed(src))
    {
        remove(self);
        return;
    }

    if (self.ei_worker_ent && !wasfreed(self.ei_worker_ent))
        EntIterator_FireOne(src, self.ei_worker_ent);

    entity nxt = self.ei_worker_next;
    remove(self);

    if (nxt)
    {
        nxt.nextthink = time + src.delay_between_triggers;
        return;
    }

    // Chain exhausted — this pass is done.
    entity oldself = self;
    self = src;
    EntIterator_EndRun();
    self = oldself;
};

// One complete pass over the matched set.
void() EntIterator_RunPass =
{
    entity src = self;
    float paced = (src.delay_between_triggers > 0);
    entity head = world;
    entity tail = world;
    float n = 0;

    entity e = nextent(world);
    while (e)
    {
        if (EntIterator_Matches(src, e))
        {
            n = n + 1;
            if (!paced)
            {
                EntIterator_FireOne(src, e);
            }
            else
            {
                entity w = spawn();
                w.classname     = "ei_worker";
                w.owner         = src;
                w.ei_worker_ent = e;
                w.think         = EntIterator_StepWorker;
                w.nextthink     = 0;        // scheduled once the chain is built
                if (tail != world)
                    tail.ei_worker_next = w;
                else
                    head = w;
                tail = w;
            }
        }
        e = nextent(e);
    }

    if (cvar("sv_debug_use"))
        print(sprintf("[entity_iterator] \"%s\" matched %g\n", src.targetname, n));

    if (paced && head != world)
    {
        head.nextthink = time + src.delay_between_triggers;
        return;         // EndRun happens when the chain drains
    }

    EntIterator_EndRun();
};

void() EntIterator_EndRun =
{
    self.ei_runs = self.ei_runs + 1;

    if (self.trigger_after_run != "")
    {
        // Fire the after-run chain through a scratch entity so this iterator's
        // own delay / killtarget are not re-applied to it.
        entity t = spawn();
        t.classname = "ei_afterrun";
        t.target    = self.trigger_after_run;
        SUB_UseTargets(t, activator, USE_TOGGLE);
        remove(t);
    }

    // maximum_runs reached: Sven REMOVES the entity, it doesn't merely stop.
    if (self.maximum_runs > 0 && self.ei_runs >= self.maximum_runs)
    {
        remove(self);
        return;
    }

    if (self.run_mode == EI_RUN_TOGGLE && self.ei_running)
    {
        self.think     = EntIterator_RunPass;
        self.nextthink = time + (self.delay_between_runs > 0
                                 ? self.delay_between_runs : 0.5);
        return;
    }

    self.ei_running = 0;
};

void() trigger_entity_iterator_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    float ut = sub_use_type ? sub_use_type : USE_TOGGLE;

    if (self.run_mode == EI_RUN_TOGGLE)
    {
        // Toggle loop: On starts, Off stops, Toggle flips.
        float want;
        if (ut == USE_ON)       want = 1;
        else if (ut == USE_OFF) want = 0;
        else                    want = !self.ei_running;

        if (!want)
        {
            self.ei_running = 0;
            self.nextthink  = 0;
            return;
        }
        if (self.ei_running)
            return;             // already looping
        self.ei_running = 1;
        EntIterator_RunPass();
        return;
    }

    // Run-once modes.  Sven: re-triggering a running, non-multi-threaded
    // iterator restarts it on use-type On and stops it on anything else.
    if (self.ei_running && self.run_mode != EI_RUN_ONCE_MT)
    {
        self.ei_running = 0;
        self.nextthink  = 0;
        if (ut != USE_ON)
            return;
    }

    self.ei_running = 1;
    EntIterator_RunPass();
};

/*QUAKED trigger_entity_iterator (1 1 .2) (-12 -12 -12) (12 12 12)
Fires `target` once per matching entity, with each match as the !activator.

"name_filter"            only entities with this targetname
"classname_filter"       only entities of this classname (ANDed with the above)
"status_filter"          0 any / 1 only living / 2 only dead
"delay_between_triggers" seconds between individual fires (0 = all at once)
"target"                 entity fired per match
"triggerstate"           use-type sent to target: 0 off / 1 on / 2 toggle
"run_mode"               0 run once / 1 run once multi-threaded / 2 toggle loop
"trigger_after_run"      fired once at the end of each complete pass
"maximum_runs"           passes before the iterator REMOVES itself (0 = endless)
"delay_between_runs"     seconds between passes in toggle mode (default 0.5)

No spawnflags.
*/
void() trigger_entity_iterator =
{
    if (!self.delay_between_runs)
        self.delay_between_runs = 0.5;
    self.use = trigger_entity_iterator_use;
};

// ---------------------------------------------------------------------------
// game_player_equip — hands out weapons / ammo / items.
//
// The unusual part is how the item list is authored: there is NO fixed key.
// The mapper turns SmartEdit off and adds raw keyvalues where the KEY NAME is
// the classname to give and the VALUE is the quantity:
//
//     "weapon_crowbar" "1"     "ammo_9mmclip" "3"     "item_suit" "1"
//
// Those cannot be QC fields — `.string weapon_crowbar` collides with the
// weapon_crowbar() spawn function, because QC has one namespace for fields and
// functions.  They are harvested in ED_ParseUnknownEpair
// (sv_multi_manager.qc) onto a chain of child entities instead.
//
// CAVEAT: a few of these names ARE already real fields (.float ammo_357 from
// the .357, plus stock ammo_shells / ammo_nails / ammo_rockets / ammo_cells).
// Keys with those names bind to the field and never reach the hook, so they
// are silently ignored rather than given.
//
// th_ep1_00's single instance carries just "item_suit" "1", and this mod has
// no suit/armour system, so in practice it resolves nothing and simply passes
// its chain along.  The mechanism is here for the general case.
// ---------------------------------------------------------------------------
const float SF_GPE_USE_ONLY       = 1;
const float SF_GPE_FILTER_NAME    = 2;
const float SF_GPE_REEQUIP_ON_USE = 4;
const float SF_GPE_APPEND_MAP_CFG = 8;

void(entity gpe, entity plyr) GamePlayerEquip_Apply =
{
    if (!plyr || plyr.classname != "player")
        return;

    // Flag 2: only equip the player whose targetname matches `target`.
    if ((gpe.spawnflags & SF_GPE_FILTER_NAME)
        && gpe.target != "" && plyr.targetname != gpe.target)
        return;

    if (gpe.spawnflags & SF_GPE_REEQUIP_ON_USE)
        PlayerWeaponStrip_Apply(plyr);

    entity oldself = self;
    self = plyr;

    entity it = gpe.gpe_first_item;
    while (it)
    {
        // Strip the leading "weapon_" before the manifest lookup:
        // WeaponManifest_NameKey folds "weapon_crowbar" to "weaponcrowbar",
        // which it does not know — "crowbar" is the key it does.
        string nm = it.netname;
        if (substring(nm, 0, 7) == "weapon_")
            nm = substring(nm, 7, strlen(nm) - 7);

        float wid = Weapon_IdFromStringOrDefault(nm, WEP_NONE);
        if (wid != WEP_NONE)
            W_GiveWeaponToSlot(wid);
        else if (cvar("sv_debug_use"))
            print(sprintf("[game_player_equip] no weapon for \"%s\" (qty %g)"
                          " — ignored\n", it.netname, it.count));

        it = it.gpe_next_item;
    }

    self = oldself;
};

void() game_player_equip_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    GamePlayerEquip_Apply(self, activator);
    SUB_UseTargets(self, activator, USE_TOGGLE);
};

// Called from PlayerSpawn for the equip-on-respawn behaviour.  Skips USE-only
// instances, exactly as HL's CGamePlayerEquip::Touch does.
void(entity plyr) GamePlayerEquip_EquipSpawningPlayer =
{
    entity g = find(world, classname, "game_player_equip");
    while (g)
    {
        if (!(g.spawnflags & SF_GPE_USE_ONLY) && IsMasterTriggered(g.master, plyr))
            GamePlayerEquip_Apply(g, plyr);
        g = find(g, classname, "game_player_equip");
    }
};

/*QUAKED game_player_equip (.8 .4 0) (-8 -8 -8) (8 8 8) USE_ONLY FILTER_NAME REEQUIP_ON_USE APPEND_MAP_CFG
Gives weapons / ammo / items.  Add raw keyvalues (SmartEdit off) where the key
is the classname to give and the value is the quantity.

USE_ONLY (1):        only equip on a direct trigger, not on respawn.
FILTER_NAME (2):     only equip the player whose targetname matches "target".
REEQUIP_ON_USE (4):  strip the player first, then equip.
APPEND_MAP_CFG (8):  PARSED, NOT IMPLEMENTED.

"master"         gate
"equipmode"      PARSED, NOT IMPLEMENTED (0 give items / 1 modify inventory)
"inventorymode"  PARSED, NOT IMPLEMENTED

Only entries the weapon manifest recognises are handed out; anything else
(item_suit, item_battery, ammo_*) is ignored — there is no armour or standalone
ammo-pool system here.
*/
void() game_player_equip =
{
    self.use = game_player_equip_use;
};
