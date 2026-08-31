//
//  sv_mapcfg_equip.qc  –  the equipment block of Sven Co-op's maps/<name>.cfg
//
//  SV_ApplyConfigFile (sv_main.qc) is a cvar parser, which is the right shape
//  for the ~40 mp_*/sv_* tuning values a map cfg carries.  But a Sven map cfg
//  is TWO languages sharing one file, and the other half is an equipment
//  manifest that has nothing to do with cvars:
//
//      startarmor 50            <- a spawn value
//      weapon_crowbar           <- argc == 1; matched no branch at all
//      ammo_9mm 20              <- became a user cvar named "ammo_9mm"
//
//  Every bare classname fell through the parser's `argc >= 2` test and was
//  dropped on the floor, and every ammo/health/armour line silently created a
//  junk cvar.  The visible result on pizza_ya_san2 is that players spawn with
//  the generic loadout, no armour and no reserve ammo, on a map whose cfg asks
//  for five weapons, 50 armour and six ammo pools.
//
//  This is not a one-map problem: of the 148 map cfgs in the corpus, 85 name
//  weapon_crowbar, 66 name ammo_9mm, 24 set startarmor and 17 set starthealth.
//
//  SOURCE OF TRUTH is Sven's own manual, which ships with the game at
//  svencoop/manual/mapping-config.html.  It is worth quoting the two things
//  that are easy to guess wrong:
//
//    * AMMO VALUES ARE CLIP/BOX COUNTS, NOT ROUNDS.  "ammo_9mm 20" is twenty
//      17-round clips, not twenty rounds.  The per-classname multipliers below
//      are the manual's own numbers.  Reading them as rounds would have given
//      pizza_ya_san2's players 20 9mm instead of 340, and 3 5.56 instead of 600.
//    * "If a game_player_equip in give mode exists in the map, the map cfg is
//      ignored for per-player settings!"  That is the rule SF_GPE_APPEND_MAP_CFG
//      (sv_goldsrc_entities.qc:340, declared and referenced nowhere until now)
//      exists to invert.
//
//  NOT IMPLEMENTED HERE, deliberately:
//    * weaponmode_* (7 maps) — alternate fire modes this mod's weapons do not
//      model as a per-map toggle.
//    * sk_* skill overrides — that is <mapname>_skl.cfg's job and its own task;
//      they are recognised here only so they stop becoming junk cvars.
//      (item_longjump used to be listed here as "consumed but inert".  It is now
//      real — the manifest routes it through GoldSrc_GrantItemClass, which sets
//      the replicated .pm_longjump that PM_CheckJump reads.)
//

// From sv_player.qc, which compiles after this file — same forward declaration
// sv_goldsrc_entities.qc:17 already carries for the same reason.
void(float wep) W_GiveWeaponToSlot;

// ---------------------------------------------------------------------------
//  Storage
//
//  Everything here is a GLOBAL, not a field, and that is deliberate: a declared
//  .field claims its spelling in the BSP keyvalue namespace and can swallow a
//  mapper's key (see sv_multi_manager.qc MM_CollisionScan for what that costs).
//  Globals have no such effect.  The item chain reuses the gpe_first_item /
//  gpe_next_item fields the game_player_equip harvester already declares.
// ---------------------------------------------------------------------------
entity mapcfg_equip_ent;      // holder for the item chain; world if the map has none
float  mapcfg_have;           // TRUE once any equipment token has been seen
float  mapcfg_starthealth;    // 0 = unset
float  mapcfg_startarmor;     // 0 = unset
float  mapcfg_maxhealth;      // 0 = unset
float  mapcfg_maxarmor;       // 0 = unset
float  mapcfg_nomedkit;
float  mapcfg_nosuit;

// Reset between maps.  FTE does not reload progs on a map change (see the note
// in worldspawn), so every one of these would otherwise leak into the next map.
//
// THE CLASSNAME TESTS ARE NOT PARANOIA.  This runs from worldspawn, by which
// point the previous map's edict table has already been wiped and re-indexed,
// so mapcfg_equip_ent is a stale pointer into a slot that may now belong to
// something else entirely.  remove()ing it blind would delete an innocent
// entity.  Checking the classname first makes a stale pointer a no-op, and the
// entities it used to refer to are gone with the old map regardless.
void() MapCfgEquip_Reset =
{
    entity it, nx;

    it = (mapcfg_equip_ent.classname == "mapcfg_equip")
             ? mapcfg_equip_ent.gpe_first_item : world;
    while (it)
    {
        nx = it.gpe_next_item;
        if (it.classname == "gpe_item")
            remove(it);
        it = nx;
    }
    if (mapcfg_equip_ent.classname == "mapcfg_equip")
        remove(mapcfg_equip_ent);

    mapcfg_equip_ent  = world;
    mapcfg_have       = 0;
    mapcfg_starthealth = 0;
    mapcfg_startarmor  = 0;
    mapcfg_maxhealth   = 0;
    mapcfg_maxarmor    = 0;
    mapcfg_nomedkit    = 0;
    mapcfg_nosuit      = 0;
};

// Append one give-me entry.  `qty` is the mapper's raw value: a clip/box count
// for ammo, a unit count for the stackable throwables, 1 for everything else.
void(string cls, float qty) MapCfgEquip_AddItem =
{
    entity gi;

    if (!mapcfg_equip_ent)
    {
        mapcfg_equip_ent           = spawn();
        mapcfg_equip_ent.classname = "mapcfg_equip";
    }

    gi               = spawn();
    gi.classname     = "gpe_item";
    gi.owner         = mapcfg_equip_ent;
    gi.netname       = strzone(cls);
    gi.count         = qty;
    gi.gpe_next_item = mapcfg_equip_ent.gpe_first_item;
    mapcfg_equip_ent.gpe_first_item = gi;
    mapcfg_have      = TRUE;
};

// ---------------------------------------------------------------------------
//  ammo_<name> -> (calibre, rounds per unit)
//
//  Straight out of svencoop/manual/mapping-config.html's Ammo table.  The
//  multiplier is the parenthesised round count in each row's description:
//      ammo_9mm "(17 rounds)"   ammo_556 "(200 rounds)"   ammo_357 "(6 rounds)"
//  ammo_sporeclip is the one that really is 1:1 ("Provide a spore").
//
//  Returns 0 for a name that is not an ammo classname.  `rounds` is returned
//  through the global below rather than a second return value.
// ---------------------------------------------------------------------------
float mapcfg_ammo_permult;

float(string lname) MapCfgEquip_AmmoCalibre =
{
    mapcfg_ammo_permult = 0;

    if (lname == "ammo_9mm")         { mapcfg_ammo_permult = 17;  return CAL_9MM;      }
    if (lname == "ammo_357")         { mapcfg_ammo_permult = 6;   return CAL_357;      }
    if (lname == "ammo_buckshot")    { mapcfg_ammo_permult = 12;  return CAL_BUCKSHOT; }
    if (lname == "ammo_556")         { mapcfg_ammo_permult = 200; return CAL_556;      }
    if (lname == "ammo_argrenades")  { mapcfg_ammo_permult = 2;   return CAL_ARGREN;   }
    if (lname == "ammo_crossbow")    { mapcfg_ammo_permult = 5;   return CAL_BOLT;     }
    if (lname == "ammo_gaussclip")   { mapcfg_ammo_permult = 20;  return CAL_URANIUM;  }
    if (lname == "ammo_rpgclip")     { mapcfg_ammo_permult = 2;   return CAL_ROCKET;   }
    if (lname == "ammo_762")         { mapcfg_ammo_permult = 5;   return CAL_762;      }
    if (lname == "ammo_sporeclip")   { mapcfg_ammo_permult = 1;   return CAL_SPORE;    }

    return 0;
};

// ---------------------------------------------------------------------------
//  Token consumer.  Called from SV_ApplyConfigFile for the map cfg ONLY, before
//  its cvar branches, and returns TRUE when it has taken ownership of the line.
//  A FALSE return leaves the old cvar_set behaviour completely untouched, which
//  is what keeps the ~40 mp_*/sv_* values working exactly as before.
// ---------------------------------------------------------------------------
float(string cmd, string val, float argc) MapCfgEquip_Token =
{
    string lname;
    float  qty;

    lname = strtolower(cmd);
    qty   = (argc >= 2) ? stof(val) : 1;

    // Spawn values.  Note startarmor 0 IS meaningful (it is the default, and 6
    // corpus maps state it explicitly), so these latch a "was set" flag by
    // being non-zero rather than by presence — with the one consequence that an
    // explicit "startarmor 0" is indistinguishable from silence.  That is
    // harmless: both mean the same thing.
    if (lname == "starthealth") { mapcfg_starthealth = qty; mapcfg_have = TRUE; return TRUE; }
    if (lname == "startarmor")  { mapcfg_startarmor  = qty; mapcfg_have = TRUE; return TRUE; }
    if (lname == "maxhealth")   { mapcfg_maxhealth   = qty; mapcfg_have = TRUE; return TRUE; }
    if (lname == "maxarmor")    { mapcfg_maxarmor    = qty; mapcfg_have = TRUE; return TRUE; }

    // Flags, which the manual documents as taking no value at all.
    if (lname == "nomedkit")    { mapcfg_nomedkit = TRUE; mapcfg_have = TRUE; return TRUE; }
    if (lname == "nosuit")      { mapcfg_nosuit   = TRUE; mapcfg_have = TRUE; return TRUE; }

    // player_weaponstrip as a cfg token means "give nothing by default".  The
    // entity of the same name already exists (sv_player_weaponstrip.qc); here it
    // is just a marker, consumed so it cannot become a cvar.
    if (lname == "player_weaponstrip") { mapcfg_have = TRUE; return TRUE; }

    if (substring(lname, 0, 7) == "weapon_"
     || substring(lname, 0, 5) == "item_"
     || substring(lname, 0, 5) == "ammo_")
    {
        if (qty <= 0) qty = 1;
        MapCfgEquip_AddItem(lname, qty);
        return TRUE;
    }

    // Recognised-and-ignored, so they stop creating junk cvars.  sk_* belongs to
    // <mapname>_skl.cfg's reader; weaponmode_* has no per-map equivalent here.
    if (substring(lname, 0, 3) == "sk_")          return TRUE;
    if (substring(lname, 0, 11) == "weaponmode_") return TRUE;

    // The two global replacement lists.  Consumed here ONLY so they stop becoming
    // junk user cvars — the value is read for real in worldspawn(), by
    // SV_ResolveGlobalList (sv_main.qc), because this parser runs long after
    // precache_everything() and a replacement table installed that late would
    // leave the canonical model precached and the replacement not.
    if (lname == "globalmodellist") return TRUE;
    if (lname == "globalsoundlist") return TRUE;

    // Sven renamed killnpc to mp_npckill and kept the old spelling working;
    // 16 corpus cfgs still use it.  Forward it rather than consume it.
    if (lname == "killnpc" && argc >= 2)
    {
        cvar_set("mp_npckill", val);
        return TRUE;
    }

    // The map's AngelScript.  We have no script VM, but server/sv_mapscript.qc
    // holds hand-ported stand-ins keyed on this value, so it has to be recorded
    // rather than dropped — and recording it also stops it becoming a junk cvar.
    if (lname == "map_script" && argc >= 2)
    {
        MapScript_SetScript(val);
        return TRUE;
    }

    // Sven's own cvar name, but unregistered here because survival mode is not
    // implemented.  Consumed so it stops creating a junk cvar; the value is the
    // campaign's map order and is worth having if survival ever lands.
    if (lname == "mp_survival_nextmap")  return TRUE;
    if (lname == "mp_survival_supported") return TRUE;

    // Sven's "do dead NPCs drop weapons" switch.  This tree's own knob is
    // sv_ai_dropweapons (read at server/sv_ai_core.qc), so bridge rather than
    // consume — all 20 hc2 cfgs set this and every one was being ignored.
    if (lname == "npc_dropweapons" && argc >= 2)
    {
        cvar_set("sv_ai_dropweapons", val);
        return TRUE;
    }

    return FALSE;
};

// ---------------------------------------------------------------------------
//  "If a game_player_equip in give mode exists in the map, the map cfg is
//   ignored for per-player settings!"  — mapping-config.html
//
//  Give mode = not USE_ONLY, i.e. an instance that equips on spawn.  A map that
//  wants both sets APPEND_MAP_CFG on it, which is what that spawnflag is for.
//  Evaluated per spawn rather than cached because game_player_equip entities can
//  be created and killtargeted during a round.
// ---------------------------------------------------------------------------
float() MapCfgEquip_SuppressedByEquipEntity =
{
    entity g;
    float  hasgive, hasappend;

    hasgive = FALSE;  hasappend = FALSE;

    g = find(world, classname, "game_player_equip");
    while (g)
    {
        if (!(g.spawnflags & SF_GPE_USE_ONLY))
        {
            hasgive = TRUE;
            if (g.spawnflags & SF_GPE_APPEND_MAP_CFG)
                hasappend = TRUE;
        }
        g = find(g, classname, "game_player_equip");
    }

    return hasgive && !hasappend;
};

// The armour ceiling this map allows.  The manual makes startarmor double as the
// cap ("This also becomes the maximum you can obtain from batteries and HEV
// chargers"), with maxarmor overriding it - but taken literally that would make
// a map stating "startarmor 0" (6 in the corpus do) unable to pick up a battery
// at all, which is plainly not the intent.  So the cap only ever RISES from the
// stock 100 unless maxarmor says otherwise.  Every corpus value is <= 100, so
// this is documentation of intent more than live arithmetic.
float() MapCfgEquip_ArmorCap =
{
    if (mapcfg_maxarmor > 0)
        return mapcfg_maxarmor;
    if (mapcfg_startarmor > SUIT_ARMOR_MAX)
        return mapcfg_startarmor;
    return SUIT_ARMOR_MAX;
};

// ---------------------------------------------------------------------------
//  Apply to a spawning player.  Called from PlayerSpawn AFTER the default
//  loadout and AFTER GamePlayerEquip_EquipSpawningPlayer, so the map's cfg is
//  the last word, matching the ordering comment already at that call site.
// ---------------------------------------------------------------------------
void(entity plyr) MapCfgEquip_Apply =
{
    entity oldself, it;
    float  cal, amt, cap, held, wid;
    float  gaveweap, gaveammo;
    string nm;

    gaveweap = 0;  gaveammo = 0;

    if (!mapcfg_have || !plyr || plyr.classname != "player")
        return;
    if (MapCfgEquip_SuppressedByEquipEntity())
        return;

    if (mapcfg_starthealth > 0)
    {
        plyr.health = mapcfg_starthealth;
        // sv_chargers.qc:199 already reads `player.max_health ? ... : 100`, so
        // setting this is all the wall health station needs to honour the map.
        plyr.max_health = mapcfg_maxhealth > 0 ? mapcfg_maxhealth : mapcfg_starthealth;
    }
    else if (mapcfg_maxhealth > 0)
    {
        plyr.max_health = mapcfg_maxhealth;
    }

    if (mapcfg_startarmor > 0)
        plyr.armor = min(MapCfgEquip_ArmorCap(), mapcfg_startarmor);

    oldself = self;
    self    = plyr;

    // PASS 1 - weapons and items.  Must run before the ammo pass: Ammo_GiveTo-
    // Carried only fills guns the player actually holds, and banks the rest.
    it = mapcfg_equip_ent.gpe_first_item;
    while (it)
    {
        nm = it.netname;
        if (substring(nm, 0, 5) != "ammo_")
        {
            // item_* names are not weapon-manifest keys, so route them through
            // the shared item grant first.  17 of the 20 hc2 cfgs ask for
            // item_longjump this way and every one of them was being dropped:
            // the prefix strip below only removes "weapon_", so the name stayed
            // "item_longjump" and resolved to WEP_NONE.
            if (GoldSrc_GrantItemClass(plyr, nm))
            {
                gaveweap = gaveweap + 1;
                it = it.gpe_next_item;
                continue;
            }

            // Same prefix strip as GamePlayerEquip_Apply: the manifest key for
            // "weapon_crowbar" is "crowbar".
            if (substring(nm, 0, 7) == "weapon_")
                nm = substring(nm, 7, strlen(nm) - 7);

            wid = Weapon_IdFromStringOrDefault(nm, WEP_NONE);
            if (wid != WEP_NONE)
            {
                W_GiveWeaponToSlot(wid);
                gaveweap = gaveweap + 1;
            }
            else if (cvar("sv_debug_use"))
                print(sprintf("[mapcfg] no weapon for \"%s\" - ignored\n", it.netname));
        }
        it = it.gpe_next_item;
    }

    // PASS 2 - ammo, give-or-bank.  This mirrors GoldSrc_Ammo_Touch
    // (sv_goldsrc_ammo.qc:374-404) exactly rather than inventing a second
    // policy: fill the carried gun if it takes anything, otherwise bank up to
    // the calibre cap so the reserve is waiting when the gun is found.
    it = mapcfg_equip_ent.gpe_first_item;
    while (it)
    {
        if (substring(it.netname, 0, 5) == "ammo_")
        {
            cal = MapCfgEquip_AmmoCalibre(it.netname);
            if (cal)
            {
                amt = it.count * mapcfg_ammo_permult;
                if (!Ammo_GiveToCarried(plyr, cal, amt))
                {
                    cap  = Ammo_CalibreMax(cal);
                    held = Ammo_BankGet(plyr, cal);
                    if (held < cap)
                        Ammo_BankSet(plyr, cal, min(cap, held + amt));
                }
                gaveammo = gaveammo + amt;
            }
            else if (cvar("sv_debug_use"))
                print(sprintf("[mapcfg] no calibre for \"%s\" - ignored\n", it.netname));
        }
        it = it.gpe_next_item;
    }

    self = oldself;

    if (cvar("sv_debug_use"))
        print(sprintf("[mapcfg] equipped %s: %g weapon(s), %g round(s), health %g, armor %g\n",
                      plyr.netname, gaveweap, gaveammo, plyr.health, plyr.armor));
};

// One line at map load so the applied manifest is visible without a debug cvar -
// this whole feature was invisible for exactly as long as nothing printed.
void() MapCfgEquip_Report =
{
    entity it;
    float  nw, na;

    if (!mapcfg_have)
        return;

    // nomedkit / nosuit are PARSED AND REPORTED BUT DELIBERATELY NOT ENFORCED.
    // They are the two tokens in the manifest that take things AWAY from the
    // player - Sven's nosuit also kills the flashlight and all armour pickups -
    // and this tree's brief is map compatibility without inheriting the maps'
    // restrictions.  20 corpus cfgs set nomedkit and 4 set nosuit, including
    // every They Hunger chapter and the HL campaign, so honouring them would
    // silently strip the medkit across most of the single-player content.
    // Consuming the tokens still matters: it stops them becoming junk cvars.
    if (mapcfg_nomedkit || mapcfg_nosuit)
        print(sprintf("[mapcfg] map requests%s%s - parsed, NOT enforced\n",
                      mapcfg_nomedkit ? " nomedkit" : "",
                      mapcfg_nosuit   ? " nosuit"   : ""));

    nw = 0;  na = 0;
    it = mapcfg_equip_ent ? mapcfg_equip_ent.gpe_first_item : world;
    while (it)
    {
        if (substring(it.netname, 0, 5) == "ammo_") na = na + 1;
        else                                        nw = nw + 1;
        it = it.gpe_next_item;
    }

    // Only announce the manifest when there is actually something in it.  A cfg
    // that carries nothing but nomedkit/nosuit (th_ep1_00, every hl_c* chapter)
    // otherwise printed a line of zeroes that read as a parse failure.
    if (!nw && !na && !mapcfg_starthealth && !mapcfg_startarmor
        && !mapcfg_maxhealth && !mapcfg_maxarmor)
        return;

    print(sprintf("[mapcfg] equipment: %g weapon/item, %g ammo, health %g, armor %g%s\n",
                  nw, na, mapcfg_starthealth, mapcfg_startarmor,
                  MapCfgEquip_SuppressedByEquipEntity()
                      ? " (SUPPRESSED by a give-mode game_player_equip)" : ""));
};
