// server/sv_hl_entities.qc
// ----------------------------------------------------------------------------
// Half-Life point entities that had no spawn function here, ported from the SDK.
//
// Found by booting all 36 Sven hl_ maps headless and harvesting the engine's own
// "no spawn function for X" report, then cross-checking against a static parse of
// every entity lump.  Both passes agreed on the same set.
//
//   speaker        29 placements / 12 maps   dlls/sound.cpp:1813   CSpeaker
//   world_items    17 placements /  7 maps   dlls/items.cpp:42     CWorldItem
//
// Both were becoming invisible inert relays, which for `speaker` means every
// Black Mesa PA announcement in the campaign was simply absent.
// ----------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// speaker — CSpeaker (sound.cpp:1704-1950)
//
// The public-address system.  Picks a random line from a sentence GROUP every
// few minutes, or plays one specific sentence once, and can be switched on and
// off by a trigger.
//
// This is almost entirely wiring: the hard part is the sentence layer, and that
// already exists.  Sentences_Resolve (sv_sentences.qc:409) implements both
// reference forms HL's SpeakerThink branches on — a leading '!' means EXACTLY
// this sentence, anything else is a group name whose NAME0..NAME9 members are
// collected and one picked at random — so SENTENCEG_PlayRndSz and the '!'
// one-shot arm both come out of a single Sentences_Speak call.
// ---------------------------------------------------------------------------

// HL's SPEAKER_START_SILENT (sound.cpp).  Set = wait to be triggered instead of
// starting the announcement cycle on its own.
const float SPEAKER_START_SILENT = 1;

// ANNOUNCE_MINUTES_MIN / _MAX, sound.cpp:1852-1853.  Note these are MINUTES in
// the SDK and are multiplied by 60 at the point of use; 0.25..2.25 minutes is
// 15..135 seconds between announcements.
const float SPEAKER_ANNOUNCE_MIN = 15;
const float SPEAKER_ANNOUNCE_MAX = 135;

// m_preset -> sentence group prefix, sound.cpp:1874-1889.  A mapper who does not
// want to name a group can pick a chapter number and get that chapter's stock
// announcements.  Returned as the group name, so it flows into exactly the same
// lookup as an explicitly-named group.
string(float p) Speaker_PresetGroup =
{
    if (p == 1)  return "C1A0_";
    if (p == 2)  return "C1A1_";
    if (p == 3)  return "C1A2_";
    if (p == 4)  return "C1A3_";
    if (p == 5)  return "C1A4_";
    if (p == 6)  return "C2A1_";
    if (p == 7)  return "C2A2_";
    if (p == 8)  return "C2A3_";
    if (p == 9)  return "C2A4_";
    if (p == 10) return "C2A5_";
    if (p == 11) return "C3A1_";
    if (p == 12) return "C3A2_";
    return "";
};

void() speaker_think =
{
    string ref = self.preset ? Speaker_PresetGroup(self.preset) : self.message;
    if (ref == "" || !ref)
    {
        self.nextthink = 0;
        return;
    }

    // HL holds off while a talk monster is mid-line so the PA does not talk over
    // a scientist (sound.cpp:1866-1871, CTalkMonster::g_talkWaitTime).  The same
    // idea, expressed against our own sentence layer: if this speaker is still
    // saying its previous line, come back rather than cutting itself off.
    if (Sentences_Speaking(self))
    {
        self.nextthink = time + 5 + random() * 5;
        return;
    }

    // pev->health * 0.1 is HL's volume (sound.cpp:1857); attenuation is a flat
    // 0.3, which is deliberately wide — a PA announcement is meant to carry
    // across the room it is mounted in.
    float vol = self.health * 0.1;
    if (vol <= 0) vol = 1;
    if (vol > 1)  vol = 1;

    if (!Sentences_Speak(self, ref, CHAN_VOICE, vol, 0.3))
    {
        // HL prints "Level Design Error! SPEAKER has bad sentence group name".
        // Worth keeping: a speaker naming a group that the loaded sentences.txt
        // does not carry is silent in exactly the same way as one that is
        // working correctly and simply between announcements.
        dprint(sprintf("[speaker] \"%s\": no sentence or group \"%s\"\n",
                       self.targetname, ref));
        self.nextthink = 0;
        return;
    }

    // A '!' reference is ONE SPECIFIC SENTENCE and fires once, then shuts off
    // and waits to be triggered again (sound.cpp:1897-1903).  A group name
    // re-announces on the long timer.
    if (substring(ref, 0, 1) == "!")
        self.nextthink = 0;
    else
        self.nextthink = time + SPEAKER_ANNOUNCE_MIN
                       + random() * (SPEAKER_ANNOUNCE_MAX - SPEAKER_ANNOUNCE_MIN);
};

// ToggleUse, sound.cpp:1925-1950: if an announcement is pending, cancel it;
// otherwise start the cycle.  Honours an explicit ON/OFF rather than always
// flipping, which is what a multi_manager slot with a "#0"/"#1" suffix asks for.
void() speaker_use =
{
    float active = (self.nextthink > 0);
    float ut = sub_use_type;

    if (ut == USE_ON  && active)  return;
    if (ut == USE_OFF && !active) return;

    if (active)
        self.nextthink = 0;
    else
        self.nextthink = time + 0.1;
};

/*QUAKED speaker (0 .7 .7) (-8 -8 -8) (8 8 8) START_SILENT
Black Mesa public-address system.  Announces a random line from a sentence group
every 15-135 s, or one specific sentence when `message` starts with '!'.

"message"  sentence group name, or "!SENTENCE" for a one-shot
"preset"   1-12, picks a stock chapter group instead of naming one
"health"   volume x10 (so 10 = full)
START_SILENT (1)  don't start announcing until triggered
*/
void() speaker =
{
    // HL removes a speaker with neither a preset nor a message and logs an
    // error (sound.cpp:1827-1834).  Same here: it can never say anything, and
    // leaving it costs an edict plus a think for the rest of the map.
    if (!self.preset && (self.message == "" || !self.message))
    {
        dprint(sprintf("[speaker] at %v has no preset and no message - removed\n",
                       self.origin));
        remove(self);
        return;
    }

    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = speaker_use;
    self.think    = speaker_think;

    // First announcement 5-15 s in, unless the mapper asked for silence
    // (sound.cpp:1855-1859).  Note HL puts this in Precache, which runs AFTER
    // the nextthink = 0 in Spawn - so the ordering here is the SDK's, not a
    // rearrangement.
    if (self.spawnflags & SPEAKER_START_SILENT)
        self.nextthink = 0;
    else
        self.nextthink = time + 5 + random() * 10;
};

// ---------------------------------------------------------------------------
// world_items — CWorldItem (items.cpp:32-80)
//
// Half-Life 1.0's original item spawner, kept alive by the retail maps that were
// built before the item_* classnames existed.  It carries a `type` number and
// its whole job is to create the modern entity in its place and delete itself.
//
// 17 placements over 7 hl_ maps, and they are not decoration: type 45 is the HEV
// suit and type 43 is the security card, both of which gate progression.
// ---------------------------------------------------------------------------
.float type;    // the numeric item id.  Free to declare — nothing else in this
                // tree claims that spelling, checked before adding it.

/*QUAKED world_items (0 .5 0) (-16 -16 0) (16 16 32)
Legacy Half-Life item spawner.  Replaces itself with the item named by `type`.

"type"  42 = item_antidote, 43 = item_security, 44 = item_battery, 45 = item_suit
*/
void() world_items =
{
    string cls = "";
    if      (self.type == 42) cls = "item_antidote";
    else if (self.type == 43) cls = "item_security";
    else if (self.type == 44) cls = "item_battery";
    else if (self.type == 45) cls = "item_suit";

    if (cls == "")
    {
        // HL: ALERT(at_console, "unable to create world_item %d\n", m_iType).
        dprint(sprintf("[world_items] unknown type %g at %v - removed\n",
                       self.type, self.origin));
        remove(self);
        return;
    }

    // BECOME the item rather than spawning a second entity and removing this
    // one.  HL creates a new edict because CBaseEntity::Create is the only tool
    // it has; here the classname and the spawn function are the same dispatch,
    // so re-entering as the target class keeps the origin, the angles and any
    // targetname the mapper set — and costs no extra edict.
    self.classname = cls;
    if      (self.type == 42) item_antidote();
    else if (self.type == 43) item_security();
    else if (self.type == 44) item_battery();
    else                      item_suit();
};

// ---------------------------------------------------------------------------
// func_mortar_field / monster_mortar — CFuncMortarField + CMortar (mortar.cpp)
//
// "the LaBuznik mortar device", per the file's own header.  A brush volume that,
// when triggered, drops a salvo of shells somewhere inside its own footprint.
// Eight placements over two maps and both are set pieces:
//
//   hl_c04       six fields, all m_fControl 1 (aim at whoever pulled the
//                trigger), m_iCount 3, m_flSpread 128 — the Surface Tension
//                barrage that is supposed to walk shells onto the player as they
//                cross the dam.
//   hl_c11_a5    `random_mortar` (control 0, spread 180) and `mortars`
//                (control 2, count 6, spread 96) driven from a pair of
//                momentary_rot_buttons the player aims by hand.
//
// Without a spawn function every one of these was an inert relay: the triggers
// still fired, and nothing ever came down.
// ---------------------------------------------------------------------------
.string m_iszXController;
.string m_iszYController;
.float  m_flSpread;
.float  m_iCount;
.float  m_fControl;

const float MORTAR_SHELL_DAMAGE = 200;      // CMortar::Spawn, mortar.cpp:210
const string MORTAR_BEAM_SPRITE = "sprites/lgtning.spr";

// CMortar::MortarExplode, mortar.cpp:226-281.
void() monster_mortar_explode =
{
    entity atk;
    vector hit;

    // The 1024-unit column of light that IS the shell, mortar.cpp:230-249.
    // TE_BEAMPOINTS with lgtning.spr, life 1 (tenths, so 0.1 s), width 40
    // (tenths, so 4 units), colour 255 160 100 at brightness 128.
    HLBeam_EntFlash(self, self.origin, self.origin + '0 0 1024',
                    getmodelindex(MORTAR_BEAM_SPRITE),
                    '1 0.627 0.392', 128, 4, 0, 0, 0.1, 0);

    // mortar.cpp:277 traces 1024 up to 1024 down through monsters and detonates
    // at the result, so a shell that spawned a little inside the ceiling still
    // lands on the floor rather than in the brush.
    traceline(self.origin + '0 0 1024', self.origin - '0 0 1024', MOVE_NORMAL, self);
    hit = trace_endpos;

    atk = self.owner;
    if (atk.classname != "player")
        atk = world;

    HL_ExplosionCreate(hit, MORTAR_SHELL_DAMAGE, atk);

    // mortar.cpp:280, immediately after the Explode above.  This was the gap
    // the old comment here deferred ("left out rather than faked so the gap
    // stays in one place and gets fixed once") — the shake channel now exists,
    // so this is that once.
    //
    // Note 25.0 exceeds HL's own 4.12 fixed-point ceiling and is clamped to
    // 15.9998 on the wire, which is what a Half-Life player feels too; see
    // ShakeQuantise412 in sv_screenshake.qc.
    SV_ScreenShake(hit, 25.0, 150.0, 1.0, 750);

    remove(self);
};

/*QUAKED monster_mortar (1 .5 0) (-8 -8 -8) (8 8 8)
One incoming mortar shell.  Created by func_mortar_field, never placed by hand
in the corpus — but it is a real classname in Half-Life and a map may use it.
Detonates on its first think; set nextthink to schedule the impact.
*/
void() monster_mortar =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.dmg      = MORTAR_SHELL_DAMAGE;
    self.think    = monster_mortar_explode;
    // mortar.cpp:213 leaves nextthink at 0 for the field to fill in.  A shell
    // placed by a mapper with no scheduler would then never go off, so a
    // hand-placed one detonates on the next frame instead.
    if (self.nextthink <= 0)
        self.nextthink = time + 0.1;
};

// CFuncMortarField::FieldUse, mortar.cpp:122-189.
void() mortar_field_use =
{
    vector  start;
    vector  spot;
    vector  fsize;
    entity  ctrl;
    entity  shell;
    float   i;
    float   t;

    // HL reads pev->mins / pev->maxs / pev->size.  For a GoldSrc brush entity
    // compiled without an origin brush — which all eight of these are — origin
    // is (0 0 0) and those ARE the absolute bounds.  absmin/absmax is the same
    // number on those and the right one on a brush that does carry an origin,
    // so it is what gets read here.  Same hazard sv_momentary.qc:503-514 and
    // sh_weapon_standard.qc:759 both document.
    fsize = self.absmax - self.absmin;
    start_x = self.absmin_x + random() * fsize_x;
    start_y = self.absmin_y + random() * fsize_y;
    start_z = self.absmax_z;

    if (self.m_fControl == 1)
    {
        // "Trigger Activator" — walk the salvo onto whoever set it off.
        if (activator && activator != world)
        {
            start_x = activator.origin_x;
            start_y = activator.origin_y;
        }
    }
    else if (self.m_fControl == 2)
    {
        // "table": a pair of momentary_rot_buttons the player turns to aim.
        // HL reads pController->pev->ideal_yaw, which CMomentaryRotButton
        // publishes as its 0..1 travel fraction (buttons.cpp:989).  This tree
        // spells that fraction .momentary_frac (sv_momentary.qc:521-532) — same
        // value, different field, because ideal_yaw here is an engine field the
        // AI already uses for facing.
        if (self.m_iszXController != "")
        {
            ctrl = find(world, targetname, self.m_iszXController);
            if (ctrl)
                start_x = self.absmin_x + ctrl.momentary_frac * fsize_x;
        }
        if (self.m_iszYController != "")
        {
            ctrl = find(world, targetname, self.m_iszYController);
            if (ctrl)
                start_y = self.absmin_y + ctrl.momentary_frac * fsize_y;
        }
    }

    // mortar.cpp:165-167.  ATTN_NONE: the launch report is meant to be heard
    // across the whole map, not just inside the field.
    sound(self, CHAN_VOICE, "weapons/mortar.wav", 1, ATTN_NONE,
          floor(95 + random() * 30));

    // mortar.cpp:169-188.  First shell lands 2.5 s after the launch report, the
    // rest at 0.2-0.5 s intervals after that — which is what makes a salvo
    // readable as "run" rather than as one large bang.
    t = 2.5;
    for (i = 0; i < self.m_iCount; i = i + 1)
    {
        spot = start;
        spot_x = spot_x + (random() - 0.5) * 2 * self.m_flSpread;
        spot_y = spot_y + (random() - 0.5) * 2 * self.m_flSpread;

        // ignore_monsters, mortar.cpp:177 — the shell aims at the GROUND, not at
        // the first head under it.
        traceline(spot, spot - '0 0 4096', MOVE_NOMONSTERS, self);

        shell = spawn();
        shell.classname = "monster_mortar";
        shell.movetype  = MOVETYPE_NONE;
        shell.solid     = SOLID_NOT;
        shell.dmg       = MORTAR_SHELL_DAMAGE;
        setorigin(shell, trace_endpos);
        // pentOwner is the activator (mortar.cpp:180-182), so a player who
        // triggered the barrage owns the kills it makes.
        shell.owner     = activator;
        shell.think     = monster_mortar_explode;
        shell.nextthink = time + t;
        // NOT `monster_mortar()`.  A QC spawn function operates on `self`, and
        // self here is the FIELD — calling it would turn the mortar field
        // itself into a shell and detonate it.  The four lines above are that
        // function's whole body anyway.

        t = t + 0.2 + random() * 0.3;
    }

    if (cvar("sv_debug_use"))
        dprint(sprintf("[mortar_field] \"%s\" control=%g: %g shell(s) around %v, spread %g, last impact +%gs\n",
                       self.targetname, self.m_fControl, self.m_iCount,
                       start, self.m_flSpread, t - 0.2));
};

/*QUAKED func_mortar_field (1 .5 0) ?
Brush volume that rains mortar shells inside its own footprint when triggered.

"m_iCount"          shells per salvo
"m_flSpread"        random scatter about the aim point, in units
"m_fControl"        0 random inside the volume / 1 onto the activator /
                    2 aimed by the m_iszXController + m_iszYController pair
"m_iszXController"  momentary_rot_button whose 0..1 fraction picks X
"m_iszYController"  ditto for Y
*/
void() func_mortar_field =
{
    precache_sound("weapons/mortar.wav");
    precache_sound("weapons/mortarhit.wav");
    precache_model(MORTAR_BEAM_SPRITE);
    Tank_PrecacheExplosion();

    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    setmodel(self, self.model);     // mortar.cpp:105 — sets size and links it in
    self.modelindex = 0;            // EF_NODRAW: the volume is never drawn
    self.use      = mortar_field_use;
};

// ---------------------------------------------------------------------------
// trigger_setcvar — Sven Co-op only (no HL SDK equivalent)
//
// Lets a map change a server cvar when triggered.  69 placements over 10 maps,
// which is far more than the five hl_ ones that put it on this list:
// ctf_warforts sets nine at map start, polar_rescue picks a difficulty by
// setting eleven, mommamesa maps its skill menu straight onto `skill`, and
// deadsimpleneo2 and toadsnatch each rewrite all thirteen sk_player_* hitgroup
// multipliers.  Every one of them was doing nothing.
//
// THE ALLOWLIST IS THE ENTITY.  sven-coop.fgd:6705-6761 does not offer a free
// text box — m_iszCVarToChange is a `choices` list of 54 exact names plus the
// `sk_` prefix, and that bound is the whole reason a map is allowed to touch
// server state at all.  It is transcribed verbatim below and nothing is added
// to it, so a map cannot reach a cvar Sven would not have let it reach.
//
// TWO KEYS CARRY THE VALUE.  The FGD documents `message`, and that is what nine
// of the ten maps write; deadsimpleneo2 and toadsnatch write `m_iszNewValue`
// instead, from a newer editor.  Both are read, message first.  Neither present
// means the value is "0" — which is not a quirk but the common case, because
// `flashlightoff`, `noflashlight`, `mp_weaponstay` off and `mp_npckill` off are
// all spelled by leaving the box empty.
// ---------------------------------------------------------------------------
.string m_iszCVarToChange;

// sven-coop.fgd:6707-6760, in the FGD's own order.  Space-delimited and
// space-padded at both ends so a substring search is an exact token match:
// searching for " mp_flashlight " cannot hit "mp_flashlight_extra".
const string TSC_ALLOWLIST =
" mp_allowmonsterinfo mp_allowplayerinfo mp_ammo_droprules mp_ammo_respawndelay"
" mp_banana mp_barnacle_paralyze mp_disable_autoclimb mp_disable_medkit_points"
" mp_disable_pcbalancing mp_disable_player_rappel mp_disablegaussjump"
" mp_dropweapons mp_falldamage mp_flashlight mp_footsteps mp_forcerespawn"
" mp_fraglimit mp_grapple_mode mp_hevsuit_voice mp_item_respawndelay"
" mp_monsterpoints mp_multiplespawn mp_no_akimbo_uzis mp_noblastgibs"
" mp_nomedkit mp_npckill mp_observer_cyclic mp_observer_mode"
" mp_pcbalancing_factorlist mp_respawndelay mp_suitpower mp_survival_nextmap"
" mp_survival_startdelay mp_survival_starton mp_survival_supported"
" mp_survival_voteallow mp_telefrag mp_timelimit mp_weapon_droprules"
" mp_weapon_respawndelay mp_weaponstay npc_dropweapons skill sv_accelerate"
" sv_ai_enemy_detection_mode sv_airaccelerate sv_friction sv_gravity"
" sv_maxspeed sv_maxvelocity sv_wateraccelerate sv_waterfriction ";

float(string nm) TriggerSetCvar_Allowed =
{
    if (nm == "" || !nm)
        return FALSE;
    // "sk_*  (see skill.cfg)" — the one wildcard entry in the list.
    if (substring(nm, 0, 3) == "sk_")
        return TRUE;
    return (strstrofs(TSC_ALLOWLIST, strcat(" ", nm, " ")) >= 0);
};

void() trigger_setcvar_use =
{
    string val;

    if (!TriggerSetCvar_Allowed(self.m_iszCVarToChange))
    {
        dprint(sprintf("[trigger_setcvar] \"%s\" refused: \"%s\" is not on the FGD allowlist\n",
                       self.targetname, self.m_iszCVarToChange));
        return;
    }

    val = self.message;
    if (val == "" || !val)
        val = self.m_iszNewValue;
    if (val == "" || !val)
        val = "0";

    // cvar_set rather than a `set` localcmd: it takes effect on this frame, so a
    // trigger_setcvar fired from a game_playerspawn multi_manager has already
    // changed the rules before the entities it shares that manager with read
    // them.  A name the allowlist permits but this mod has not implemented is a
    // no-op with a note, not an error — the allowlist is Sven's and covers
    // cvars we may add later.
    cvar_set(self.m_iszCVarToChange, val);

    if (cvar_string(self.m_iszCVarToChange) != val)
        dprint(sprintf("[trigger_setcvar] \"%s\" -> %s \"%s\": not implemented here\n",
                       self.targetname, self.m_iszCVarToChange, val));
    else if (cvar("sv_debug_use"))
        dprint(sprintf("[trigger_setcvar] %s = \"%s\"\n",
                       self.m_iszCVarToChange, val));

    // "Trigger after set" (sven-coop.fgd:6763).  Fired AFTER the write so
    // whatever it wakes up reads the new value.
    if (self.netname != "")
        SV_FireTargetsByName(self.netname, activator, USE_TOGGLE);
};

// ---------------------------------------------------------------------------
// env_funnel — CEnvFunnel (effects.cpp:2094-2141)
//
// The whole class is: write TE_LARGEFUNNEL, then delete yourself.  The visual
// lives in shared/sh_envfunnel.qc; this is the trigger wiring and nothing else.
//
// Four placements over three maps, all with SF_FUNNEL_REVERSE set:
// hl_c01_a2 "funnel"/"funnel2", hl_c13_a4 "end_funnel", hl_c17
// "c3a2d_particles".
// ---------------------------------------------------------------------------
void() env_funnel_use =
{
    EnvFunnel_Multicast(self.origin, self.spawnflags & FUNNEL_SF_REVERSE);

    // effects.cpp:2132-2133 — SetThink(SUB_Remove) at gpGlobals->time, i.e. it
    // is a ONE-SHOT.  Firing it twice is a mapper error in Half-Life too, and
    // hl_c01_a2's pair are each fired exactly once by a multi_manager.
    self.think     = SUB_Remove;
    self.nextthink = time;
};

/*QUAKED env_funnel (.4 .6 1) (-8 -8 -8) (8 8 8) REVERSE
One-shot cloud of flares converging on this point (or flying out from it).
Removes itself after firing, exactly as Half-Life does.

REVERSE (1)  particles fly outward from the point instead of inward
*/
void() env_funnel =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = env_funnel_use;
};

/*QUAKED trigger_setcvar (.6 .2 .6) (-8 -8 -8) (8 8 8)
Sets one server cvar when triggered.  The cvar must be on Sven's own allowlist
(sven-coop.fgd:6705-6760): 54 named cvars plus anything starting "sk_".

"m_iszCVarToChange"  which cvar
"message"            the new value ("" = "0")
"m_iszNewValue"      alternative spelling of the same thing, newer editors
"netname"            fired after the value has been written
*/
void() trigger_setcvar =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.use      = trigger_setcvar_use;
};

// ---------------------------------------------------------------------------
// info_bigmomma — CInfoBM (bigmomma.cpp:33-96)
//
// A patrol node for the gonarch, and one of the shortest classes in the SDK:
// CInfoBM::Spawn is an EMPTY FUNCTION.  It is pure data — the monster reads the
// keys off it and it never thinks, moves, draws or is touched.  All the
// behaviour lives in monsters/mon_bosses.qc, and the key fields are declared up
// in sv_ai_defs.qc because that file compiles before both of us.
//
// 22 placements, all on hl_c15, and they are that map: the chain runs
// goose1 -> goose1b -> goose1c -> goose2 -> goose3 -> goose4 -> goose5 ->
// goose5b -> goose5c -> goose6 -> goose7 -> goose7b -> goose8 -> goose8b ->
// goose9 -> goose10 -> goose11 -> goose11b -> goose12 -> goose13 -> goose14 ->
// end, and nine of those carry a `health` key that gates the player's progress.
//
// SOLID_NOT AND MOVETYPE_NONE, spelled out rather than left to default, for the
// reason momentary_rot_button's note gives: a nonsolid entity that is never
// found by anything except find() needs no FL_FINDABLE_NONSOLID, and stating
// the two fields is what makes that a decision rather than an omission.
// ---------------------------------------------------------------------------

/*QUAKED info_bigmomma (.2 .8 .3) (-24 -24 0) (24 24 16) RUN WAIT
One stop on monster_bigmomma's patrol.  Seed the chain by putting this node's
targetname in the gonarch's own "netname" key; each node then names the next in
"target".  A node with no target ends the path, which is also what finally makes
her killable.

"target"         the next node
"radius"         how close she must get before this node counts as reached
"reachdelay"     seconds to hold here after arriving
"reachtarget"    fired on arrival (or early, if the sequence has an event 50)
"reachsequence"  big_mom.mdl sequence played at the node (claw, breakwall, jump)
"presequence"    sequence played before she sets off for it (angry1/2/3)
"health"         her health for this stage; she cannot pass until it is spent
"angles"         the yaw she faces on arrival; 0 keeps her current facing

RUN  (1)  run to this node instead of walking
WAIT (2)  hold here indefinitely once reached
*/
void() info_bigmomma =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
};
