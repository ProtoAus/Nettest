// ===========================================================================
//  sv_weapondebugcmds.qc — the server half of the F5 weapon panel
// ===========================================================================
//
// Three client commands, all gated on mp_cheats, all reached from
// SV_ParseClientCommand via the WepDbg_Command dispatcher.  The shape is
// copied from server/sv_ai_debugcmds.qc, which does the same job for monsters.
//
//   cmd wep_give  <id|name>       put the weapon in the player's hands
//   cmd wep_spawn <id|name> [n]   drop n pickups on the floor in front of them
//   cmd wep_strip                 take everything away
//
// COMPILE POSITION.  This file sits immediately AFTER server/sv_player.qc,
// because it calls W_GiveWeaponToSlot, SV_DebugSpawnWeaponId and
// SV_DebugWeaponOrigin, all of which live there.  SV_ParseClientCommand is
// also in sv_player.qc, so the dispatcher is forward-declared there and
// defined here - the mirror image of how sv_ai_debugcmds.qc does it (that
// file compiles BEFORE sv_player.qc and needs no declaration).
//
// The gate is checked per command rather than once, so flipping mp_cheats
// takes effect immediately - same rule as AIDbg_Allowed.

float(entity p) WepDbg_Allowed =
{
    if (cvar("mp_cheats"))
        return TRUE;
    sprint(p, PRINT_HIGH, "weapon debug commands need mp_cheats 1\n");
    return FALSE;
};

// ---------------------------------------------------------------------------
//  Classname -> spawn function, for the GoldSrc/Sven aliases ONLY
// ---------------------------------------------------------------------------
// SV_DebugSpawnWeaponId dispatches by WEAPON ID and structurally cannot express
// these: all 16 collapse onto 11 existing ids and differ only in the world
// model.  "weapon_tommygun" and "weapon_m16a1" are both WEP_HLSMG, so an
// id-keyed spawn can only ever produce one of the two models.
//
// QC has no call-by-name, so this is an explicit chain - the same shape as
// Breakable_ObjectName / Breakable_SpawnObject in sv_goldsrc_ammo.qc, and for
// the same reason.  Returns TRUE if it handled the name.
//
// The nine plain GoldSrc names (weapon_shotgun, weapon_9mmAR, weapon_mp5, ...)
// are deliberately absent: they are name-only aliases that spawn the mod's own
// model, so the id path already produces an identical pickup.
float(vector org, string cls) SV_DebugSpawnWeaponClass =
{
    // THE TACTICAL SHIELD IS NOT A MANIFEST WEAPON.  It is equipment — no slot,
    // no WEP_ id, nothing for SV_DebugSpawnWeaponId to dispatch on — so it can
    // only ever reach the bench through this classname table.  That is also why
    // the F5 panel lists it separately rather than in a slot tab.
         if (cls == "weapon_shield")       SV_DebugSpawnWeapon(org, weapon_shield);
    else if (cls == "weapon_tommygun")     SV_DebugSpawnWeapon(org, weapon_tommygun);
    else if (cls == "weapon_m16a1")        SV_DebugSpawnWeapon(org, weapon_m16a1);
    else if (cls == "weapon_m16")          SV_DebugSpawnWeapon(org, weapon_m16);
    else if (cls == "weapon_greasegun")    SV_DebugSpawnWeapon(org, weapon_greasegun);
    else if (cls == "weapon_uzi")          SV_DebugSpawnWeapon(org, weapon_uzi);
    else if (cls == "weapon_uziakimbo")    SV_DebugSpawnWeapon(org, weapon_uziakimbo);
    else if (cls == "weapon_sawedoff")     SV_DebugSpawnWeapon(org, weapon_sawedoff);
    else if (cls == "weapon_colt1911")     SV_DebugSpawnWeapon(org, weapon_colt1911);
    else if (cls == "weapon_m14")          SV_DebugSpawnWeapon(org, weapon_m14);
    else if (cls == "weapon_sniperrifle")  SV_DebugSpawnWeapon(org, weapon_sniperrifle);
    else if (cls == "weapon_pipewrench")   SV_DebugSpawnWeapon(org, weapon_pipewrench);
    else if (cls == "weapon_spanner")      SV_DebugSpawnWeapon(org, weapon_spanner);
    else if (cls == "weapon_teslagun")     SV_DebugSpawnWeapon(org, weapon_teslagun);
    else if (cls == "weapon_minigun")      SV_DebugSpawnWeapon(org, weapon_minigun);
    else if (cls == "weapon_sporelauncher") SV_DebugSpawnWeapon(org, weapon_sporelauncher);
    // weapon_penguin has LEFT this table.  It is a real manifest weapon now
    // (WEP_PENGUIN), so the id path spawns it and the F5 panel lists it in the
    // Utility tab; keeping a row here would offer it twice.  The same is true of
    // weapon_knife and weapon_m249, which are real manifest weapons too and are
    // deliberately absent for the same reason.
    else
        return FALSE;
    return TRUE;
};

// ---------------------------------------------------------------------------
//  cmd wep_give <id|name>
// ---------------------------------------------------------------------------
void(entity p, string tok) WepDbg_Give =
{
    if (p.classname != "player" || p.health <= 0)
    {
        sprint(p, PRINT_HIGH, "wep_give: must be alive\n");
        return;
    }

    // Equipment first, because it is not in the manifest and the id lookup
    // below would reject it.  The shield is granted the same way the buy menu
    // grants it (sv_money.qc's BUYITEM_SHIELD arm), including the rule that it
    // cannot coexist with a two-handed weapon: whatever is in the primary slot
    // is dropped, exactly as taking one off the floor would.
    if (tok == "shield" || tok == "weapon_shield" || tok == "wepshield")
    {
        if (p.has_shield)
        {
            sprint(p, PRINT_HIGH, "you already have a Tactical Shield\n");
            return;
        }
        entity ssaved = self;
        self = p;
        // Force-drop the primary rather than refusing.  The buy menu refuses
        // (sv_money.qc) because a mis-click there costs $2200; this is the
        // bench, its own bottom bar already says "equip: the old gun drops at
        // your feet", and refusing here would leave the click doing nothing
        // visible.  Without it the shield lands and W_WeaponFrame's backstop
        // drops it again on the very next frame.
        if (p.slot_primary != WEP_NONE)
        {
            float pv = p.slot_primary;
            W_DropSlotForBuy(0, pv, p.slot_primary_drop);
            W_CarryRemove(p, SLOT_PRIMARY, pv);
        }
        p.has_shield      = TRUE;
        p.shield_deployed = FALSE;
        // If the hand is still holding something two-handed, put the knife up —
        // SH_ShieldAllowsWeapon covers pistols, the knife and grenades, and the
        // melee slot is the one thing every player always has.
        if (!SH_ShieldAllowsWeapon(p.weapon) && p.slot_melee != WEP_NONE)
            W_SelectWeapon(p.slot_melee);
        self = ssaved;
        sound(p, CHAN_ITEM, "items/gunpickup2.wav", 1, ATTN_NORM);
        sprint(p, PRINT_HIGH, "gave Tactical Shield\n");
        return;
    }

    // Accepts a numeric id OR any alias key, via the manifest's own table.
    float id = Weapon_IdFromStringOrDefault(tok, WEP_NONE);
    if (id == WEP_NONE || id < 1 || id > WMF_WEP_LAST)
    {
        sprint(p, PRINT_HIGH, sprintf("wep_give: no such weapon \"%s\"\n", tok));
        return;
    }

    // W_GiveWeaponToSlot works on self and drops whatever is already in the
    // slot as a world pickup, which is why repeated use litters the floor.
    entity saved = self;
    self = p;
    W_GiveWeaponToSlot(id);
    self = saved;

    sprint(p, PRINT_HIGH, sprintf("gave %s\n", WeaponManifest_MenuName(id)));
};

// ---------------------------------------------------------------------------
//  Placement for the SPAWN button
// ---------------------------------------------------------------------------
// "it actually just picks a direction 64~units away from the player" — and it
// did, for two independent reasons.
//
// 1. THE ARITHMETIC.  SV_DebugWeaponOrigin (sv_player.qc:621) offsets by
//    v_right * ((col - 2.5) * 48), hard-centring a row on a phantom column 2.5
//    of a five-wide grid.  The panel defaults to ONE item, which is row 0 col 0,
//    so the single pickup went v_forward*64 - v_right*120: 136 units away at 62
//    degrees off the facing axis.  Only a count of exactly 5 or 10 ever came out
//    centred on the player, which is why the button looked random.
//
// 2. THE BASIS.  makevectors(p.angles) is not the player's view.  The engine
//    stamps angles[PITCH] = r_meshpitch * v_angle[PITCH]/3 and angles[ROLL] =
//    V_CalcRoll(...)*4 (fteqw engine/server/sv_user.c:7655-7659), so the basis
//    carries a THIRD of the view pitch with the sign flipped, plus up to eight
//    degrees of strafe roll.  It is also skipped entirely while .fixangle is set
//    and while dead, so it can be a stale spawnpoint angle.  v_angle is the view;
//    .angles is the model pose, and they were never the same thing.
//
// And there was no trace of any kind: the item was setorigin'd at the player's
// bbox CENTRE, 36 units up, so it was born at chest height and could be born
// inside a wall — where W_PhysDropThink (sv_weapons.qc:2939) silently deletes it
// two seconds later.  That is the "refuses to spawn" with nothing said.
//
// SV_DebugWeaponOrigin is deliberately left alone: it still has two non-player-
// facing callers (sv_player.qc:4377's spawn grid, sv_main.qc:2274's alias
// self-test), and this keeps the change to the F5 path.

// Widest pickup hull in the tree: 91 of 110 weapon_*() spawn functions use
// exactly this and the rest are smaller, and EVERY one has mins_z 0 — so an
// origin whose Z is the floor puts the box ON the floor.  SV_DebugSpawnWeapon
// still runs W_PhysDropGroundSnap afterwards with the entity's real hull; this
// only has to land the weapon somewhere sane and reachable.
const vector WEPDBG_HULL_MINS = '-16 -16 0';
const vector WEPDBG_HULL_MAXS = '16 16 48';

vector wepdbg_ground;        // out-param of WepDbg_GroundUnder
string wepdbg_place_note;    // why it ended up where it did, for the sprint

// Find the floor under `at` and confirm the pickup hull fits standing on it.
//
// The DESCENT is a box trace, not a point trace, and that matters: a point
// trace's endpos on a step or a ramp leaves the 32x32 box clipping the
// neighbouring riser, and a fit test at that point then rejects a spot that is
// visually perfect — dumping the weapon back at the player's feet, which is the
// same failure being fixed.  Box-tracing down rests it on its highest contact.
//
// MOVE_NOMONSTERS deliberately: world and brush entities are what we want to
// stand on, and dropped weapons are SOLID_TRIGGER so they are ignored anyway.
float(entity p, vector at) WepDbg_GroundUnder =
{
    vector low = at;
    low_z = at_z - 512;
    tracebox(at, WEPDBG_HULL_MINS, WEPDBG_HULL_MAXS, low, MOVE_NOMONSTERS, p);
    if (trace_startsolid || trace_allsolid || trace_fraction >= 1)
        return FALSE;
    wepdbg_ground = trace_endpos + '0 0 1';   // 1 u clearance, as W_PhysDropGroundSnap uses
    return TRUE;
};

vector(entity p, float idx, float n) WepDbg_PlaceOrigin =
{
    // FLATTENED view yaw.  Pitch is dropped on purpose — looking at the ceiling
    // should still put the crate in front of you, not launch it upwards.
    makevectors([0, p.v_angle_y, 0]);
    vector fwd = v_forward, right = v_right;

    vector eye = p.origin + p.view_ofs;

    // Centre each row on the ACTUAL count in that row.
    float row    = floor(idx / 5);
    float col    = idx - row * 5;
    float in_row = n - row * 5;
    if (in_row > 5) in_row = 5;
    if (in_row < 1) in_row = 1;
    float lat  = (col - (in_row - 1) * 0.5) * 40;
    float dist = 72 + row * 56;   // 72 clears the +/-16 player hull and the +/-16 pickup

    // 1. Sightline forward from the eye, and back off any impact so the hull is
    //    not left kissing the plane it just hit.
    vector want = eye + fwd * dist + right * lat;
    traceline(eye, want, MOVE_NOMONSTERS, p);
    vector spot = trace_endpos;
    wepdbg_place_note = "in front of you";
    if (trace_startsolid)
    {
        spot = eye;
        wepdbg_place_note = "at your feet - no clear line in front";
    }
    else if (trace_fraction < 1)
    {
        spot = spot - normalize(want - eye) * 24;
        wepdbg_place_note = "just short of the wall in front of you";
    }

    // 2. Sit it on the floor under that spot.
    if (WepDbg_GroundUnder(p, spot))
        return wepdbg_ground;

    // 3. Ledge, pit or lift shaft — try half way back before giving up on "in front".
    if (WepDbg_GroundUnder(p, eye + (spot - eye) * 0.5))
    {
        wepdbg_place_note = "part-way in front of you - no floor further out";
        return wepdbg_ground;
    }

    // 4. NEVER refuse.  The player is standing on something by definition, so
    //    there is always an answer; the only question is how good it is.
    if (WepDbg_GroundUnder(p, eye))
    {
        wepdbg_place_note = "at your feet - nothing to stand on in front";
        return wepdbg_ground;
    }
    wepdbg_place_note = "at your feet";
    vector feet = p.origin;
    feet_z = p.origin_z + p.mins_z + 1;
    return feet;
};

// ---------------------------------------------------------------------------
//  cmd wep_spawn <id|name> [n]
// ---------------------------------------------------------------------------
void(entity p, string tok, float n) WepDbg_Spawn =
{
    if (p.classname != "player")
        return;

    n = bound(1, n, 10);

    // RESOLUTION ORDER IS LOAD-BEARING: classname FIRST, id second.
    // WeaponManifest_IdFromKey maps "uzi" -> WMF_WEP_CFMAC10, so resolving the
    // id first would turn every alias into its underlying weapon and hand back
    // the stock model - defeating the entire point of asking for the alias.
    float id = Weapon_IdFromStringOrDefault(tok, WEP_NONE);

    entity saved = self;
    makevectors(p.angles);

    // Same bracket PlayerSpawn's debug grid uses (sv_player.qc:3266/3281).
    // W_RegisterMapWeapon early-returns while this is set; without it a
    // debug-spawned weapon registers as a MAP weapon and respawns at every
    // round restart forever.
    sv_debug_weapon_spawning = TRUE;

    float i, made = 0, nospawn = 0;
    for (i = 0; i < n; i = i + 1)
    {
        vector org = WepDbg_PlaceOrigin(p, i, n);

        if (SV_DebugSpawnWeaponClass(org, tok))
            made = made + 1;
        else if (id != WEP_NONE && id >= 1 && id <= WMF_WEP_LAST)
        {
            // COUNTING THE RANGE CHECK AS A SPAWN WAS A LIE.
            // SV_DebugSpawnWeaponId (sv_player.qc:626) is a bare else-if chain
            // with no terminal else, so an in-range id with no branch — fists,
            // the binoculars — creates nothing at all while the player is still
            // told "spawned 1 x <name>" and goes looking for it.  That is the
            // exact symptom the three warnings inside that chain describe.
            //
            // Detected from the handle the spawner publishes unconditionally at
            // sv_player.qc:616, the same idiom as sv_goldsrc_ammo.qc:1011.
            sv_last_spawned_weapon = world;
            SV_DebugSpawnWeaponId(org, id);
            if (sv_last_spawned_weapon != world)
                made = made + 1;
            else
                nospawn = nospawn + 1;
        }
    }

    sv_debug_weapon_spawning = FALSE;
    self = saved;

    // Say what happened AND where — the panel's own bottom bar promises "pickups
    // land in front of you", so when they cannot, the player should hear why
    // rather than hunt the floor.  A partial success still reports its count.
    if (made)
        sprint(p, PRINT_HIGH, sprintf("spawned %g x %s (%s)\n",
                                      made, tok, wepdbg_place_note));
    else if (nospawn)
        sprint(p, PRINT_HIGH, sprintf("wep_spawn: %s has no world pickup - use wep_give\n",
                                      WeaponManifest_MenuName(id)));
    else
        sprint(p, PRINT_HIGH, sprintf("wep_spawn: no such weapon \"%s\"\n", tok));
};

// ---------------------------------------------------------------------------
//  Dispatcher
// ---------------------------------------------------------------------------
float(entity p, string cmd) WepDbg_Command =
{
    if (cmd == "wep_give")
    {
        if (WepDbg_Allowed(p)) WepDbg_Give(p, argv(1));
        return TRUE;
    }
    if (cmd == "wep_spawn")
    {
        if (WepDbg_Allowed(p)) WepDbg_Spawn(p, argv(1), stof(argv(2)));
        return TRUE;
    }
    if (cmd == "wep_strip")
    {
        if (WepDbg_Allowed(p)) PlayerWeaponStrip_Apply(p);
        return TRUE;
    }
    return FALSE;
};
