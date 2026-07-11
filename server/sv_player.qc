
//
//	Player.qc - Various stuff done for the player, including per-frame functions like PlayerPreThink and PlayerPostThink, also client specific stuff like PutClientInServer etc.
//

void(entity player) PM_SyncPredictionProxy;

// =============================================
//  Team System
// =============================================

// Returns 1 if a player-sized bbox at spot.origin would not overlap any solid.
// Almost always tells us "no other player is currently standing here" — walls
// aren't usually placed at spawn entities. `self` is excluded from the trace
// so the player about to (re)spawn doesn't see themselves as blocking.
// Hull dims are hardcoded rather than using PM_MINS/MAXS so this works even
// before PM_ReadMovevars has run (e.g. during PlayerBeginTeamSelection).
float(entity spot) Spawn_IsClear =
{
    vector pos = spot.origin + '0 0 1';
    tracebox(pos, '-16 -16 0', '16 16 56', pos, MOVE_NORMAL, self);
    return (trace_startsolid == 0);
};

// Returns one entity matching `spawn_classname`, preferring an unobstructed
// spawn point (no player or other solid intersecting). Falls back to a random
// occupied one if every spawn of this classname is blocked. Returns world if
// no entities of this classname exist.
//
// Two parallel reservoir-sampling picks: choice_free over clear spots,
// choice_any over all spots. Cost is O(N) tracebox calls per spawn pick,
// where N is typically <16. Negligible.
entity(string spawn_classname) PlayerFindSpawnByClassname =
{
    entity spot, choice_free, choice_any;
    float count_free, count_any;

    spot = world;
    choice_free = world;
    choice_any  = world;
    count_free = 0;
    count_any  = 0;

    while (TRUE)
    {
        spot = find(spot, classname, spawn_classname);
        if (!spot)
            break;

        count_any = count_any + 1;
        if (random() < (1 / count_any))
            choice_any = spot;

        if (Spawn_IsClear(spot))
        {
            count_free = count_free + 1;
            if (random() < (1 / count_free))
                choice_free = spot;
        }
    }

    if (choice_free)
        return choice_free;
    return choice_any;
};

// FFA spawn picker: same reservoir-sampling logic as
// PlayerFindSpawnByClassname, but accepts spawn points of EITHER classname
// so blue + red spawns merge into a single pool. Used only by the FFA
// branch in PlayerGetSpawnPointEntity below — the team-mode picker stays
// strict so blue players never land at red spawns and vice versa.
entity(string a, string b) PlayerFindSpawnByEitherClassname =
{
    entity spot, choice_free, choice_any;
    float count_free, count_any;

    spot = world;
    choice_free = world;
    choice_any  = world;
    count_free = 0;
    count_any  = 0;

    while (TRUE)
    {
        spot = nextent(spot);
        if (!spot)
            break;
        if (spot.classname != a && spot.classname != b)
            continue;

        count_any = count_any + 1;
        if (random() < (1 / count_any))
            choice_any = spot;

        if (Spawn_IsClear(spot))
        {
            count_free = count_free + 1;
            if (random() < (1 / count_free))
                choice_free = spot;
        }
    }

    if (choice_free)
        return choice_free;
    return choice_any;
};

// Strict team-spawn policy: TEAM_BLUE only ever spawns at blue classnames,
// TEAM_RED only ever spawns at red classnames.  When the map has no team
// spawns for this player's team, we fall through to a CS-style two-step
// chain: BLUE plays the CT side (info_player_start primary, info_player_
// deathmatch as cross-backup) and RED plays the T side (info_player_
// deathmatch primary, info_player_start as cross-backup).  The cross-
// backup catches single-class CS maps that ship only one of the two.
// PlayerPlaceAtSpawnPoint handles the "no spawn at all" case by snapping
// to (0,0,1) so the spawn pipeline never returns world to its callers.
entity() PlayerGetSpawnPointEntity =
{
    entity spawnpoint;
    float is_team_player;
    string cs_primary, cs_backup;

    spawnpoint = world;
    is_team_player = FALSE;

    if (Gamemode_HasUnifiedTeams())
    {
        // Unified-team gamemodes (FFA + Bhop) pool both teams' spawns
        // through the same canonical → start → team1/2 fallback chain
        // so existing maps with team-only spawn entities work without
        // re-editing. Player still has a backend TEAM_BLUE/TEAM_RED
        // value (set by their model pick on the team-select panel);
        // we just don't let it filter the spawn pool here.
        is_team_player = TRUE;
        spawnpoint = PlayerFindSpawnByEitherClassname(
            "info_player_blue", "info_player_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByEitherClassname(
                "info_player_start_blue", "info_player_start_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByEitherClassname(
                "info_player_team1", "info_player_team2");
        // Fall through to the CS-style cs_primary/cs_backup chain below
        // when neither team has tagged spawns on this map.
        cs_primary = "info_player_start";
        cs_backup  = "info_player_deathmatch";
    }
    else if (self.player_team == TEAM_BLUE)
    {
        is_team_player = TRUE;
        spawnpoint = PlayerFindSpawnByClassname("info_player_blue");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_start_blue");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_team1");
        // CS CT side maps to BLUE.
        cs_primary = "info_player_start";
        cs_backup  = "info_player_deathmatch";
    }
    else if (self.player_team == TEAM_RED)
    {
        is_team_player = TRUE;
        spawnpoint = PlayerFindSpawnByClassname("info_player_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_start_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_team2");
        // CS T side maps to RED.
        cs_primary = "info_player_deathmatch";
        cs_backup  = "info_player_start";
    }
    else
    {
        // Untagged player (spectator transitioning, pre-team-pick) —
        // route them through the CT side's chain since info_player_start
        // is the more universal "any spawn" classname in CS maps.
        cs_primary = "info_player_start";
        cs_backup  = "info_player_deathmatch";
    }

    string cs_used = "";
    if (!spawnpoint)
    {
        spawnpoint = PlayerFindSpawnByClassname(cs_primary);
        if (spawnpoint)
            cs_used = cs_primary;
    }
    if (!spawnpoint)
    {
        spawnpoint = PlayerFindSpawnByClassname(cs_backup);
        if (spawnpoint)
            cs_used = cs_backup;
    }

    if (cs_used != "" && cvar("developer"))
    {
        // Gated behind `developer` because FTE's dprint is unconditional
        // (unlike vanilla QC's). Map authors want to see this; end users
        // running vanilla-compat CS maps on the mod don't.
        // Colour palette: ^3 yellow tag = "fallback fired", ^6 magenta =
        // highlighted classname, ^4/^1 = team identity.
        dprint(sprintf("^3[spawn]^7 resorting to cs spawns ^6[%s]^7 for team-%s on map %s\n",
            cs_used,
            (self.player_team == TEAM_BLUE) ? "^4blue^7"
                : (self.player_team == TEAM_RED) ? "^1red^7" : "none",
            serverkey("mapname")));
    }

    // Per-respawn diagnostic.
    //   developer 1          → dprint to server console only (classic path)
    //   sv_debug_spawns 1    → bprint to all consoles (for diagnosing
    //                          wrong-team-side-respawn reports without
    //                          needing developer-level noise)
    float want_dev  = cvar("developer");
    float want_diag = cvar("sv_debug_spawns");
    if ((want_dev || want_diag) && spawnpoint)
    {
        // Colour palette: ^4 blue / ^1 red for team identity, ^2 green
        // for CLEAR (good), ^1 red for OCCUPIED (bad), ^3 yellow for
        // CS-FALLBACK (degraded), ^6 magenta to highlight classnames.
        string team_str = (self.player_team == TEAM_BLUE) ? "^4BLUE^7"
                        : (self.player_team == TEAM_RED)  ? "^1RED^7"
                        : "NONE";
        string state_str;
        if (cs_used != "")
            state_str = sprintf("^3CS-FALLBACK^7 ^6[%s]^7", cs_used);
        else if (Spawn_IsClear(spawnpoint))
            state_str = "^2CLEAR^7";
        else
            state_str = "^1OCCUPIED^7 (all spawns blocked)";
        string line = sprintf("^5[spawn]^7 slot %g team=%s picked ^6%s^7 at %v — %s\n",
            num_for_edict(self) - 1, team_str,
            spawnpoint.classname, spawnpoint.origin, state_str);
        // sv_debug_spawns takes precedence — if it's on, we want the
        // visible bprint and not the duplicated dprint underneath (on
        // a listen server both go to the same console).
        if (want_diag)
            bprint(PRINT_HIGH, line);
        else
            dprint(line);
    }

    return spawnpoint;
};

void() PlayerPlaceAtSpawnPoint =
{
    entity spawnpoint;

    spawnpoint = PlayerGetSpawnPointEntity();
    if (!spawnpoint)
    {
        setorigin(self, '0 0 1');
        return;
    }

    setorigin(self, spawnpoint.origin + '0 0 1');
    self.angles = spawnpoint.angles;
    self.v_angle = spawnpoint.angles;
};

void() PlayerApplyTeamColours =
{
    if (self.player_team == TEAM_RED)
    {
        setcolors(self, (14 * 16) + 5);
        return;
    }

    if (self.player_team == TEAM_BLUE)
    {
        setcolors(self, (11 * 16) + 2);
        return;
    }
};

void(entity player) PlayerRefreshScoreboardInfo =
{
    float topcolor;
    float bottomcolor;

    forceinfokey(player, "modteam", ftos(player.player_team));
    forceinfokey(player, "deaths", ftos(player.deaths));
    // Broadcast dead state so other clients can dim this player's row on
    // the scoreboard.  Callers must ensure is_dead is set to its new value
    // before invoking this refresh for the state to be accurate.
    forceinfokey(player, "dead", ftos(player.is_dead));

    topcolor = 0;
    bottomcolor = 0;
    if (player.player_team == TEAM_BLUE)
    {
        topcolor = 11;
        bottomcolor = 2;
    }
    else if (player.player_team == TEAM_RED)
    {
        topcolor = 14;
        bottomcolor = 5;
    }

    forceinfokey(player, INFOKEY_P_TOPCOLOR, ftos(topcolor));
    forceinfokey(player, INFOKEY_P_BOTTOMCOLOR, ftos(bottomcolor));
};

float() PlayerNeedsTeamSelection =
{
    return self.player_team <= TEAM_NONE;
};

void() PlayerBeginTeamSelection =
{
    self.player_team = TEAM_NONE;
    self.classname = "player";
    self.solid = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.modelindex = 0;
    self.health = 100;
    self.frags = 0;
    self.deaths = 0;
    self.weapon = 0;
    // Explicitly clear every inventory slot + its equip/drop callbacks.
    // Defence-in-depth against anything (map pickups touched during
    // camera placement, residual state from an earlier session, etc.)
    // stashing a weapon on the team-select player.  weapon_touch also
    // guards via player_team == TEAM_NONE, but resetting here means even
    // if a past frame slipped a weapon in, it's gone before gameplay.
    self.slot_primary         = WEP_NONE;
    self.slot_primary_equip   = __NULL__;
    self.slot_primary_drop    = __NULL__;
    self.slot_secondary       = WEP_NONE;
    self.slot_secondary_equip = __NULL__;
    self.slot_secondary_drop  = __NULL__;
    self.slot_melee           = WEP_NONE;
    self.slot_melee_equip     = __NULL__;
    self.slot_melee_drop      = __NULL__;
    self.slot_utility         = WEP_NONE;
    self.slot_utility_equip   = __NULL__;
    self.slot_utility_drop    = __NULL__;
    W_SlotAmmo_ClearSlots(self);
    self.ammo_hlgrenade       = 0;
    self.ammo_snowball        = 0;
    self.ammo_cshegrenade     = 0;
    self.ammo_csflashbang     = 0;
    self.ammo_cssmokegrenade  = 0;
    self.mag_paintball        = 0;
    self.ammo_paintball       = 0;
    self.snowball_has_slingshot = FALSE;
    self.snowball_use_slingshot = FALSE;
    self.team_menu_request_serial = 0;
    self.velocity = '0 0 0';
    self.fixangle = TRUE;
    self.cam_phase = CAM_PHASE_NEUTRAL;   // deterministic phase on (re)connect
    self.cam_last_dbg_time = 0;
    // Freeze pmove while in team-select — otherwise PM_PlayerMove applies
    // small gravity every tick and the player drifts down off the camera.
    self.pm_movetype = PM_MOVETYPE_NONE;
    // Prefer a "camera" entity viewpoint for team selection. Falls through
    // to the normal spawn point system if the map doesn't define any.
    if (!Camera_PlacePlayerAtCurrent(self))
        PlayerPlaceAtSpawnPoint();
    PlayerRefreshScoreboardInfo(self);
};

void() PlayerSpawn;
.entity player_visual_proxy;  // forward declaration (defined below)

void(vector org, void() spawn_func) SV_DebugSpawnWeapon =
{
    entity saved_self = self;

    self = spawn();
    setorigin(self, org);
    spawn_func();

    // Debug spawns trip the sv_debug_weapon_spawning early-return inside
    // W_RegisterMapWeapon, which means the slot-ammo seed lines (the
    // W_SlotAmmo_SaveLegacy + W_SlotAmmo_CopyPlayerToDrop pair that map
    // weapons rely on) never run.  Without those, weapon_drop_mag/ammo
    // stay zero on the entity, and weapon_touch's slot-ammo path
    // overwrites the legacy mag_*/ammo_* fields back to zero on pickup
    // — debug weapons came up empty.  Run the seed manually here so the
    // ammo the weapon_*() spawn function set on legacy fields makes it
    // into the drop fields the slot-ammo pipeline reads.
    W_SlotAmmo_SaveLegacy(self, self.weapon);
    W_SlotAmmo_CopyPlayerToDrop(self, self, self.weapon);

    if (W_PhysDropAllowed(self.weapon))
    {
        // Same mesh-aware floor snap that map weapons get in
        // W_RegisterMapWeapon — without it, debug weapons spawn at the
        // requested grid origin (typically a few units above the floor),
        // ODE detects mesh-below-bbox penetration on activation and
        // ejects them upward, producing the same bounce cascade
        // map weapons used to suffer from at round restart.
        if (!W_PhysDropGroundSnap())
            self.velocity = '0 0 -200';   // void fallback — let TOSS find ground
        self.owner = world;
        W_PhysDropStart(self, 0);
    }

    self = saved_self;
};

vector(vector base, float row, float col) SV_DebugWeaponOrigin =
{
    return base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48);
};

void(vector org, float weapon_id) SV_DebugSpawnWeaponId =
{
	     if (weapon_id == WEP_AK47)           SV_DebugSpawnWeapon(org, weapon_ak47);
	else if (weapon_id == WEP_HDAK47)         SV_DebugSpawnWeapon(org, weapon_hdak47);
	else if (weapon_id == WEP_M4A1)           SV_DebugSpawnWeapon(org, weapon_m4a1);
	else if (weapon_id == WEP_CSAWP)          SV_DebugSpawnWeapon(org, weapon_csawp);
	else if (weapon_id == WEP_G3SG1)          SV_DebugSpawnWeapon(org, weapon_g3sg1);
	else if (weapon_id == WEP_CSM3)           SV_DebugSpawnWeapon(org, weapon_csm3);
	else if (weapon_id == WEP_CSMP5)          SV_DebugSpawnWeapon(org, weapon_csmp5);
	else if (weapon_id == WEP_PAINTBALL)      SV_DebugSpawnWeapon(org, weapon_paintball);
	else if (weapon_id == WEP_DOD98K)         SV_DebugSpawnWeapon(org, weapon_dod98k);
	else if (weapon_id == WEP_FLAKSHOTGUN)    SV_DebugSpawnWeapon(org, weapon_flakshotgun);
	else if (weapon_id == WEP_GAUSS)          SV_DebugSpawnWeapon(org, weapon_gauss);
	else if (weapon_id == WEP_GRENADELAUNCHER) SV_DebugSpawnWeapon(org, weapon_grenadelauncher);
	else if (weapon_id == WEP_CROSSBOW)       SV_DebugSpawnWeapon(org, weapon_crossbow);
	else if (weapon_id == WEP_HLEGON)         SV_DebugSpawnWeapon(org, weapon_hlegon);
	else if (weapon_id == WEP_HLRPG)          SV_DebugSpawnWeapon(org, weapon_hlrpg);
	else if (weapon_id == WEP_HLSHOTGUN)      SV_DebugSpawnWeapon(org, weapon_hlshotgun);
	else if (weapon_id == WEP_HLSMG)          SV_DebugSpawnWeapon(org, weapon_hlsmg);
	else if (weapon_id == WEP_M249)           SV_DebugSpawnWeapon(org, weapon_m249);
	else if (weapon_id == WEP_REBAR)          SV_DebugSpawnWeapon(org, weapon_rebar);
	else if (weapon_id == WEP_SCOUT)          SV_DebugSpawnWeapon(org, weapon_scout);
	else if (weapon_id == WEP_DEAGLE)         SV_DebugSpawnWeapon(org, weapon_deagle);
	else if (weapon_id == WEP_GLOCK)          SV_DebugSpawnWeapon(org, weapon_glock);
	else if (weapon_id == WEP_357)            SV_DebugSpawnWeapon(org, weapon_357);
	else if (weapon_id == WEP_HLGLOCK)        SV_DebugSpawnWeapon(org, weapon_hlglock);
	else if (weapon_id == WEP_PISTOL)         SV_DebugSpawnWeapon(org, weapon_pistol);
	else if (weapon_id == WEP_WRENCH)         SV_DebugSpawnWeapon(org, weapon_wrench);
	else if (weapon_id == WEP_KNIFE)          SV_DebugSpawnWeapon(org, weapon_knife);
	else if (weapon_id == WEP_HLCROWBAR)      SV_DebugSpawnWeapon(org, weapon_hlcrowbar);
	else if (weapon_id == WEP_HLGRENADE)      SV_DebugSpawnWeapon(org, weapon_hlgrenade);
	else if (weapon_id == WEP_SNOWBALL)       SV_DebugSpawnWeapon(org, weapon_snowball);
	else if (weapon_id == WEP_SLINGSHOT)      SV_DebugSpawnWeapon(org, weapon_slingshot);
	else if (weapon_id == WEP_CSHEGRENADE)    SV_DebugSpawnWeapon(org, weapon_cshegrenade);
	else if (weapon_id == WEP_CSFLASHBANG)    SV_DebugSpawnWeapon(org, weapon_csflashbang);
	else if (weapon_id == WEP_CSSMOKEGRENADE) SV_DebugSpawnWeapon(org, weapon_cssmokegrenade);
	else if (weapon_id == WEP_CFAUG)          SV_DebugSpawnWeapon(org, weapon_cfaug);
	else if (weapon_id == WEP_CFFAMAS)        SV_DebugSpawnWeapon(org, weapon_cffamas);
	else if (weapon_id == WEP_CFMAC10)        SV_DebugSpawnWeapon(org, weapon_cfmac10);
	else if (weapon_id == WEP_CFBARRETT)          SV_DebugSpawnWeapon(org, weapon_cfbarrett);
	else if (weapon_id == WEP_CFPSG1)        SV_DebugSpawnWeapon(org, weapon_cfpsg1);
	else if (weapon_id == WEP_CFSPAS12)       SV_DebugSpawnWeapon(org, weapon_cfspas12);
	else if (weapon_id == WEP_CFM700)    SV_DebugSpawnWeapon(org, weapon_cfm700);
	else if (weapon_id == WEP_CFM3)           SV_DebugSpawnWeapon(org, weapon_cfm3);
	else if (weapon_id == WEP_CFSCAR)        SV_DebugSpawnWeapon(org, weapon_cfscar);
	else if (weapon_id == WEP_CFSVD)        SV_DebugSpawnWeapon(org, weapon_cfsvd);
	else if (weapon_id == WEP_CFMP5)          SV_DebugSpawnWeapon(org, weapon_cfmp5);
	else if (weapon_id == WEP_CFVECTOR)       SV_DebugSpawnWeapon(org, weapon_cfvector);
	else if (weapon_id == WEP_CFTYPE89)       SV_DebugSpawnWeapon(org, weapon_cftype89);
	else if (weapon_id == WEP_CFUMP45)        SV_DebugSpawnWeapon(org, weapon_cfump45);
	else if (weapon_id == WEP_CFM249)         SV_DebugSpawnWeapon(org, weapon_cfm249);
	else if (weapon_id == WEP_CFAWM)          SV_DebugSpawnWeapon(org, weapon_cfawm);
	else if (weapon_id == WEP_CFKS23)         SV_DebugSpawnWeapon(org, weapon_cfks23);
	else if (weapon_id == WEP_CFM4)           SV_DebugSpawnWeapon(org, weapon_cfm4);
	else if (weapon_id == WEP_CFMK23)         SV_DebugSpawnWeapon(org, weapon_cfmk23);
	else if (weapon_id == WEP_CSUSP)          SV_DebugSpawnWeapon(org, weapon_csusp);
	else if (weapon_id == WEP_CFGALIL)        SV_DebugSpawnWeapon(org, weapon_cfgalil);
	else if (weapon_id == WEP_CFGLOCK)        SV_DebugSpawnWeapon(org, weapon_cfglock);
	else if (weapon_id == WEP_CFELITE)        SV_DebugSpawnWeapon(org, weapon_cfelite);
	else if (weapon_id == WEP_CFP228)         SV_DebugSpawnWeapon(org, weapon_cfp228);
	else if (weapon_id == WEP_CFMSG90)        SV_DebugSpawnWeapon(org, weapon_cfmsg90);
	else if (weapon_id == WEP_CFSG552)        SV_DebugSpawnWeapon(org, weapon_cfsg552);
	else if (weapon_id == WEP_CFSL8)          SV_DebugSpawnWeapon(org, weapon_cfsl8);
	else if (weapon_id == WEP_GRAVITYGUN)     SV_DebugSpawnWeapon(org, weapon_gravitygun);
	else if (weapon_id == WEP_CFM9)    SV_DebugSpawnWeapon(org, weapon_cfm9);
	else if (weapon_id == WEP_CFREVOLVER)       SV_DebugSpawnWeapon(org, weapon_cfrevolver);
	else if (weapon_id == WEP_CFDDEAGLE)        SV_DebugSpawnWeapon(org, weapon_cfddeagle);
	else if (weapon_id == WEP_CFMAUSER)        SV_DebugSpawnWeapon(org, weapon_cfmauser);
	else if (weapon_id == WEP_BUTTERFLY)      SV_DebugSpawnWeapon(org, weapon_butterfly);
	else if (weapon_id == WEP_KATANA)         SV_DebugSpawnWeapon(org, weapon_katana);
	else if (weapon_id == WEP_CFC4)           SV_DebugSpawnWeapon(org, weapon_cfc4);
};

// Apply the correct player model based on team + model_index.
void() PlayerApplyModel =
{
    string mdl;

    if (self.player_model_index == 5)
        mdl = "models/player/sini.mdl";
    else if (self.player_model_index == 6)
        mdl = "models/player/chickenman/chickenman.iqm";
    else if (self.player_model_index == 7)
        mdl = "models/player/numberk/numberK.iqm";
    else if (self.player_model_index == 8)
        mdl = "models/player/kilmer/kilmer.iqm";
    else
    {
        float idx = bound(0, self.player_model_index, TEAM_MODEL_COUNT - 1);
        if (self.player_team == TEAM_BLUE)
            mdl = team_blue_models[idx];
        else if (self.player_team == TEAM_RED)
            mdl = team_red_models[idx];
        else
            mdl = "models/player/leet/leet.iqm";
    }

    entity vis = self.player_visual_proxy;
    if (vis)
    {
        setmodel(vis, mdl);
        // Force an IDENTITY-section resend (bit 4 = VP_SF_IDENTITY, defined
        // further down) so the team_model byte refreshes even if
        // Player_VisualProxy_Sync didn't see a change this tick.
        vis.SendFlags |= 4;
    }

    // Also set on the player entity for MOVE_HITMODEL traces.
    // setmodel resets mins/maxs so restore collision box.
    // Make fully transparent so the engine doesn't render it visually
    // (the visual proxy handles all rendering), but the model stays
    // loaded for MOVE_HITMODEL bone-accurate traces.
    setmodel(self, mdl);
    self.alpha = -1;  // fully invisible but still present for traces
    SetHitboxSize(self, PM_MINS, PM_MAXS);
};

void(float new_team, float model_idx) PlayerJoinTeam =
{
    if (new_team != TEAM_BLUE && new_team != TEAM_RED)
        return;

    model_idx = bound(0, model_idx, 8); // 0-3 = team models; 5 = sini, 6 = chickenman, 7 = numberK, 8 = kilmer

    // Defensive: leaving spec ALWAYS needs a full PlayerSpawn pass.
    // PlayerJoinSpectate sets is_dead=TRUE, modelindex=0, solid=NOT,
    // movetype=NONE, alpha=-1 — none of which the same-team / model-only
    // fast path below would undo. Without this guard, an intermittent
    // bug let spec-rejoin land in the fast-path branch and the player
    // stayed effectively dead/invisible. Latch first, gate later.
    float was_spec = (self.player_team == TEAM_SPEC);

    // Same team, just changing model — swap instantly without respawn.
    // Skipped when leaving spec (see was_spec above) so the spec→team
    // transition always reaches PlayerSpawn at the bottom.
    if (!was_spec && self.player_team == new_team && !PlayerNeedsTeamSelection())
    {
        self.player_model_index = model_idx;
        PlayerApplyModel();
        return;
    }

    if (!PlayerNeedsTeamSelection() && self.player_team != new_team)
        self.deaths = self.deaths + 1;

    self.player_team = new_team;
    self.player_model_index = model_idx;
    PlayerApplyTeamColours();
    PlayerRefreshScoreboardInfo(self);

    // CS economy: grant starting cash on first real team join (once —
    // Money_EnsureStart guards via money_started, so model swaps / rejoins
    // don't refill).  Cash then persists across deaths/rounds.
    Money_EnsureStart(self);

    // Auto-restart trigger when the player count goes from 1 to 2 —
    // checked BEFORE the elim/paintgun deferred-spawn return below so
    // a new joiner who lands in the dead/spec pending state still
    // fires the restart.  Walk player_chain_head and count teamed
    // players (TEAM_BLUE + TEAM_RED).  If we're now the second teamed
    // player and the round was already running (round_phase != NONE),
    // queue a restart via the standard sv_roundrestart admin trigger.
    // Works in all gamemodes — score / round timer reset on the
    // restart path.
    if (round_phase != ROUND_PHASE_NONE)
    {
        float teamed_count = 0;
        entity scan = player_chain_head;
        while (scan)
        {
            if (scan.player_team == TEAM_BLUE || scan.player_team == TEAM_RED)
                teamed_count = teamed_count + 1;
            scan = scan.player_chain_next;
        }
        if (teamed_count == 2)
        {
            cvar_set("sv_roundrestart", "1");
            bprint(PRINT_HIGH, "Second player joined — restarting round.\n");
        }
    }

    // Elimination mid-round join: stay invisible/non-colliding until the
    // next RoundRestart. RoundRestart's teamed-player loop in sv_main.qc
    // already clears is_dead/pending_round_join and calls PlayerSpawn,
    // so we just have to mark the player here. FREEZE phase is treated
    // as "round starting" — we let it spawn through normally.
    // Spec-leavers also bypass this branch — they should fully spawn
    // even mid-round (they were already a non-participant).
    if (!was_spec
        && (cvar("sv_gamemode") == GAMEMODE_ELIMINATION
            || cvar("sv_gamemode") == GAMEMODE_PAINTGUN)
        && (round_phase == ROUND_PHASE_ACTIVE
            || round_phase == ROUND_PHASE_ROUND_END))
    {
        self.is_dead = TRUE;
        self.death_time = -1;
        self.solid = SOLID_NOT;
        self.movetype = MOVETYPE_NONE;
        self.pm_movetype = PM_MOVETYPE_DEAD;
        self.health = 0;
        self.velocity = '0 0 0';
        self.weapon = WEP_NONE;
        setmodel(self, "");
        self.alpha = -1;
        entity vis = self.player_visual_proxy;
        if (vis)
        {
            remove(vis);
            self.player_visual_proxy = world;
        }
        self.pending_round_join = TRUE;
        PlayerRefreshScoreboardInfo(self);
        PM_SyncPredictionProxy(self);
        return;
    }

    PlayerSpawn();

    // Start the first round when the first player joins a team.
    // (The 2-player auto-restart trigger lives above the deferred-spawn
    // branch so it fires for both fully-spawned and pending-spawn
    // joiners — see the count-and-set-sv_roundrestart block earlier in
    // this function.)
    if (round_phase == ROUND_PHASE_NONE)
    {
        round_active = TRUE;
        RoundStart();
    }
};

void() PlayerJoinSpectate =
{
    if (self.player_team == TEAM_SPEC)
        return;

    self.player_team = TEAM_SPEC;

    // Make invisible and non-interactive
    self.is_dead = TRUE;
    self.death_time = 0;
    // Refresh AFTER is_dead so the scoreboard sees the new dead state.
    PlayerRefreshScoreboardInfo(self);
    self.solid = SOLID_NOT;
    self.health = 0;
    self.velocity = '0 0 0';
    self.pm_movetype = PM_MOVETYPE_DEAD;
    self.weapon = WEP_NONE;

    // Hide the player model and visual proxy
    setmodel(self, "");
    self.alpha = -1;
    entity vis = self.player_visual_proxy;
    if (vis)
    {
        // Voluntary spectate from an alive player — no corpse needed
        // (their standing pose would look weird left in the world). For
        // dead players, the proxy was already detached as a corpse in
        // PlayerKilled, so player_visual_proxy is world here and we
        // skip the remove. RoundRestart's sweep cleans up corpses.
        remove(vis);
        self.player_visual_proxy = world;
    }

    bprint(PRINT_HIGH, self.netname);
    bprint(PRINT_HIGH, " is now spectating\n");

    PM_SyncPredictionProxy(self);
};

float(string cmd) PlayerHandleTeamCommand =
{
    string team_name;
    float new_team;

    if (cmd == "spectate" || cmd == "spec")
    {
        PlayerJoinSpectate();
        return TRUE;
    }

    if (cmd != "jointeam" && cmd != "team")
        return FALSE;

    team_name = argv(1);
    new_team = TEAM_NONE;

    if (team_name == "blue")
        new_team = TEAM_BLUE;
    else if (team_name == "red")
        new_team = TEAM_RED;
    else if (team_name == "spec" || team_name == "spectate")
    {
        PlayerJoinSpectate();
        return TRUE;
    }

    // argv(2) = model index (0-3), defaults to 0 if not provided
    float model_idx = stof(argv(2));

    if (new_team != TEAM_NONE)
        PlayerJoinTeam(new_team, model_idx);

    return TRUE;
};

void() PlayerHandlePreTeamSelectionImpulse =
{
    if (self.impulse == 28)
        self.team_menu_request_serial = self.team_menu_request_serial + 1;

    self.impulse = 0;
};

void() TeamSelectionCheck =
{
    if (PlayerNeedsTeamSelection())
    {
        PlayerHandlePreTeamSelectionImpulse();
        self.velocity = '0 0 0';
        return;
    }
};

// =============================================
//  Core Player Logic
// =============================================

void() PlayerJump =
{
	if (!(self.flags & FL_ONGROUND))
		return;

	if ( !(self.flags & FL_JUMPRELEASED) )
		return;

	self.weaponframe = 0;
	self.flags = self.flags - (self.flags & FL_JUMPRELEASED);
	self.button2 = 0;
};

void() CheckImpulses =
{
	W_CheckImpulses();   // weapon impulses (1-6, 12-13) — zeros self.impulse if claimed

	switch (self.impulse)
	{
	case 11:   // use key
		SV_PlayerTryUse();
		break;
	case 10:   // noclip toggle
		if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
		{
			self.pm_movetype = PM_MOVETYPE_NORMAL;
			self.solid       = SOLID_SLIDEBOX;
			sprint(self, PRINT_HIGH, "noclip OFF\n");
		}
		else if (cvar("mp_cheats"))
		{
			self.pm_movetype = PM_MOVETYPE_NOCLIP;
			self.solid       = SOLID_NOT;
			sprint(self, PRINT_HIGH, "noclip ON\n");
		}
		break;
	case 28:   // team menu request
		self.team_menu_request_serial = self.team_menu_request_serial + 1;
		break;
	case 19:   // spray decal — routes to the spray placer (server/sv_spray.qc)
		SV_PlayerSpray();
		break;
	default: break;
	}
	self.impulse = 0;
};

// --- Command continuation state ---
// Tracks the last input a client actually delivered. When a client's
// cl_netfps is lower than the server's tick rate (e.g. cl_netfps 20 vs
// sv_mintic 0.015), the server otherwise has nothing to simulate for
// them between inputs — their position freezes, snapshots broadcast the
// frozen position to other clients, then jump 50 ms when input finally
// arrives. Replaying the last input in SV_RunContinuation (called once
// per tick from StartFrame) keeps the simulation advancing so other
// clients see smooth motion. Gated by sv_command_continuation (default 1).
//
// Hook placement matters: PlayerPreThink is INPUT-DRIVEN (FTE only calls
// it when SV_RunCmd is processing a packet from that client), so putting
// the continuation there made it a no-op in exactly the scenario we're
// trying to fix. StartFrame runs every sv_mintic unconditionally.
.vector cmd_last_movevalues;
.float  cmd_last_buttons;
.vector cmd_last_angles;
.float  cmd_last_time;

// ---------------------------------------------------------------------------
// Drift-trace ring buffer — captures the last 32 server pmove ticks so we
// can dump the immediate pre-/post-switch context to console without
// flooding the log. Append per real usercmd, dump on weapon switch.
// ---------------------------------------------------------------------------
const float DRIFT_RING_SIZE = 32;
float  drift_t  [DRIFT_RING_SIZE];
float  drift_msec[DRIFT_RING_SIZE];
vector drift_mv [DRIFT_RING_SIZE];
float  drift_btn[DRIFT_RING_SIZE];
float  drift_wep[DRIFT_RING_SIZE];
vector drift_org[DRIFT_RING_SIZE];
vector drift_vel[DRIFT_RING_SIZE];
float  drift_idx;

void(float t_now, float msec, vector mv, float btn, float wep, vector org, vector vel) Drift_Append =
{
	drift_t  [drift_idx] = t_now;
	drift_msec[drift_idx] = msec;
	drift_mv [drift_idx] = mv;
	drift_btn[drift_idx] = btn;
	drift_wep[drift_idx] = wep;
	drift_org[drift_idx] = org;
	drift_vel[drift_idx] = vel;
	drift_idx = (drift_idx + 1) % DRIFT_RING_SIZE;
};

void(string label) Drift_Dump =
{
	float i;
	dprint(sprintf("--- %s drift ring (oldest first, %g entries) ---\n", label, DRIFT_RING_SIZE));
	for (i = 0; i < DRIFT_RING_SIZE; i++)
	{
		float ix = (drift_idx + i) % DRIFT_RING_SIZE;
		if (drift_t[ix] <= 0) continue;  // unfilled slot
		dprint(sprintf("[%s] t=%.4f msec=%.2f mv=%v btn=%g wep=%g\n",
			label, drift_t[ix], drift_msec[ix], drift_mv[ix], drift_btn[ix], drift_wep[ix]));
		dprint(sprintf("[%s]   org=%v vel=%v\n", label, drift_org[ix], drift_vel[ix]));
	}
};

// Run once per server tick from StartFrame. For each live, teamed player
// whose last command arrived more than 1.5 × sv_mintic ago, replay their
// last input as a synthetic pmove step so the server's simulation of
// them stays current. This hides low-cl_netfps players' input-rate
// stutter from everyone else.
//
// The 1.5 × sv_mintic threshold is deliberately loose: high-cl_netfps
// clients whose packets sometimes jitter 1 tick late aren't affected,
// only clients consistently below the server tick rate.
void() SV_RunCommandContinuation =
{
	if (cvar_string("sv_command_continuation") != ""
	    && !cvar("sv_command_continuation"))
		return;

	float tick = cvar("sv_mintic");
	if (tick <= 0) tick = 0.015;
	float stale_threshold = tick * 1.5;

	float debug = cvar("sv_debug_continuation");

	entity saved_self = self;
	entity e = player_chain_head;
	while (e)
	{
		if (e.classname != "player"
		    || e.is_dead
		    || e.player_team <= TEAM_NONE
		    || e.cmd_last_time <= 0)
		{
			e = e.chain;
			continue;
		}

		float since = time - e.cmd_last_time;
		if (since < stale_threshold)
		{
			e = e.chain;
			continue;
		}

		// Synthesize one tick using this player's last input.
		self = e;
		input_movevalues = self.cmd_last_movevalues;
		input_buttons    = self.cmd_last_buttons;
		input_angles     = self.cmd_last_angles;
		input_timelength = tick;
		// Mask off PM_BTN_GRAPPLE on synthesized ticks — without this an
		// AFK / dropped-packet player whose last input had the grapple
		// bind held would loop "still holding" forever and keep the rope
		// live.  W_GrappleHeldTick (real ticks only) then sees the next
		// real input as a falling edge and releases the hook.
		input_buttons = input_buttons & ~PM_BTN_GRAPPLE;

		if (round_phase == ROUND_PHASE_FREEZE)
		{
			input_movevalues_x = 0;
			input_movevalues_y = 0;
			input_buttons = input_buttons & ~1;
		}

		if (debug)
			dprint(sprintf("[cmd-cont] synth %s  since_last=%.3f  mv=(%.0f %.0f)  btn=%g\n",
				self.netname, since,
				input_movevalues_x, input_movevalues_y, input_buttons));

		PM_PlayerMove();
		SV_CheckTouchTriggers();
		PM_SyncPredictionProxy(self);

		// Bump cmd_last_time so we don't synth again next tick until
		// the real client is another tick overdue — one synthetic tick
		// per missed tick, not a burst of them.
		self.cmd_last_time = time;

		e = e.chain;
	}
	self = saved_self;
};

void() PlayerPreThink =
{
	TeamSelectionCheck();
	if (PlayerNeedsTeamSelection())
		return;

	// Dead players: allow team menu (impulse 28), suppress everything else
	if (self.is_dead)
	{
		if (self.impulse == 28)
			self.team_menu_request_serial = self.team_menu_request_serial + 1;
		self.impulse = 0;
		return;
	}

	// Freeze time: suppress primary attack but allow everything else
	if (round_phase == ROUND_PHASE_FREEZE)
		self.button0 = 0;

	CheckImpulses();
	// While carrying a prop, +attack THROWS it instead of firing.  The client
	// suppresses the fire button and sends `cmd throwprop` (see CSQC_Input_Frame
	// + the throwprop handler).  Defensively clear button0 here too so no weapon
	// auto-fires even if a client leaves the bit set.
	if (self.carried_prop != world || self.carried_ragdoll != world)
		self.button0 = 0;
	W_WeaponFrame();
	// Grapple press-and-hold edge detect — rising edge of PM_BTN_GRAPPLE
	// (+grapple / +button9) spawns the hook, falling edge releases it.
	// Runs BEFORE PullTick so a falling-edge release in the same tick
	// clears the hook before PullTick would re-assert grapple_rope_active.
	W_GrappleHeldTick();
	// Grappling-hook pull — additive force toward the anchor while the
	// rope is attached; gravity still applies through MOVETYPE_WALK so the
	// player swings under it.  No-op when no hook is out.
	W_GrapplePullTick();
	// HL2 prop carry — velocity-servo the held cabinet toward the hold point
	// (slides on walls, auto-drops when jammed; +attack throws). No-op when
	// carried_prop is world.
	Carry_Tick(self);
	// nettest gravity-gun ragdoll carry — velocity-servo the held corpse's pelvis toward the hold point
	// (limbs dangle; +attack throws via throwprop).  No-op unless carried_ragdoll is set.
	Ragdoll_CarryTick(self);
	// Gravity gun — +attack2 (held) rising/falling edge spins up / blasts the
	// black-hole; PullTick yanks all phys props toward the gather point each
	// frame while spinning.  No-op unless WEP_GRAVITYGUN is equipped + spinning.
	W_GravGun_HeldTick();
	W_GravGun_PullTick();
	W_GravGun_ShiftPropTick();   // gravity shift: tilt ODE phys props (cabinets) the new way
	// Defuse poll — runs every server frame on every alive player; cheap
	// single bit-test early-out when +use isn't held (see sh_wpn_cfc4.qc).
	C4_TickDefuseInteraction(self);
	// Momentary rotating-button poll — same per-frame held-+use pattern;
	// drives momentary_rot_button → momentary_door (see sv_momentary.qc).
	Momentary_TickInteraction(self);
	makevectors(self.v_angle);
	if (self.button2)
		PlayerJump();
	else
		self.flags = self.flags | FL_JUMPRELEASED;

	// Weapon state changes happen in PlayerPreThink, after SV_RunClientCommand
	// already synced the movement proxy. Sync again so owner-only CSQC snapshots
	// contain the post-weapon authoritative state for this frame.
	PM_SyncPredictionProxy(self);
};

// CS 1.6 / GoldSrc fall damage constants
float PLAYER_MAX_SAFE_FALL_SPEED = 580;
float PLAYER_FATAL_FALL_SPEED    = 1024;

void() PlayerCheckFallDamage =
{
    float onground;
    float damage;

    onground = (self.flags & FL_ONGROUND) > 0;

    // While airborne, store current downward speed each frame (not peak —
    // matches GoldSrc which uses instantaneous velocity, not accumulated)
    if (!onground)
        self.fall_velocity = -self.velocity_z;

    // Just landed
    if (onground && !self.was_onground
        && cvar("mp_falldamage")
        && self.fall_velocity > PLAYER_MAX_SAFE_FALL_SPEED
        && self.waterlevel == 0)   // any water at all prevents fall damage (GoldSrc behaviour)
    {
        // GoldSrc formula: damage = (fallVelocity - 580) * (100 / (1024 - 580))
        damage = (self.fall_velocity - PLAYER_MAX_SAFE_FALL_SPEED)
               * (100.0 / (PLAYER_FATAL_FALL_SPEED - PLAYER_MAX_SAFE_FALL_SPEED));
        damage = floor(damage);

        if (damage > 0)
        {
            self.health = self.health - damage;

            // Send damage flash only to the victim.  Must write the SAME
            // payload as the weapons path (sv_weapons.qc): dmg byte + 3
            // attacker-origin coords — the CSQC_EVENT_DAMAGE_FLASH receiver
            // reads all four.  Omitting the coords made the client read 12
            // bytes past this event into the next one (e.g. the fall-death
            // kill-feed below), desyncing the CSQC event stream → the
            // "Illegible server message" crash.  Fall damage has no external
            // attacker, so write the victim's own origin (same fallback the
            // weapons path uses → a non-directional flash, no hit arrow).
            if (SV_PlayerHasNetchan(self))   // skip bots (no netchan); engine-truth guard
            {
                msg_entity = self;
                WriteByte(MSG_ONE, SVC_CGAMEPACKET);
                WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_FLASH);
                WriteByte(MSG_ONE, bound(1, damage, 255));
                WriteCoord(MSG_ONE, self.origin_x);
                WriteCoord(MSG_ONE, self.origin_y);
                WriteCoord(MSG_ONE, self.origin_z);
            }

            if (self.health <= 0)
            {
                sound(self, CHAN_VOICE, "sounds/player/fallpain2.wav", 1, ATTN_NORM);
                self.deaths = self.deaths + 1;
                self.frags = self.frags - 1;

                SV_SendKillFeed(KILLFEED_NO_ATTACKER, num_for_edict(self) - 1,
                                KILL_CAUSE_FALL, 0, 0);

                // Deferred death — handled by StartFrame after mp_respawndelay
                self.is_dead = TRUE;
                PlayerRefreshScoreboardInfo(self);
                SH_PlayerAnim_Death();
                W_DropAllWeaponsOnDeath();
                self.death_time = time;
                self.solid = SOLID_NOT;
                self.velocity = '0 0 0';
                self.pm_movetype = PM_MOVETYPE_DEAD;
                PM_SyncPredictionProxy(self);
            }
            else
            {
                sound(self, CHAN_VOICE, "sounds/player/fallpain1.wav", 1, ATTN_NORM);
            }
        }
    }

    // Reset on landing (matches GoldSrc: flFallVelocity = 0 when onground)
    if (onground)
        self.fall_velocity = 0;

    self.was_onground = onground;
};

void(entity player) Player_VisualProxy_Sync;

void() PlayerPostThink =
{
    if (PlayerNeedsTeamSelection())
        return;

    // sv_gunkick: fold this tick's pending view-kick and decay the spring, mirroring
    // CSQC's post-fire/post-pmove call (cl_player.qc:1938).  The fire + bullet trace
    // ran earlier (PlayerPreThink W_WeaponFrame -> engine PM_Move), reading the
    // pre-fold kick; folding HERE keeps the server's penetrating-hitscan trace
    // following the recoil identically to the client.  Without this call the server
    // traced a perpetually-zero kick while the client's bullets followed the spray,
    // so the two diverged (growing across a sustained spray).
    SH_TickViewKickFrame();

    PlayerCheckFallDamage();
    SH_PlayerAnim_Update();
    Player_VisualProxy_Sync(self);
};

void() ClientKill =
{
	if (PlayerNeedsTeamSelection())
		return;

	self.frags = self.frags - 1;
	self.deaths = self.deaths + 1;

	{
		float slot = num_for_edict(self) - 1;
		SV_SendKillFeed(slot, slot, KILL_CAUSE_SUICIDE, 0, 0);
	}

	// Deferred death — handled by StartFrame after mp_respawndelay
	self.is_dead = TRUE;
	PlayerRefreshScoreboardInfo(self);
	SH_PlayerAnim_Death();
	W_DropAllWeaponsOnDeath();
	self.death_time = time;
	self.solid = SOLID_NOT;
	self.health = 0;
	self.velocity = '0 0 0';
	self.pm_movetype = PM_MOVETYPE_DEAD;
	PM_SyncPredictionProxy(self);
};

//called when a client connects to the server
void() ClientConnect =
{
	// print("Client connect\n");
};

// ============================================================
//  Player visual proxy — CSQC entity for full animation control
//
//  SendFlags sections: only the changed sections are written. POSE
//  (origin/angles/velocity) dirties every motion tick; ANIM (frame,
//  top gen, pitch, flags) dirties on animation events; IDENTITY
//  (weapon, skin, colormap, team_model, is_dead) almost never. Full
//  send is ~54 B; typical motion-only send is ~39 B. Mirrors the
//  prediction proxy's section split (PM_SF_MOVEMENT/WEAPON/AMMO).
// ============================================================

const float VP_SF_POSE     = 1;  // origin, angles, velocity
const float VP_SF_ANIM     = 2;  // frame, baseframe, v_angle_x, anim_top_gen, flags
const float VP_SF_IDENTITY = 4;  // weapon, skin, colormap, team_model byte, is_dead
const float VP_SF_GRAPPLE  = 8;  // grapple_rope_active (+ anchor when active) — remote ropes

// Cached "last-sent" values for fields that come from the owner (not
// mirrored on the proxy itself) or need encoding. Compared in
// Player_VisualProxy_Sync to decide which section bits to dirty.
.float vps_last_v_pitch;
.float vps_last_anim_top_gen;
.float vps_last_weaponstate;	// nettest killcam/spectate: remote viewmodel anim state
.float vps_last_wep_action;	// wep_action_id (mod 256) — change == a new weapon action started
.float vps_last_weapon;
.float vps_last_team_model;
.float vps_last_is_dead;
// Capped to 0..255 (single byte on the wire). Used by the CSQC predicted-
// death helper to decide whether a hit is lethal — without it, the client
// can't predict (would over-fire on every shot).
.float vps_last_health;
.float vps_last_bodygroup;
.float vps_last_life_serial;
// nettest server ragdoll: 1 = a server-side corpse_ragdoll is active for this corpse, so the client
// hides this proxy's animated mesh (the ragdoll renders in its place).  A plain live field written at
// the end of the VP_SF_IDENTITY section (Sync doesn't run on a corpse — sv_ragdoll.qc sets it + dirties).
.float vps_hide_ragdoll;
.float vis_last_pose_resync;

// Marks a proxy as a corpse (orphaned by Player_VisualProxy_DetachAsCorpse,
// called from PlayerKilled). Bypasses the owner-team check in
// Player_Visual_SendEntity so the body keeps streaming to clients —
// returning FALSE there causes the engine to drop the entity from
// snapshots regardless of PVSF_NOREMOVE.  Cleared by RoundRestart's
// corpse sweep when the round ends.
.float vis_is_corpse;

.entity player_visual_proxy;

// Pointer back to the most recently detached corpse for THIS player.
// Used by PlayerSpawn (gated on mp_deadbodys 0) to delete the lingering
// body before spawning a fresh proxy — keeps at most one corpse per
// player on the map.  When mp_deadbodys 1, this pointer is still
// tracked but PlayerSpawn ignores it and the corpse persists until
// the round-restart sweep.
.entity last_corpse;

float(entity playerent, float changedflags) Player_Visual_SendEntity =
{
	// Corpses (vis_is_corpse) bypass the owner-team check so the body
	// keeps streaming to clients. The pose / anim / identity fields
	// are frozen — Player_VisualProxy_Sync stops touching them once
	// the proxy is detached from the (now-respawning) player.
	if (!self.vis_is_corpse)
	{
		// Don't send if owner disconnected or has no team
		if (!self.owner || self.owner.player_team < TEAM_BLUE)
			return FALSE;
	}

	WriteByte(MSG_ENTITY, CSQC_ENT_PLAYER_VISUAL);
	WriteByte(MSG_ENTITY, num_for_edict(self.owner));

	float bits = changedflags & (VP_SF_POSE | VP_SF_ANIM | VP_SF_IDENTITY | VP_SF_GRAPPLE);
	WriteByte(MSG_ENTITY, bits);

	if (bits & VP_SF_POSE)
	{
		WriteCoord(MSG_ENTITY, self.origin_x);
		WriteCoord(MSG_ENTITY, self.origin_y);
		WriteCoord(MSG_ENTITY, self.origin_z);
		WriteFloat(MSG_ENTITY, self.angles_x);
		WriteFloat(MSG_ENTITY, self.angles_y);
		WriteFloat(MSG_ENTITY, self.angles_z);
		WriteCoord(MSG_ENTITY, self.velocity_x);
		WriteCoord(MSG_ENTITY, self.velocity_y);
		WriteCoord(MSG_ENTITY, self.velocity_z);
	}

	if (bits & VP_SF_ANIM)
	{
		WriteByte(MSG_ENTITY, self.frame);
		WriteByte(MSG_ENTITY, self.baseframe);
		WriteFloat(MSG_ENTITY, self.vps_last_v_pitch);
		WriteFloat(MSG_ENTITY, self.flags);
		WriteByte(MSG_ENTITY, self.vps_last_anim_top_gen);
		WriteByte(MSG_ENTITY, self.vps_last_weaponstate);	// nettest killcam/spectate
		WriteByte(MSG_ENTITY, self.vps_last_wep_action);
	}

	if (bits & VP_SF_IDENTITY)
	{
		WriteByte(MSG_ENTITY, self.vps_last_weapon);
		WriteByte(MSG_ENTITY, self.skin);
		WriteByte(MSG_ENTITY, self.colormap);
		WriteByte(MSG_ENTITY, self.vps_last_team_model);
		WriteByte(MSG_ENTITY, self.vps_last_is_dead);
		WriteByte(MSG_ENTITY, self.vps_last_health);
		// Bodygroup bitfield (bit 0 = C4 backpack) + life generation.
		// Mirrors the CSQC reader (vis_bodygroup / vis_life_serial).
		WriteByte(MSG_ENTITY, self.vps_last_bodygroup);
		WriteByte(MSG_ENTITY, self.vps_last_life_serial);
		// nettest server ragdoll: hide-mesh flag (matched read at the END of the CSQC IDENTITY reader).
		WriteByte(MSG_ENTITY, self.vps_hide_ragdoll);
	}

	// Grapple rope (broadcast so everyone sees the rope, not just the owner).
	// The player END of the rope is this proxy's (already-smoothed) origin; only
	// the anchor + active flag travel here.  Anchor coords are gated on the active
	// flag so a release update is a single byte.  MUST match the CSQC reader.
	if (bits & VP_SF_GRAPPLE)
	{
		WriteByte(MSG_ENTITY, self.grapple_rope_active);
		if (self.grapple_rope_active)
		{
			WriteCoord(MSG_ENTITY, self.grapple_anchor_x);
			WriteCoord(MSG_ENTITY, self.grapple_anchor_y);
			WriteCoord(MSG_ENTITY, self.grapple_anchor_z);
		}
	}

	return TRUE;
};

void(entity player) Player_VisualProxy_Ensure =
{
	entity vis = player.player_visual_proxy;
	// Defensive: if the stored reference points at something that ISN'T a
	// player_visual_proxy (classname check), the pointer is stale / wrong
	// and would cause Player_VisualProxy_Sync to call setorigin on the
	// wrong entity (e.g. a func_breakable, moving it to the player's pos).
	// Force a fresh spawn in that case and log so we can trace the cause.
	if (vis && vis.classname != "player_visual_proxy")
	{
		bprint(PRINT_HIGH, sprintf("^1[vis]^7 player %s had stale proxy ref: ent #%g classname='%s' — respawning\n",
		                           player.netname, num_for_edict(vis), vis.classname));
		player.player_visual_proxy = world;
		vis = world;
	}
	if (!vis)
	{
		vis = spawn();
		vis.classname = "player_visual_proxy";
		vis.owner = player;
		vis.movetype = MOVETYPE_NONE;
		vis.solid = SOLID_NOT;
		// PVSF_USEPHS: send the proxy update over the broader PHS region
		// instead of strict PVS so a cross-map teleport (a round-restart
		// spawn outside the viewer's PVS) still delivers the new origin.
		// NOREMOVE is deliberately NOT set on LIVE proxies: with it, an enemy
		// who leaves the viewer's PHS stays CACHED frozen at their last-seen
		// position — the "enemy standing at their spawn the whole round until
		// they move into view" bug — because the engine then sends neither
		// further updates nor a remove.  Plain PHS-culling (no NOREMOVE)
		// removes the proxy when the player is genuinely out of range and
		// re-adds it at the correct CURRENT position when they return.
		// (Corpses DO keep NOREMOVE — set separately in DetachAsCorpse — and
		// are explicitly retired at round end via VisProxy_RetireCorpse.)
		vis.pvsflags = PVSF_USEPHS;
		setmodel(vis, "models/player/leet/leet.iqm"); // default until model applied
		vis.SendEntity = Player_Visual_SendEntity;
		player.player_visual_proxy = vis;
	}

	// Apply correct model for team+index (runs every ensure, not just first create)
	entity oldself = self;
	self = player;
	PlayerApplyModel();
	self = oldself;
};

// Convert the dying player's visual proxy into a frozen corpse:
//   1. push one final sync so the proxy carries the death-pose frame
//      that PlayerKilled just set on the player (without this, the
//      next PlayerPostThink sync would no-op because we detach below);
//   2. flip vis_is_corpse so Player_Visual_SendEntity bypasses the
//      owner-team check and keeps streaming;
//   3. detach from the player so PlayerSpawn's Player_VisualProxy_Ensure
//      spawns a fresh proxy on respawn instead of reusing the corpse.
//
// The corpse persists until RoundRestart's sweep removes it. Works
// for both TDM (immediate auto-respawn) and Elimination (death-cam
// then spectate) — neither path touches a detached proxy.
void(entity player) Player_VisualProxy_DetachAsCorpse;
void(entity player) Player_VisualProxy_Sync;
void(entity corpse) VisProxy_RetireCorpse;   // defined in sv_main.qc (compiled later)

// Server-side corpse settle.  A detached corpse is MOVETYPE_NONE (the engine
// never ticks physics on it), so a player who dies airborne hangs at the death
// height.  This think drops the corpse under gravity a step at a time, re-
// networking each step via SendFlags (Player_VisualProxy_Sync no longer runs on
// a detached proxy), and re-freezes it the instant it lands.  Short-lived: it
// stops as soon as the floor trace blocks.
const float VISCORPSE_SETTLE_DT = 0.05;
.float vis_sinking;		// corpse despawn: TRUE while sinking into the ground (idempotent guard)
.float vis_sink_endtime;	// corpse despawn: when the sink finishes -> the real removal
void() VisProxy_CorpseSettleThink =
{
	if (self.classname != "player_visual_proxy" || !self.vis_is_corpse)
		return;		// retired / repurposed — stop ticking

	float grav = cvar("sv_gravity");
	if (grav <= 0) grav = 800;
	self.velocity_z = self.velocity_z - grav * VISCORPSE_SETTLE_DT;

	vector dest = self.origin + self.velocity * VISCORPSE_SETTLE_DT;
	tracebox(self.origin, self.mins, self.maxs, dest, MOVE_NOMONSTERS, self);
	setorigin(self, trace_endpos);
	self.SendFlags |= VP_SF_POSE;		// re-network the new corpse origin

	if (trace_fraction < 1)			// landed — settle + re-freeze
	{
		self.velocity = '0 0 0';
		self.SendFlags |= VP_SF_POSE;
		self.nextthink = 0;
		return;
	}
	self.nextthink = time + VISCORPSE_SETTLE_DT;
};

void(entity player) Player_VisualProxy_DetachAsCorpse =
{
	entity vis = player.player_visual_proxy;
	if (!vis || vis.classname != "player_visual_proxy")
		return;

	// Final sync — pushes the death frame / final origin / SendFlags
	// dirty bit so all clients receive the death pose before we orphan.
	Player_VisualProxy_Sync(player);

	vis.vis_is_corpse = TRUE;

	// Once detached, the corpse is fully passive on the server side:
	//   - movetype MOVETYPE_NONE  → engine never ticks physics on it
	//   - solid    SOLID_NOT      → no collision tracing against it
	//   - .think   unset          → no QC think scheduled
	//   - nextthink 0             → engine won't fire one
	//   - SendFlags only dirties on field changes, and after detach
	//     player.player_visual_proxy = world means Sync early-returns,
	//     so nothing dirties the corpse — only the initial post-death
	//     snapshot crosses the wire.
	// PVSF_USEPHS is dropped here: the original setting widened the
	// proxy's send region for live cross-PVS teleports — a frozen
	// corpse never moves, so strict PVS is enough and saves bandwidth.
	// PVSF_NOREMOVE retained so a viewer briefly out of PVS doesn't
	// see the corpse blink out and back.
	vis.pvsflags = PVSF_NOREMOVE;

	// Corpse cap (mp_deadbodies).  >=1: keep at most ONE body per player —
	// retire this player's PREVIOUS corpse now so only the latest remains (it
	// survives respawn, unlike the 0 case which clears it in PlayerSpawn).
	// VisProxy_RetireCorpse, NOT bare remove(): a PVSF_NOREMOVE corpse bare-
	// removed never networks CSQC_Ent_Remove and would ghost on clients.
	if (cvar("mp_deadbodies") >= 1
	    && player.last_corpse
	    && player.last_corpse.classname == "player_visual_proxy"
	    && player.last_corpse.vis_is_corpse)
		VisProxy_RetireCorpse(player.last_corpse);
	player.last_corpse = vis;

	// If the player died airborne, let the corpse FALL to the floor instead of
	// hanging at the death height.  Give the floor trace the player's own box so
	// it rests like they'd stand/crouch; the settle think re-syncs the drop and
	// re-freezes on landing.  A grounded death needs no settle (already on floor).
	if (!(player.flags & FL_ONGROUND))
	{
		setsize(vis, player.mins, player.maxs);
		vis.velocity   = '0 0 0';
		vis.think      = VisProxy_CorpseSettleThink;
		vis.nextthink  = time + VISCORPSE_SETTLE_DT;
	}

	player.player_visual_proxy = world;
};

void(entity player) Player_VisualProxy_Sync =
{
	entity vis = player.player_visual_proxy;
	if (!vis) return;
	// Defensive: REFUSE to setorigin if vis isn't actually a visual proxy.
	// Without this guard, a stale/miscast pointer would yank a random entity
	// (commonly a func_breakable on map bounds) to the player's origin —
	// the "breakable attached to player" bug.
	if (vis.classname != "player_visual_proxy")
	{
		bprint(PRINT_HIGH, sprintf("^1[vis]^7 Sync refused: player %s .player_visual_proxy=ent #%g classname='%s'\n",
		                           player.netname, num_for_edict(vis), vis.classname));
		player.player_visual_proxy = world;
		return;
	}
	// Compute next values.  Angles: untwisted aim direction — CSQC
	// applies its own leg_twist + subblendfrac.  The server's angles_y
	// includes leg_twist for MOVE_HITMODEL traces, but the proxy must
	// not double-apply it.  For dead players, freeze body yaw at its
	// last-live value: their v_angle still tracks mouse input (spectator
	// camera uses it), and piping that into the corpse makes the body
	// spin with the camera.
	vector next_angles = '0 0 0';
	if (player.is_dead)
		next_angles_y = vis.angles_y;  // keep whatever we last sent
	else
		next_angles_y = player.v_angle_y;

	float next_tmbyte;
	if (player.player_model_index == 5)
		next_tmbyte = 255;          // sentinel: sini (team-independent)
	else if (player.player_model_index == 6)
		next_tmbyte = 254;          // sentinel: chickenman (team-independent)
	else if (player.player_model_index == 7)
		next_tmbyte = 253;          // sentinel: numberK (team-independent)
	else if (player.player_model_index == 8)
		next_tmbyte = 252;          // sentinel: kilmer (team-independent)
	else
		next_tmbyte = (player.player_team - 1) * 4
		            + bound(0, player.player_model_index, TEAM_MODEL_COUNT - 1);

	float next_is_dead = player.is_dead ? 1 : 0;

	// Diff each section to decide which SendFlags bits to dirty.
	float bits = 0;

	// POSE keepalive: without this, a player standing perfectly still
	// produces zero POSE updates (origin/angles/velocity all unchanged),
	// so the CSQC interp ring buffer goes stale and cl_interp_time can
	// no longer bracket the render time.
	//
	// Interval must be <= cl_interp_time for any client that runs interp
	// to reliably bracket the render time — otherwise you get periodic
	// "interp buffer miss" lines for the last (interval - cl_interp_time)
	// ms of every keepalive cycle. At 64 tick with cl_interp_time 0.031,
	// a 62 ms keepalive misses half the time. Every-tick keepalive
	// (~15 ms at 64 tick) safely covers cl_interp_time values of 0.031
	// and above. Bandwidth cost: ~400 B/s per stationary player. Cheap.
	//
	// Tunable via sv_pose_keepalive_ticks (default 1 = every tick).
	// Computed once per tick in sv_main.qc StartFrame so this hot path
	// doesn't re-read the cvars on every player.
	float keepalive_interval = sv_cached_pose_keepalive_interval;

	if (vis.origin != player.origin
	    || vis.angles != next_angles
	    || vis.velocity != player.velocity
	    || (time - vis.vis_last_pose_resync) > keepalive_interval)
		bits |= VP_SF_POSE;

	float next_wep_action = player.wep_action_id - floor(player.wep_action_id / 256) * 256;
	if (vis.frame != player.frame
	    || vis.baseframe != player.baseframe
	    || vis.flags != player.flags
	    || vis.vps_last_v_pitch != player.v_angle_x
	    || vis.vps_last_anim_top_gen != player.anim_top_gen
	    || vis.vps_last_weaponstate != player.weaponstate
	    || vis.vps_last_wep_action != next_wep_action)
		bits |= VP_SF_ANIM;

	float next_health = bound(0, player.health, 255);
	// Bodygroup bit 0 = C4 backpack visible (carried by a Red player but
	// not actively held).  Mirrored to the client as vis_bodygroup.
	float next_bodygroup = 0;
	if (player.player_team == TEAM_RED && player.ammo_cfc4 > 0 && player.weapon != WEP_CFC4)
		next_bodygroup |= 1;
	// Life generation (1..255, byte-wrap, never 0) — hitclaims carry this
	// so a stale corpse / old-life proxy can't damage the respawned player.
	float next_life_serial = player.player_life_serial;
	if (next_life_serial <= 0)
		next_life_serial = 1;
	next_life_serial = next_life_serial - floor(next_life_serial / 256) * 256;
	if (next_life_serial <= 0)
		next_life_serial = 1;
	if (vis.vps_last_weapon != player.weapon
	    || vis.skin != player.skin
	    || vis.colormap != player.colormap
	    || vis.vps_last_team_model != next_tmbyte
	    || vis.vps_last_is_dead != next_is_dead
	    || vis.vps_last_health != next_health
	    || vis.vps_last_bodygroup != next_bodygroup
	    || vis.vps_last_life_serial != next_life_serial)
		bits |= VP_SF_IDENTITY;

	// Grapple rope: dirty on a flag flip, or (while active) whenever the anchor
	// moves — the hook flies during throw, then sits at a fixed world point once
	// attached, so a settled rope sends nothing.
	if (vis.grapple_rope_active != player.grapple_rope_active
	    || (player.grapple_rope_active && vis.grapple_anchor != player.grapple_anchor))
		bits |= VP_SF_GRAPPLE;

	// Apply new values to the proxy unconditionally — the cached
	// fields are the "last sent" record, so the next compare sees
	// these as the baseline.
	setorigin(vis, player.origin);
	vis.angles    = next_angles;
	vis.velocity  = player.velocity;
	vis.frame     = player.frame;
	vis.baseframe = player.baseframe;
	vis.flags     = player.flags;
	vis.skin      = player.skin;
	vis.colormap  = player.colormap;
	vis.vps_last_v_pitch      = player.v_angle_x;
	vis.vps_last_anim_top_gen = player.anim_top_gen;
	vis.vps_last_weaponstate  = player.weaponstate;
	vis.vps_last_wep_action   = next_wep_action;
	vis.vps_last_weapon       = player.weapon;
	vis.vps_last_team_model   = next_tmbyte;
	vis.vps_last_is_dead      = next_is_dead;
	vis.vps_last_health       = next_health;
	vis.vps_last_bodygroup    = next_bodygroup;
	vis.vps_last_life_serial  = next_life_serial;
	vis.grapple_rope_active   = player.grapple_rope_active;   // last-sent cache + proxy value
	vis.grapple_anchor        = player.grapple_anchor;

	if (bits & VP_SF_POSE)
		vis.vis_last_pose_resync = time;

	if (bits)
		vis.SendFlags |= bits;
};

float(entity playerent, float changedflags) PM_PredictionProxy_SendEntity =
{
	if (playerent != self.drawonlytoclient)
		return FALSE;

	WriteByte(MSG_ENTITY, PM_CSQC_PROXY_VERSION);
	// Baseline calls pass 0xFFFFFF meaning "all changed" — mask to the bits
	// we actually use so WriteByte doesn't truncate-and-warn.
	WriteByte(MSG_ENTITY, changedflags & (PM_SF_MOVEMENT | PM_SF_WEAPON_STATE | PM_SF_AMMO));

	if (changedflags & PM_SF_MOVEMENT)
	{
		// Full 32-bit float precision for origin and velocity — NOT
		// WriteCoord (which quantizes to 1/8 qu).  Coord rounding was
		// the dominant source of client-vs-server pmove disagreement:
		// every reconcile, sv_confirmed_origin was the rounded value,
		// replay ran from there, predicted_player drifted ~0.1-0.3 qu
		// per reconcile from float-precision live.  Switching to float
		// here makes the prediction proxy carry the exact server pmove
		// state, eliminating the rounding-induced drift at its source.
		// Cost: +6 bytes per movement section (3 axes × 2 fields × 2 B
		// extra) — negligible.
		//
		// Paired CSQC reader: client/cl_player.qc CSQC_PlayerVisual_Update /
		// proxy parser must use readfloat() for these same fields.
		WriteFloat(MSG_ENTITY, self.origin_x);
		WriteFloat(MSG_ENTITY, self.origin_y);
		WriteFloat(MSG_ENTITY, self.origin_z);

		WriteFloat(MSG_ENTITY, self.velocity_x);
		WriteFloat(MSG_ENTITY, self.velocity_y);
		WriteFloat(MSG_ENTITY, self.velocity_z);

		// view_ofs stays at WriteCoord — it changes infrequently
		// (duck/stand transitions) and 1/8 qu precision is well below
		// the smallest meaningful change.
		WriteCoord(MSG_ENTITY, self.view_ofs_x);
		WriteCoord(MSG_ENTITY, self.view_ofs_y);
		WriteCoord(MSG_ENTITY, self.view_ofs_z);

		// `flags` kept as float — FTE's FL_* bitset can use bits above
		// byte range (FL_DUCKING=0x4000, FL_NOTARGET=0x40000 on some
		// builds) so float (same 4 B as long) retains full width.
		WriteFloat(MSG_ENTITY, self.flags);
		// Small-range integer / bitfield fields re-encoded to save wire:
		//   pm_movetype    — enum, ≤ ~40           → byte
		//   pm_jump_held   — 0/1                   → byte
		//   pm_jump_msec   — 0..50  (clamp-reset)  → short (headroom for future)
		//   pm_in_duck     — 0/1                   → byte
		//   pm_duck_msec   — 0..1000               → short
		//   pm_oldbuttons  — 8-bit button bitmask  → byte
		// Saves 16 B per movement update vs the old WriteFloat-everything layout.
		WriteByte (MSG_ENTITY, self.pm_movetype);
		WriteByte (MSG_ENTITY, self.pm_jump_held);
		WriteShort(MSG_ENTITY, self.pm_jump_msec);
		WriteFloat(MSG_ENTITY, self.pm_waterjumptime);
		WriteByte (MSG_ENTITY, self.pm_in_duck);
		WriteShort(MSG_ENTITY, self.pm_duck_msec);
		WriteByte (MSG_ENTITY, self.pm_oldbuttons);
		WriteFloat(MSG_ENTITY, self.pm_timecarry);
		WriteFloat(MSG_ENTITY, self.pm_teleport_time);
		WriteFloat(MSG_ENTITY, self.pm_ladder_detach_time);
		WriteFloat(MSG_ENTITY, self.pm_fuser2);
		WriteFloat(MSG_ENTITY, self.spread_penalty);
		WriteFloat(MSG_ENTITY, self.fire_spread_penalty);
		WriteFloat(MSG_ENTITY, self.pm_step_time);
		// Movement-tail state (slide-friction, jump-lag, grapple rope,
		// codstamina, fire-suppress) — mirrors the CSQC reader in
		// cl_player.qc PM_SF_MOVEMENT field-for-field.  Time fields are
		// sent as remaining-seconds (client rebuilds absolute against its
		// local `time`), matching attack_finished / wep_anim_start above.
		WriteByte (MSG_ENTITY, self.slide_friction_active);
		WriteFloat(MSG_ENTITY, max(0, self.pm_jump_lag_end - time));
		// Post-jump ground-snap suppress window (remaining-seconds, same
		// encoding as pm_jump_lag_end above). Must be replicated or the
		// reconcile replay re-grounds a sub-180 (codstamina/grapple) jump at
		// high ping → the "stuck/flicker" symptom.
		WriteFloat(MSG_ENTITY, max(0, self.pm_jump_groundstick_off_until - time));
		WriteByte (MSG_ENTITY, self.grapple_rope_active);
		WriteCoord(MSG_ENTITY, self.grapple_anchor_x);
		WriteCoord(MSG_ENTITY, self.grapple_anchor_y);
		WriteCoord(MSG_ENTITY, self.grapple_anchor_z);
		WriteByte (MSG_ENTITY, self.grapple_attached);
		WriteByte (MSG_ENTITY, self.pm_grapple_held_last);
		WriteFloat(MSG_ENTITY, self.codstamina);
		WriteByte (MSG_ENTITY, self.codstamina_punished);
		WriteFloat(MSG_ENTITY, max(0, self.pm_fire_suppress_until - time));
		// HL2 carry: lowered-weapon flag, replicated so CSQC's fire-gate /
		// lower envelope match the server (mirrors grapple_rope_active).
		WriteByte (MSG_ENTITY, self.pm_carrying);
		// func_vehicle: replicated driving flag (drives the pmove driver-lock + fire-block)
		WriteByte (MSG_ENTITY, self.pm_driving);
		// prop_car: replicated in-car flag (pmove input-zero + fire-block + third-person camera)
		WriteByte (MSG_ENTITY, self.pm_incar);
		// prop_car: the driven car's origin + velocity so CSQC extrapolates a render-smooth chase cam
		// (the follow cam anchored to the tick-pinned player "stepped").  Only when actually in a car.
		if (self.pm_incar)
		{
			WriteCoord(MSG_ENTITY, self.car_driving.origin_x);
			WriteCoord(MSG_ENTITY, self.car_driving.origin_y);
			WriteCoord(MSG_ENTITY, self.car_driving.origin_z);
			WriteCoord(MSG_ENTITY, self.car_driving.velocity_x);
			WriteCoord(MSG_ENTITY, self.car_driving.velocity_y);
			WriteCoord(MSG_ENTITY, self.car_driving.velocity_z);
		}
	}

	if (changedflags & PM_SF_WEAPON_STATE)
	{
		// wep_anim_start sent as elapsed seconds so client rebuilds absolute cltime.
		WriteByte(MSG_ENTITY, self.slot_primary);
		WriteByte(MSG_ENTITY, self.slot_secondary);
		WriteByte(MSG_ENTITY, self.slot_melee);
		WriteByte(MSG_ENTITY, self.slot_utility);
		WriteByte(MSG_ENTITY, self.weapon);
		WriteByte(MSG_ENTITY, self.previous_weapon);
		WriteByte(MSG_ENTITY, self.weaponstate);
		// Signed 32-bit — wep_action_id is a monotonic counter used as the
		// deterministic spread seed. WriteByte truncated it at 256, silently
		// desyncing server vs client spread mid-round (predicted bullet flies
		// one way, authoritative bullet flies another → "silent shot" bug).
		WriteLong(MSG_ENTITY, self.wep_action_id);
		WriteFloat(MSG_ENTITY, max(0, self.attack_finished - time));
		WriteFloat(MSG_ENTITY, (self.wep_anim_start > 0) ? max(0, time - self.wep_anim_start) : 0);
		WriteByte(MSG_ENTITY, self.zoomstage);
		WriteByte(MSG_ENTITY, self.snowball_has_slingshot ? 1 : 0);
		WriteByte(MSG_ENTITY, self.snowball_use_slingshot ? 1 : 0);
		// Speed-factor blend state — preserves in-flight transition
		// across reconcile so client replay and server pmove stay
		// synchronized through ping-window weapon switches.
		WriteFloat(MSG_ENTITY, self.pm_weapon_blend_progress);
		WriteFloat(MSG_ENTITY, self.pm_weapon_prev_factor);
		// sv_gunkick authoritative camera-kick state — the client overwrites
		// its locally-integrated kick with these each snapshot and keeps
		// integrating between snapshots.  Mirrors the CSQC reader.
		WriteFloat(MSG_ENTITY, self.view_kick_pitch);
		WriteFloat(MSG_ENTITY, self.view_kick_yaw);
		WriteFloat(MSG_ENTITY, self.view_kick_pitch_vel);
		WriteFloat(MSG_ENTITY, self.view_kick_yaw_vel);
		WriteByte (MSG_ENTITY, self.view_kick_burst_idx);
	}

	if (changedflags & PM_SF_AMMO)
	{
		// Compact slot-ammo bitmask. Primary/secondary ammo is canonical;
		// utilities remain separate because utility inventory is multi-carry.
		float m0 = self.pm_ammo_mb0;
		float m1 = self.pm_ammo_mb1;

		WriteByte(MSG_ENTITY, m0);
		WriteByte(MSG_ENTITY, m1);

		if (m0 &   1) WriteByte(MSG_ENTITY, self.slot_primary_mag);
		if (m0 &   2) WriteByte(MSG_ENTITY, self.slot_primary_ammo);
		if (m0 &   4) WriteByte(MSG_ENTITY, self.slot_primary_aux);
		if (m0 &   8) WriteByte(MSG_ENTITY, self.slot_secondary_mag);
		if (m0 &  16) WriteByte(MSG_ENTITY, self.slot_secondary_ammo);
		if (m0 &  32) WriteByte(MSG_ENTITY, self.slot_secondary_aux);
		if (m0 &  64) WriteByte(MSG_ENTITY, self.ammo_hlgrenade);
		if (m0 & 128) WriteByte(MSG_ENTITY, self.ammo_snowball);

		if (m1 &   1) WriteByte(MSG_ENTITY, self.ammo_cshegrenade);
		if (m1 &   2) WriteByte(MSG_ENTITY, self.ammo_csflashbang);
		if (m1 &   4) WriteByte(MSG_ENTITY, self.ammo_cssmokegrenade);
		if (m1 &   8) WriteByte(MSG_ENTITY, self.ammo_cfc4);

		// Consume the mask now that we've written all pending fields —
		// PM_SyncPredictionProxy accumulates bits with |= across multiple
		// sync calls per tick, so without this clear the next delta would
		// re-send the same fields.  Safe because SendEntity runs once per
		// delta (pm_prediction_proxy uses drawonlytoclient = one player).
		self.pm_ammo_mb0 = 0;
		self.pm_ammo_mb1 = 0;
		self.pm_ammo_mb2 = 0;
		self.pm_ammo_mb3 = 0;
		self.pm_ammo_mb4 = 0;
		self.pm_ammo_mb5 = 0;
		self.pm_ammo_mb6 = 0;
	}

	return TRUE;
};

// Dropped-weapon CSQC replication — networks weapon id, slot, origin,
// model, and mag/ammo/silencer so CSQC can predict pickup (instant
// viewmodel swap AND ammo display on touch for high-ping players).
// Body lives here (not in sv_weapons.qc) so the per-weapon mag_*/ammo_*
// fields are already declared by this point in the compile order.
// Called for both player-dropped weapons (via weapon_become_solid) and
// map-placed weapons (via W_RegisterMapWeapon) — see sv_weapons.qc.
// Dispatch table must stay in lock-step with CSQC_ApplyPickupAmmo in
// client/cl_weapons.qc; any drift shows wrong ammo for one proxy tick.
float(entity playerent, float changedflags) dropped_weapon_SendEntity =
{
	WriteByte(MSG_ENTITY, CSQC_ENT_DROPPED_WEAPON);
	WriteByte(MSG_ENTITY, self.weapon);
	WriteByte(MSG_ENTITY, self.weapon_slot);
	WriteCoord(MSG_ENTITY, self.origin_x);
	WriteCoord(MSG_ENTITY, self.origin_y);
	WriteCoord(MSG_ENTITY, self.origin_z);
	// Velocity for CSQC extrap (cl_tosssmooth.qc). Lets the client
	// project the entity forward between snapshots so the visual flight
	// is smooth instead of snapping to the latest authoritative origin
	// every send tick. Costs 12 B per send — trivial vs the bandwidth
	// already used by the rest of the payload.
	WriteCoord(MSG_ENTITY, self.velocity_x);
	WriteCoord(MSG_ENTITY, self.velocity_y);
	WriteCoord(MSG_ENTITY, self.velocity_z);
	// Angular velocity lets CSQC visually tumble ODE drops between server
	// samples instead of only snapping to the latest authoritative angles.
	WriteCoord(MSG_ENTITY, self.avelocity_x);
	WriteCoord(MSG_ENTITY, self.avelocity_y);
	WriteCoord(MSG_ENTITY, self.avelocity_z);
	WriteString(MSG_ENTITY, self.model);

	WriteByte(MSG_ENTITY, self.weapon_drop_mag);
	WriteByte(MSG_ENTITY, self.weapon_drop_ammo);
	WriteByte(MSG_ENTITY, self.weapon_drop_aux);

	// Classic-Quake spin opt-in (per-weapon flag on the dropped entity).
	// CSQC derives rotation locally from cltime for spinning weapons.
	WriteByte(MSG_ENTITY, self.dropped_spin ? 1 : 0);

	// Server angles. CSQC ignores these when dropped_spin is set, uses them
	// directly for physics drops, and keeps non-physics non-spin drops upright.
	WriteCoord(MSG_ENTITY, self.angles_x);
	WriteCoord(MSG_ENTITY, self.angles_y);
	WriteCoord(MSG_ENTITY, self.angles_z);

	// Physics drops are server-authoritative ODE bodies. CSQC uses this to
	// disable toss extrapolation/fake angular prediction for those entities.
	WriteByte(MSG_ENTITY, (self.movetype == MOVETYPE_PHYSICS || self.weapon_physdrop_sleeping) ? 1 : 0);
	return TRUE;
};

void(entity player) PM_SyncPredictionProxy =
{
	entity proxy;
	float bits = 0;

	proxy = player.pm_prediction_proxy;
	if (!proxy)
		return;

	proxy.owner = player;
	proxy.drawonlytoclient = player;
	// Link proxy at eye position for PVS (ducked origin can go below floor).
	// Then restore .origin to the real player origin for SendEntity to write.
	setorigin(proxy, player.origin + player.view_ofs);

	// Detect movement-section changes
	if (proxy.origin              != player.origin ||
	    proxy.velocity            != player.velocity ||
	    proxy.view_ofs            != player.view_ofs ||
	    proxy.flags               != player.flags ||
	    proxy.pm_movetype         != player.pm_movetype ||
	    proxy.pm_jump_held        != player.pm_jump_held ||
	    proxy.pm_jump_msec        != player.pm_jump_msec ||
	    proxy.pm_waterjumptime    != player.pm_waterjumptime ||
	    proxy.pm_in_duck          != player.pm_in_duck ||
	    proxy.pm_duck_msec        != player.pm_duck_msec ||
	    proxy.pm_oldbuttons       != player.pm_oldbuttons ||
	    proxy.pm_timecarry        != player.pm_timecarry ||
	    proxy.pm_teleport_time    != player.pm_teleport_time ||
	    proxy.pm_ladder_detach_time != player.pm_ladder_detach_time ||
	    proxy.pm_fuser2           != player.pm_fuser2 ||
	    proxy.spread_penalty      != player.spread_penalty ||
	    proxy.fire_spread_penalty != player.fire_spread_penalty ||
	    proxy.pm_step_time        != player.pm_step_time ||
	    proxy.slide_friction_active != player.slide_friction_active ||
	    proxy.pm_jump_lag_end     != player.pm_jump_lag_end ||
	    proxy.pm_jump_groundstick_off_until != player.pm_jump_groundstick_off_until ||
	    proxy.grapple_rope_active != player.grapple_rope_active ||
	    proxy.grapple_anchor      != player.grapple_anchor ||
	    proxy.grapple_attached    != player.grapple_attached ||
	    proxy.pm_grapple_held_last != player.pm_grapple_held_last ||
	    proxy.codstamina          != player.codstamina ||
	    proxy.codstamina_punished != player.codstamina_punished ||
	    proxy.pm_fire_suppress_until != player.pm_fire_suppress_until ||
	    proxy.pm_carrying != player.pm_carrying ||
	    proxy.pm_driving != player.pm_driving ||
	    proxy.pm_incar != player.pm_incar)
		bits |= PM_SF_MOVEMENT;

	// Detect weapon-state changes
	if (proxy.slot_primary    != player.slot_primary ||
	    proxy.slot_secondary  != player.slot_secondary ||
	    proxy.slot_melee      != player.slot_melee ||
	    proxy.slot_utility    != player.slot_utility ||
	    proxy.weapon          != player.weapon ||
	    proxy.previous_weapon != player.previous_weapon ||
	    proxy.weaponstate     != player.weaponstate ||
	    proxy.wep_action_id   != player.wep_action_id ||
	    proxy.attack_finished != player.attack_finished ||
	    proxy.wep_anim_start  != player.wep_anim_start ||
	    proxy.zoomstage       != player.zoomstage ||
	    proxy.snowball_has_slingshot != player.snowball_has_slingshot ||
	    proxy.snowball_use_slingshot != player.snowball_use_slingshot ||
	    proxy.pm_weapon_blend_progress != player.pm_weapon_blend_progress ||
	    proxy.pm_weapon_prev_factor    != player.pm_weapon_prev_factor ||
	    proxy.view_kick_pitch     != player.view_kick_pitch ||
	    proxy.view_kick_yaw       != player.view_kick_yaw ||
	    proxy.view_kick_pitch_vel != player.view_kick_pitch_vel ||
	    proxy.view_kick_yaw_vel   != player.view_kick_yaw_vel ||
	    proxy.view_kick_burst_idx != player.view_kick_burst_idx)
		bits |= PM_SF_WEAPON_STATE;

	// Ammo diff for canonical slot ammo + multi-carry utility counts.
	float mb0 = 0, mb1 = 0, mb2 = 0, mb3 = 0, mb4 = 0, mb5 = 0, mb6 = 0;

	if (proxy.slot_primary_mag     != player.slot_primary_mag)     mb0 |= 1;
	if (proxy.slot_primary_ammo    != player.slot_primary_ammo)    mb0 |= 2;
	if (proxy.slot_primary_aux     != player.slot_primary_aux)     mb0 |= 4;
	if (proxy.slot_secondary_mag   != player.slot_secondary_mag)   mb0 |= 8;
	if (proxy.slot_secondary_ammo  != player.slot_secondary_ammo)  mb0 |= 16;
	if (proxy.slot_secondary_aux   != player.slot_secondary_aux)   mb0 |= 32;
	if (proxy.ammo_hlgrenade       != player.ammo_hlgrenade)       mb0 |= 64;
	if (proxy.ammo_snowball        != player.ammo_snowball)        mb0 |= 128;

	if (proxy.ammo_cshegrenade     != player.ammo_cshegrenade)     mb1 |= 1;
	if (proxy.ammo_csflashbang     != player.ammo_csflashbang)     mb1 |= 2;
	if (proxy.ammo_cssmokegrenade  != player.ammo_cssmokegrenade)  mb1 |= 4;
	if (proxy.ammo_cfc4            != player.ammo_cfc4)            mb1 |= 8;

	// OR (accumulate), don't overwrite.  PlayerSpawn can call
	// PM_SyncPredictionProxy twice in one tick (once via
	// PM_EnsurePredictionProxy, once directly right after); the second
	// call sees zero diff — if we OVERWROTE the mask, the first call's
	// pending bits would be lost before SendEntity could write them.
	// The corresponding clear lives in SendEntity's ammo section, after
	// the WriteBytes.
	proxy.pm_ammo_mb0 |= mb0;
	proxy.pm_ammo_mb1 |= mb1;
	proxy.pm_ammo_mb2 |= mb2;
	proxy.pm_ammo_mb3 |= mb3;
	proxy.pm_ammo_mb4 |= mb4;
	proxy.pm_ammo_mb5 |= mb5;
	proxy.pm_ammo_mb6 |= mb6;

	if (proxy.pm_ammo_mb0 || proxy.pm_ammo_mb1 || proxy.pm_ammo_mb2
	 || proxy.pm_ammo_mb3 || proxy.pm_ammo_mb4 || proxy.pm_ammo_mb5
	 || proxy.pm_ammo_mb6)
		bits |= PM_SF_AMMO;

	// nettest perf: nothing changed since the last snapshot (proxy already equals
	// player; no pending ammo), so skip the 135-field copy below AND the no-op
	// `SendFlags | 0`.  Safe because every SENT field is either diffed above or
	// moves in lockstep with one that is (e.g. per-weapon mag_* only change with
	// the active slot ammo, which IS diffed) — bits==0 means there is genuinely
	// nothing to send.  A freshly-created proxy diffs against a zeroed cache, so
	// its first sync has bits!=0 and still runs the full copy.
	if (!bits)
		return;

	// Copy player → proxy cache (so next call compares against this snapshot).
	proxy.origin = player.origin;
	proxy.velocity = player.velocity;
	proxy.view_ofs = player.view_ofs;
	proxy.flags = player.flags;
	proxy.pm_movetype = player.pm_movetype;
	proxy.pm_jump_held = player.pm_jump_held;
	proxy.pm_jump_msec = player.pm_jump_msec;
	proxy.pm_waterjumptime = player.pm_waterjumptime;
	proxy.pm_in_duck = player.pm_in_duck;
	proxy.pm_duck_msec = player.pm_duck_msec;
	proxy.pm_oldbuttons    = player.pm_oldbuttons;
	proxy.pm_timecarry     = player.pm_timecarry;
	proxy.pm_teleport_time        = player.pm_teleport_time;
	proxy.pm_ladder_detach_time   = player.pm_ladder_detach_time;
	proxy.pm_fuser2               = player.pm_fuser2;
	proxy.spread_penalty          = player.spread_penalty;
	proxy.fire_spread_penalty     = player.fire_spread_penalty;
	proxy.pm_step_time            = player.pm_step_time;
	proxy.slide_friction_active   = player.slide_friction_active;
	proxy.pm_jump_lag_end         = player.pm_jump_lag_end;
	proxy.pm_jump_groundstick_off_until = player.pm_jump_groundstick_off_until;
	proxy.grapple_rope_active     = player.grapple_rope_active;
	proxy.grapple_anchor          = player.grapple_anchor;
	proxy.grapple_attached        = player.grapple_attached;
	proxy.pm_grapple_held_last    = player.pm_grapple_held_last;
	proxy.codstamina              = player.codstamina;
	proxy.codstamina_punished     = player.codstamina_punished;
	proxy.pm_fire_suppress_until  = player.pm_fire_suppress_until;
	proxy.pm_carrying             = player.pm_carrying;
	proxy.pm_driving              = player.pm_driving;
	proxy.pm_incar                = player.pm_incar;

	proxy.slot_primary     = player.slot_primary;
	proxy.slot_secondary   = player.slot_secondary;
	proxy.slot_melee       = player.slot_melee;
	proxy.slot_utility     = player.slot_utility;
	proxy.weapon          = player.weapon;
	proxy.previous_weapon = player.previous_weapon;
	proxy.weaponstate     = player.weaponstate;
	proxy.wep_action_id   = player.wep_action_id;
	proxy.attack_finished = player.attack_finished;
	proxy.wep_anim_start  = player.wep_anim_start;
	proxy.zoomstage       = player.zoomstage;
	proxy.snowball_has_slingshot = player.snowball_has_slingshot;
	proxy.snowball_use_slingshot = player.snowball_use_slingshot;
	proxy.pm_weapon_blend_progress = player.pm_weapon_blend_progress;
	proxy.pm_weapon_prev_factor    = player.pm_weapon_prev_factor;
	proxy.view_kick_pitch     = player.view_kick_pitch;
	proxy.view_kick_yaw       = player.view_kick_yaw;
	proxy.view_kick_pitch_vel = player.view_kick_pitch_vel;
	proxy.view_kick_yaw_vel   = player.view_kick_yaw_vel;
	proxy.view_kick_burst_idx = player.view_kick_burst_idx;

	proxy.mag_deagle      = player.mag_deagle;
	proxy.ammo_deagle     = player.ammo_deagle;
	proxy.mag_ak47        = player.mag_ak47;
	proxy.ammo_ak47       = player.ammo_ak47;
	proxy.mag_m4a1        = player.mag_m4a1;
	proxy.ammo_m4a1       = player.ammo_m4a1;
	proxy.m4a1_silenced   = player.m4a1_silenced;
	proxy.mag_flakshotgun = player.mag_flakshotgun;
	proxy.mag_pistol      = player.mag_pistol;
	proxy.ammo_pistol     = player.ammo_pistol;
	proxy.mag_scout       = player.mag_scout;
	proxy.ammo_scout      = player.ammo_scout;
	proxy.mag_357         = player.mag_357;
	proxy.ammo_357        = player.ammo_357;
	proxy.mag_m249        = player.mag_m249;
	proxy.ammo_m249       = player.ammo_m249;
	proxy.mag_awp         = player.mag_awp;
	proxy.ammo_awp        = player.ammo_awp;
	proxy.mag_98k         = player.mag_98k;
	proxy.ammo_98k        = player.ammo_98k;
	proxy.mag_shotgun     = player.mag_shotgun;
	proxy.ammo_shotgun    = player.ammo_shotgun;
	proxy.mag_m3          = player.mag_m3;
	proxy.ammo_m3         = player.ammo_m3;
	proxy.mag_mp5         = player.mag_mp5;
	proxy.ammo_mp5        = player.ammo_mp5;
	proxy.mag_crossbow    = player.mag_crossbow;
	proxy.ammo_crossbow   = player.ammo_crossbow;
	proxy.mag_grenadelauncher = player.mag_grenadelauncher;
	proxy.mag_rebar       = player.mag_rebar;
	proxy.ammo_gauss      = player.ammo_gauss;
	proxy.mag_glock       = player.mag_glock;
	proxy.ammo_glock      = player.ammo_glock;
	proxy.mag_g3sg1       = player.mag_g3sg1;
	proxy.ammo_g3sg1      = player.ammo_g3sg1;
	proxy.mag_hlsmg       = player.mag_hlsmg;
	proxy.ammo_hlsmg      = player.ammo_hlsmg;
	proxy.ammo_hlsmg_grenades = player.ammo_hlsmg_grenades;
	proxy.mag_hlrpg       = player.mag_hlrpg;
	proxy.ammo_hlrpg      = player.ammo_hlrpg;
	proxy.ammo_hlgrenade  = player.ammo_hlgrenade;
	proxy.ammo_snowball   = player.ammo_snowball;
	proxy.mag_hlglock     = player.mag_hlglock;
	proxy.ammo_hlglock    = player.ammo_hlglock;
	proxy.ammo_hlegon     = player.ammo_hlegon;
	proxy.mag_paintball   = player.mag_paintball;
	proxy.ammo_paintball  = player.ammo_paintball;
	proxy.ammo_cshegrenade = player.ammo_cshegrenade;
	proxy.ammo_csflashbang = player.ammo_csflashbang;
	proxy.ammo_cssmokegrenade = player.ammo_cssmokegrenade;
	proxy.ammo_cfc4 = player.ammo_cfc4;

	proxy.slot_primary_mag    = player.slot_primary_mag;
	proxy.slot_primary_ammo   = player.slot_primary_ammo;
	proxy.slot_primary_aux    = player.slot_primary_aux;
	proxy.slot_secondary_mag  = player.slot_secondary_mag;
	proxy.slot_secondary_ammo = player.slot_secondary_ammo;
	proxy.slot_secondary_aux  = player.slot_secondary_aux;

	proxy.SendFlags = proxy.SendFlags | bits;
};

void(entity player) PM_EnsurePredictionProxy =
{
	entity proxy;
	float was_new = FALSE;

	proxy = player.pm_prediction_proxy;
	if (!proxy)
	{
		proxy = spawn();
		proxy.classname = PM_CSQC_PROXY_CLASSNAME;
		proxy.movetype = MOVETYPE_NONE;
		proxy.solid = SOLID_NOT;
		proxy.pvsflags = PVSF_NOREMOVE;
		proxy.SendEntity = PM_PredictionProxy_SendEntity;
		player.pm_prediction_proxy = proxy;
		was_new = TRUE;
	}

	proxy.owner = player;
	proxy.drawonlytoclient = player;
	PM_SyncPredictionProxy(player);

	// Force a full snapshot on first creation so the client definitely
	// gets every section even if a player's field happens to match zero.
	// For PM_SF_AMMO: also set every used bit in the compact slot-ammo
	// mask so SendEntity writes all ammo values on baseline.
	if (was_new)
	{
		proxy.SendFlags = proxy.SendFlags | PM_SF_MOVEMENT | PM_SF_WEAPON_STATE | PM_SF_AMMO;
		proxy.pm_ammo_mb0 = 255;
		proxy.pm_ammo_mb1 = 15;   // bits 1/2/4 = he/flash/smoke, bit 8 = ammo_cfc4 (C4 carry)
		proxy.pm_ammo_mb2 = 0;
		proxy.pm_ammo_mb3 = 0;
		proxy.pm_ammo_mb4 = 0;
		proxy.pm_ammo_mb5 = 0;
		proxy.pm_ammo_mb6 = 0;
	}
};

// ------------------------------------------------------------
//  W_GiveStartingAmmo
//    Reads self.slot_primary / slot_secondary / slot_melee / slot_utility
//    (already populated from sv_default_* cvars) and sets the matching
//    slot_X_equip / slot_X_drop function pointers plus starting mag + reserve
//    ammo for the chosen weapon in each slot.  All known mag/ammo fields are
//    zeroed first so nothing bleeds over from a previous inventory.
// ------------------------------------------------------------
// Per-slot equip refreshers — extracted from W_GiveStartingAmmo so the buy
// path (W_GiveWeaponToSlot) can re-equip ONE slot without the global ammo
// wipe (which would reset the player's other guns).  Defined below; forward-
// declared here because W_GiveStartingAmmo calls them.
void() W_RefreshPrimarySlot;
void() W_RefreshSecondarySlot;
void() W_RefreshMeleeSlot;
void() W_RefreshUtilitySlot;

void() W_GiveStartingAmmo =
{
	// Zero every mag + reserve field so switching away from a weapon
	// doesn't leave the old weapon's ammo on the player.
	self.mag_ak47 = 0;             self.ammo_ak47 = 0;
	self.mag_m4a1 = 0;             self.ammo_m4a1 = 0;
	self.mag_awp = 0;              self.ammo_awp = 0;
	self.mag_g3sg1 = 0;            self.ammo_g3sg1 = 0;
	self.mag_m3 = 0;               self.ammo_m3 = 0;
	self.mag_mp5 = 0;              self.ammo_mp5 = 0;
	self.mag_98k = 0;              self.ammo_98k = 0;
	self.mag_flakshotgun = 0;
	self.ammo_gauss = 0;
	self.mag_grenadelauncher = 0;
	self.mag_crossbow = 0;         self.ammo_crossbow = 0;
	self.ammo_hlegon = 0;
	self.mag_hlrpg = 0;            self.ammo_hlrpg = 0;
	self.mag_shotgun = 0;          self.ammo_shotgun = 0;
	self.mag_hlsmg = 0;            self.ammo_hlsmg = 0;  self.ammo_hlsmg_grenades = 0;
	self.mag_m249 = 0;             self.ammo_m249 = 0;
	self.mag_rebar = 0;
	self.mag_scout = 0;            self.ammo_scout = 0;
	self.mag_paintball = 0;        self.ammo_paintball = 0;
	self.mag_deagle = 0;           self.ammo_deagle = 0;
	self.mag_glock = 0;            self.ammo_glock = 0;
	self.mag_357 = 0;              self.ammo_357 = 0;
	self.mag_hlglock = 0;          self.ammo_hlglock = 0;
	self.mag_pistol = 0;           self.ammo_pistol = 0;
	self.ammo_hlgrenade = 0;
	self.ammo_snowball = 0;
	self.ammo_cshegrenade = 0;
	self.ammo_csflashbang = 0;
	self.ammo_cssmokegrenade = 0;
	self.snowball_has_slingshot = FALSE;
	self.snowball_use_slingshot = FALSE;
	W_SlotAmmo_ClearSlots(self);

	W_RefreshPrimarySlot();
	W_RefreshSecondarySlot();
	W_RefreshMeleeSlot();
	W_RefreshUtilitySlot();

	// Multi-utility post-pass: sv_default_utility is a comma-separated
	// weapon-id list (e.g. "33,34" for HE+Flash).  The switch above
	// already gave ammo for the FIRST entry (the active slot_utility);
	// here we give ammo for any additional utility ids so the player
	// spawns carrying every selected grenade.  Any unknown / duplicate
	// / non-utility id is skipped; the inventory model already supports
	// holding multiple utilities (W_UtilityNextCarried iterates them).
	// NOTE: this stays in W_GiveStartingAmmo (the spawn path) ONLY — a
	// single-weapon buy must NOT re-grant the default grenade set.
	{
		string util_list = cvar_string("sv_default_utility");
		float util_n = Weapon_TokenizeIdList(util_list);
		float util_i;
		for (util_i = 0; util_i < util_n; util_i++)
		{
			float util_wep = Weapon_IdFromStringOrDefault(argv(util_i), WEP_NONE);
			if (util_wep == WEP_NONE || util_wep == self.slot_utility)
				continue;
			if      (util_wep == WEP_HLGRENADE)       self.ammo_hlgrenade      = MAX_AMMO_HLGRENADE;
			else if (util_wep == WEP_SNOWBALL)        self.ammo_snowball       = MAX_AMMO_SNOWBALL;
			else if (util_wep == WEP_CSHEGRENADE)     self.ammo_cshegrenade    = MAX_AMMO_CSHEGRENADE;
			else if (util_wep == WEP_CSFLASHBANG)     self.ammo_csflashbang    = MAX_AMMO_CSFLASHBANG;
			else if (util_wep == WEP_CSSMOKEGRENADE)  self.ammo_cssmokegrenade = MAX_AMMO_CSSMOKEGRENADE;
			else if (util_wep == WEP_SLINGSHOT)
			{
				self.snowball_has_slingshot = TRUE;
				self.snowball_use_slingshot = TRUE;
				if (self.ammo_snowball <= 0)
					self.ammo_snowball = MAX_AMMO_SNOWBALL;
			}
		}
	}
};

// Re-equip the PRIMARY slot from self.slot_primary (equip/drop fn-pointers +
// that weapon's mag/ammo).  The global ammo wipe lives in W_GiveStartingAmmo,
// NOT here, so W_GiveWeaponToSlot can refresh one slot without resetting the
// player's other guns.
void() W_RefreshPrimarySlot =
{
	self.slot_primary_equip = __NULL__;
	self.slot_primary_drop  = __NULL__;
	switch (self.slot_primary)
	{
	case WEP_AK47:
		self.slot_primary_equip = W_AK47Equip;
		self.slot_primary_drop  = W_AK47Drop;
		self.mag_ak47 = MAX_MAG_AK47;   self.ammo_ak47 = MAX_AMMO_AK47;
		break;
	case WEP_HDAK47:
		// HD variant — shares mag_ak47 / ammo_ak47 with WEP_AK47.
		self.slot_primary_equip = W_HDAK47Equip;
		self.slot_primary_drop  = W_HDAK47Drop;
		self.mag_ak47 = MAX_MAG_AK47;   self.ammo_ak47 = MAX_AMMO_AK47;
		break;
	case WEP_M4A1:
		self.slot_primary_equip = W_M4A1Equip;
		self.slot_primary_drop  = W_M4A1Drop;
		self.mag_m4a1 = MAX_MAG_M4A1;   self.ammo_m4a1 = MAX_AMMO_M4A1;
		break;
	case WEP_CSAWP:
		self.slot_primary_equip = W_AWPEquip;
		self.slot_primary_drop  = W_AWPDrop;
		self.mag_awp = MAX_MAG_AWP;     self.ammo_awp = MAX_AMMO_AWP;
		break;
	case WEP_G3SG1:
		self.slot_primary_equip = W_G3SG1Equip;
		self.slot_primary_drop  = W_G3SG1Drop;
		self.mag_g3sg1 = MAX_MAG_G3SG1; self.ammo_g3sg1 = MAX_AMMO_G3SG1;
		break;
	case WEP_CSM3:
		self.slot_primary_equip = W_M3Equip;
		self.slot_primary_drop  = W_M3Drop;
		self.mag_m3 = MAX_MAG_M3;       self.ammo_m3 = MAX_AMMO_M3;
		break;
	case WEP_CSMP5:
		self.slot_primary_equip = W_MP5Equip;
		self.slot_primary_drop  = W_MP5Drop;
		self.mag_mp5 = MAX_MAG_MP5;     self.ammo_mp5 = MAX_AMMO_MP5;
		break;
	case WEP_DOD98K:
		self.slot_primary_equip = W_98KEquip;
		self.slot_primary_drop  = W_98KDrop;
		self.mag_98k = MAX_MAG_98K;     self.ammo_98k = MAX_AMMO_98K;
		break;
	case WEP_FLAKSHOTGUN:
		self.slot_primary_equip = W_FlakShotgunEquip;
		self.slot_primary_drop  = W_FlakShotgunDrop;
		self.mag_flakshotgun = MAX_MAG_FLAKSHOTGUN;
		break;
	case WEP_GAUSS:
		self.slot_primary_equip = W_GaussEquip;
		self.slot_primary_drop  = W_GaussDrop;
		self.ammo_gauss = MAX_AMMO_GAUSS;
		break;
	case WEP_GRENADELAUNCHER:
		self.slot_primary_equip = W_GLEquip;
		self.slot_primary_drop  = W_GLDrop;
		self.mag_grenadelauncher = MAX_MAG_GRENADELAUNCHER;
		break;
	case WEP_CROSSBOW:
		self.slot_primary_equip = W_CrossbowEquip;
		self.slot_primary_drop  = W_CrossbowDrop;
		self.mag_crossbow = MAX_MAG_CROSSBOW;   self.ammo_crossbow = MAX_AMMO_CROSSBOW;
		break;
	case WEP_HLEGON:
		self.slot_primary_equip = W_EgonEquip;
		self.slot_primary_drop  = W_EgonDrop;
		self.ammo_hlegon = MAX_AMMO_HLEGON;
		break;
	case WEP_HLRPG:
		self.slot_primary_equip = W_RPGEquip;
		self.slot_primary_drop  = W_RPGDrop;
		self.mag_hlrpg = MAX_MAG_HLRPG;         self.ammo_hlrpg = MAX_AMMO_HLRPG;
		break;
	case WEP_HLSHOTGUN:
		self.slot_primary_equip = W_ShotgunEquip;
		self.slot_primary_drop  = W_ShotgunDrop;
		self.mag_shotgun = MAX_MAG_SHOTGUN;     self.ammo_shotgun = MAX_AMMO_SHOTGUN;
		break;
	case WEP_HLSMG:
		self.slot_primary_equip = W_HLSMGEquip;
		self.slot_primary_drop  = W_HLSMGDrop;
		self.mag_hlsmg = MAX_MAG_HLSMG;         self.ammo_hlsmg = MAX_AMMO_HLSMG;
		self.ammo_hlsmg_grenades = MAX_AMMO_HLSMG_GRENADES;
		break;
	case WEP_M249:
		self.slot_primary_equip = W_M249Equip;
		self.slot_primary_drop  = W_M249Drop;
		self.mag_m249 = MAX_MAG_M249;           self.ammo_m249 = MAX_AMMO_M249;
		break;
	case WEP_REBAR:
		self.slot_primary_equip = W_RebarEquip;
		self.slot_primary_drop  = W_RebarDrop;
		self.mag_rebar = MAX_MAG_REBAR;
		break;
	case WEP_SCOUT:
		self.slot_primary_equip = W_ScoutEquip;
		self.slot_primary_drop  = W_ScoutDrop;
		self.mag_scout = MAX_MAG_SCOUT;         self.ammo_scout = MAX_AMMO_SCOUT;
		break;
	case WEP_PAINTBALL:
		self.slot_primary_equip = W_PaintballEquip;
		self.slot_primary_drop  = W_PaintballDrop;
		self.mag_paintball = MAX_MAG_PAINTBALL; self.ammo_paintball = MAX_AMMO_PAINTBALL;
		break;
	case WEP_CFAUG:
		self.slot_primary_equip = W_CFAugEquip;
		self.slot_primary_drop  = W_CFAugDrop;
		self.mag_cfaug = MAX_MAG_CFAUG;         self.ammo_cfaug = MAX_AMMO_CFAUG;
		break;
	case WEP_CFFAMAS:
		self.slot_primary_equip = W_CFFamasEquip;
		self.slot_primary_drop  = W_CFFamasDrop;
		self.mag_cffamas = MAX_MAG_CFFAMAS;     self.ammo_cffamas = MAX_AMMO_CFFAMAS;
		break;
	case WEP_CFMAC10:
		self.slot_primary_equip = W_CFMac10Equip;
		self.slot_primary_drop  = W_CFMac10Drop;
		self.mag_cfmac10 = MAX_MAG_CFMAC10;     self.ammo_cfmac10 = MAX_AMMO_CFMAC10;
		break;
	case WEP_CFBARRETT:
		self.slot_primary_equip = W_CFBarrettEquip;
		self.slot_primary_drop  = W_CFBarrettDrop;
		self.mag_cfbarrett = MAX_MAG_CFBARRETT;         self.ammo_cfbarrett = MAX_AMMO_CFBARRETT;
		break;
	case WEP_CFPSG1:
		self.slot_primary_equip = W_CFPSG1Equip;
		self.slot_primary_drop  = W_CFPSG1Drop;
		self.mag_cfpsg1 = MAX_MAG_CFPSG1;     self.ammo_cfpsg1 = MAX_AMMO_CFPSG1;
		break;
	case WEP_CFSPAS12:
		self.slot_primary_equip = W_CFSPAS12Equip;
		self.slot_primary_drop  = W_CFSPAS12Drop;
		self.mag_cfspas12 = MAX_MAG_CFSPAS12;   self.ammo_cfspas12 = MAX_AMMO_CFSPAS12;
		break;
	case WEP_CFM700:
		self.slot_primary_equip = W_CFM700Equip;
		self.slot_primary_drop  = W_CFM700Drop;
		self.mag_cfm700 = MAX_MAG_CFM700; self.ammo_cfm700 = MAX_AMMO_CFM700;
		break;
	case WEP_CFM3:
		self.slot_primary_equip = W_CFM3Equip;
		self.slot_primary_drop  = W_CFM3Drop;
		self.mag_cfm3 = MAX_MAG_CFM3;           self.ammo_cfm3 = MAX_AMMO_CFM3;
		break;
	case WEP_CFSCAR:
		self.slot_primary_equip = W_CFScarEquip;
		self.slot_primary_drop  = W_CFScarDrop;
		self.mag_cfscar = MAX_MAG_CFSCAR;     self.ammo_cfscar = MAX_AMMO_CFSCAR;
		break;
	case WEP_CFSVD:
		self.slot_primary_equip = W_CFSVDEquip;
		self.slot_primary_drop  = W_CFSVDDrop;
		self.mag_cfsvd = MAX_MAG_CFSVD;     self.ammo_cfsvd = MAX_AMMO_CFSVD;
		break;
	case WEP_CFMP5:
		self.slot_primary_equip = W_CFMp5Equip;
		self.slot_primary_drop  = W_CFMp5Drop;
		self.mag_cfmp5 = MAX_MAG_CFMP5;         self.ammo_cfmp5 = MAX_AMMO_CFMP5;
		break;
	case WEP_CFVECTOR:
		self.slot_primary_equip = W_CFVectorEquip;
		self.slot_primary_drop  = W_CFVectorDrop;
		self.mag_cfvector = MAX_MAG_CFVECTOR;   self.ammo_cfvector = MAX_AMMO_CFVECTOR;
		break;
	case WEP_CFTYPE89:
		self.slot_primary_equip = W_CFType89Equip;
		self.slot_primary_drop  = W_CFType89Drop;
		self.mag_cftype89 = MAX_MAG_CFTYPE89;   self.ammo_cftype89 = MAX_AMMO_CFTYPE89;
		break;
	case WEP_CFUMP45:
		self.slot_primary_equip = W_CFUmp45Equip;
		self.slot_primary_drop  = W_CFUmp45Drop;
		self.mag_cfump45 = MAX_MAG_CFUMP45;     self.ammo_cfump45 = MAX_AMMO_CFUMP45;
		break;
	case WEP_CFM249:
		self.slot_primary_equip = W_CFM249Equip;
		self.slot_primary_drop  = W_CFM249Drop;
		self.mag_cfm249 = MAX_MAG_CFM249;       self.ammo_cfm249 = MAX_AMMO_CFM249;
		break;
	case WEP_CFAWM:
		self.slot_primary_equip = W_CFAwmEquip;
		self.slot_primary_drop  = W_CFAwmDrop;
		self.mag_cfawm = MAX_MAG_CFAWM;         self.ammo_cfawm = MAX_AMMO_CFAWM;
		break;
	case WEP_CFKS23:
		self.slot_primary_equip = W_CFKs23Equip;
		self.slot_primary_drop  = W_CFKs23Drop;
		self.mag_cfks23 = MAX_MAG_CFKS23;       self.ammo_cfks23 = MAX_AMMO_CFKS23;
		break;
	case WEP_CFM4:
		self.slot_primary_equip = W_CFM4Equip;
		self.slot_primary_drop  = W_CFM4Drop;
		self.mag_cfm4 = MAX_MAG_CFM4;           self.ammo_cfm4 = MAX_AMMO_CFM4;
		break;
	case WEP_CFGALIL:
		self.slot_primary_equip = W_CFGalilEquip;
		self.slot_primary_drop  = W_CFGalilDrop;
		self.mag_cfgalil = MAX_MAG_CFGALIL;     self.ammo_cfgalil = MAX_AMMO_CFGALIL;
		break;
	case WEP_CFELITE:
		self.slot_primary_equip = W_CFEliteEquip;
		self.slot_primary_drop  = W_CFEliteDrop;
		self.mag_cfelite = MAX_MAG_CFELITE;     self.ammo_cfelite = MAX_AMMO_CFELITE;
		break;
	case WEP_CFMSG90:
		self.slot_primary_equip = W_CFMsg90Equip;
		self.slot_primary_drop  = W_CFMsg90Drop;
		self.mag_cfmsg90 = MAX_MAG_CFMSG90;     self.ammo_cfmsg90 = MAX_AMMO_CFMSG90;
		break;
	case WEP_CFSG552:
		self.slot_primary_equip = W_CFSG552Equip;
		self.slot_primary_drop  = W_CFSG552Drop;
		self.mag_cfsg552 = MAX_MAG_CFSG552;     self.ammo_cfsg552 = MAX_AMMO_CFSG552;
		break;
	case WEP_CFSL8:
		self.slot_primary_equip = W_CFSl8Equip;
		self.slot_primary_drop  = W_CFSl8Drop;
		self.mag_cfsl8 = MAX_MAG_CFSL8;         self.ammo_cfsl8 = MAX_AMMO_CFSL8;
		break;
	case WEP_GRAVITYGUN:
		self.slot_primary_equip = W_GravGunEquip;
		self.slot_primary_drop  = W_GravGunDrop;
		// infinite energy — no mag/ammo
		break;
	default:
		self.slot_primary = WEP_NONE;
		break;
	}
	if (self.slot_primary != WEP_NONE)
		W_SlotAmmo_SaveLegacy(self, self.slot_primary);
};

// Re-equip the SECONDARY slot from self.slot_secondary.
void() W_RefreshSecondarySlot =
{
	self.slot_secondary_equip = __NULL__;
	self.slot_secondary_drop  = __NULL__;
	switch (self.slot_secondary)
	{
	case WEP_DEAGLE:
		self.slot_secondary_equip = W_DeagleEquip;
		self.slot_secondary_drop  = W_DeagleDrop;
		self.mag_deagle = MAX_MAG_DEAGLE; self.ammo_deagle = MAX_AMMO_DEAGLE;
		break;
	case WEP_GLOCK:
		self.slot_secondary_equip = W_GlockEquip;
		self.slot_secondary_drop  = W_GlockDrop;
		self.mag_glock = MAX_MAG_GLOCK;   self.ammo_glock = MAX_AMMO_GLOCK;
		break;
	case WEP_357:
		self.slot_secondary_equip = W_357Equip;
		self.slot_secondary_drop  = W_357Drop;
		self.mag_357 = MAX_MAG_357;       self.ammo_357 = MAX_AMMO_357;
		break;
	case WEP_HLGLOCK:
		self.slot_secondary_equip = W_HLGlockEquip;
		self.slot_secondary_drop  = W_HLGlockDrop;
		self.mag_hlglock = MAX_MAG_HLGLOCK; self.ammo_hlglock = MAX_AMMO_HLGLOCK;
		break;
	case WEP_PISTOL:
		self.slot_secondary_equip = W_PistolEquip;
		self.slot_secondary_drop  = W_PistolDrop;
		self.mag_pistol = MAX_MAG_PISTOL; self.ammo_pistol = MAX_AMMO_PISTOL;
		break;
	case WEP_CFM9:
		self.slot_secondary_equip = W_CFM9Equip;
		self.slot_secondary_drop  = W_CFM9Drop;
		self.mag_cfm9 = MAX_MAG_CFM9; self.ammo_cfm9 = MAX_AMMO_CFM9;
		break;
	case WEP_CFREVOLVER:
		self.slot_secondary_equip = W_CFRevolverEquip;
		self.slot_secondary_drop  = W_CFRevolverDrop;
		self.mag_cfrevolver = MAX_MAG_CFREVOLVER; self.ammo_cfrevolver = MAX_AMMO_CFREVOLVER;
		break;
	case WEP_CFDDEAGLE:
		self.slot_secondary_equip = W_CFDdeagleEquip;
		self.slot_secondary_drop  = W_CFDdeagleDrop;
		self.mag_cfddeagle = MAX_MAG_CFDDEAGLE; self.ammo_cfddeagle = MAX_AMMO_CFDDEAGLE;
		break;
	case WEP_CFMAUSER:
		self.slot_secondary_equip = W_CFMauserEquip;
		self.slot_secondary_drop  = W_CFMauserDrop;
		self.mag_cfmauser = MAX_MAG_CFMAUSER; self.ammo_cfmauser = MAX_AMMO_CFMAUSER;
		break;
	case WEP_CFMK23:
		self.slot_secondary_equip = W_CFMk23Equip;
		self.slot_secondary_drop  = W_CFMk23Drop;
		self.mag_cfmk23 = MAX_MAG_CFMK23; self.ammo_cfmk23 = MAX_AMMO_CFMK23;
		self.cfmk23_silenced = TRUE;
		break;
	case WEP_CSUSP:
		self.slot_secondary_equip = W_CSUSPEquip;
		self.slot_secondary_drop  = W_CSUSPDrop;
		self.mag_csusp = MAX_MAG_CSUSP; self.ammo_csusp = MAX_AMMO_CSUSP;
		self.csusp_silenced = 0;
		break;
	case WEP_CFGLOCK:
		self.slot_secondary_equip = W_CFGlockEquip;
		self.slot_secondary_drop  = W_CFGlockDrop;
		self.mag_cfglock = MAX_MAG_CFGLOCK; self.ammo_cfglock = MAX_AMMO_CFGLOCK;
		break;
	case WEP_CFP228:
		self.slot_secondary_equip = W_CFP228Equip;
		self.slot_secondary_drop  = W_CFP228Drop;
		self.mag_cfp228 = MAX_MAG_CFP228; self.ammo_cfp228 = MAX_AMMO_CFP228;
		break;
	default:
		self.slot_secondary = WEP_NONE;
		break;
	}
	if (self.slot_secondary != WEP_NONE)
		W_SlotAmmo_SaveLegacy(self, self.slot_secondary);
};

// Re-equip the MELEE slot from self.slot_melee.
void() W_RefreshMeleeSlot =
{
	self.slot_melee_equip = __NULL__;
	self.slot_melee_drop  = __NULL__;
	switch (self.slot_melee)
	{
	case WEP_WRENCH:
		self.slot_melee_equip = W_WrenchEquip;
		self.slot_melee_drop  = W_WrenchDrop;
		break;
	case WEP_KNIFE:
		self.slot_melee_equip = W_KnifeEquip;
		self.slot_melee_drop  = W_KnifeDrop;
		break;
	case WEP_HLCROWBAR:
		self.slot_melee_equip = W_CrowbarEquip;
		self.slot_melee_drop  = W_CrowbarDrop;
		break;
	case WEP_BUTTERFLY:
		self.slot_melee_equip = W_ButterflyEquip;
		self.slot_melee_drop  = W_ButterflyDrop;
		break;
	case WEP_KATANA:
		self.slot_melee_equip = W_KatanaEquip;
		self.slot_melee_drop  = W_KatanaDrop;
		break;
	case WEP_MELEE:
		// Bare fists — the fallback melee when the loadout's melee is "None".
		self.slot_melee_equip = W_MeleeEquip;
		self.slot_melee_drop  = W_MeleeDrop;
		break;
	default:
		self.slot_melee = WEP_NONE;
		break;
	}
};

// Re-equip the UTILITY slot from self.slot_utility (single grenade; the
// multi-grenade default fill stays in W_GiveStartingAmmo's post-pass).
void() W_RefreshUtilitySlot =
{
	self.slot_utility_equip = __NULL__;
	self.slot_utility_drop  = __NULL__;
	switch (self.slot_utility)
	{
	case WEP_HLGRENADE:
		self.slot_utility_equip = W_HLGrenadeEquip;
		self.slot_utility_drop  = W_HLGrenadeDrop;
		self.ammo_hlgrenade = MAX_AMMO_HLGRENADE;
		break;
	case WEP_SNOWBALL:
		self.slot_utility_equip = W_SnowballEquip;
		self.slot_utility_drop  = W_SnowballDrop;
		self.ammo_snowball = MAX_AMMO_SNOWBALL;
		break;
	case WEP_CSHEGRENADE:
		self.slot_utility_equip = W_CSHEGrenadeEquip;
		self.slot_utility_drop  = W_CSHEGrenadeDrop;
		self.ammo_cshegrenade = MAX_AMMO_CSHEGRENADE;
		break;
	case WEP_CSFLASHBANG:
		self.slot_utility_equip = W_CSFlashbangEquip;
		self.slot_utility_drop  = W_CSFlashbangDrop;
		self.ammo_csflashbang = MAX_AMMO_CSFLASHBANG;
		break;
	case WEP_CSSMOKEGRENADE:
		self.slot_utility_equip = W_CSSmokeGrenadeEquip;
		self.slot_utility_drop  = W_CSSmokeGrenadeDrop;
		self.ammo_cssmokegrenade = MAX_AMMO_CSSMOKEGRENADE;
		break;
	case WEP_SLINGSHOT:
		// Slingshot is a snowball upgrade — selecting it as the
		// loadout's "primary utility" implies snowballs to throw with
		// it, otherwise the player spawns holding a slingshot they
		// can't use.  Equip snowball as the active utility, fill
		// snowball ammo, and pre-arm the slingshot toggle.
		self.snowball_has_slingshot = TRUE;
		self.snowball_use_slingshot = TRUE;
		self.slot_utility = WEP_SNOWBALL;
		self.slot_utility_equip = W_SnowballEquip;
		self.slot_utility_drop  = W_SnowballDrop;
		self.ammo_snowball = MAX_AMMO_SNOWBALL;
		break;
	default:
		self.slot_utility = WEP_NONE;
		break;
	}
};

// Grant a single bought weapon into its slot WITHOUT the global ammo wipe
// (so the player's other slots/guns are preserved).  Operates on self (the
// buyer).  Slot is resolved from the shared manifest.  PRIMARY/SECONDARY/
// MELEE replace the slot; UTILITY is additive (the refresh only sets that
// grenade's ammo + makes it active).
void(float wep) W_GiveWeaponToSlot =
{
	float slot = WeaponManifest_Slot(wep);
	if (slot == WMF_SLOT_PRIMARY)
	{
		// Drop the gun already in this slot (if any) as a pickup, carrying
		// its ammo, before installing the new one.  Skip when re-buying the
		// same weapon (that just refills via the refresh below).
		if (self.slot_primary != WEP_NONE && self.slot_primary != wep)
			W_DropSlotForBuy(0, self.slot_primary, self.slot_primary_drop);
		self.slot_primary = wep;
		W_RefreshPrimarySlot();
	}
	else if (slot == WMF_SLOT_SECONDARY)
	{
		if (self.slot_secondary != WEP_NONE && self.slot_secondary != wep)
			W_DropSlotForBuy(1, self.slot_secondary, self.slot_secondary_drop);
		self.slot_secondary = wep;
		W_RefreshSecondarySlot();
	}
	else if (slot == WMF_SLOT_MELEE)
	{
		if (self.slot_melee != WEP_NONE && self.slot_melee != wep)
			W_DropSlotForBuy(2, self.slot_melee, self.slot_melee_drop);
		self.slot_melee = wep;
		W_RefreshMeleeSlot();
	}
	else if (slot == WMF_SLOT_UTILITY)
	{
		// Grenades stack (additive) — no drop, and don't yank the player
		// off their gun to a thrown item.  Equipment buys end here.
		self.slot_utility = wep;
		W_RefreshUtilitySlot();
		return;
	}
	else
		return;

	// Switch to the just-bought weapon so the viewmodel flushes to it.
	W_SelectWeapon(wep);
};

void() PlayerSpawn =
{
	// Always produce a live player. Without this, callers that reach
	// PlayerSpawn from a dead state (notably PlayerJoinTeam on the
	// spec→team path) leave is_dead=TRUE — STAT_IS_DEAD then keeps the
	// client in spec UI, PlayerPreThink early-returns every tick, and
	// the body sits frozen at the spawn point as a killable "ghost"
	// with the proxy rendering vis_is_dead=1 corpse pose. The other
	// respawn paths (RoundRestart sv_main.qc:82, auto-respawn :525,
	// gamemode switch :355) already pre-clear these — this duplicates
	// them harmlessly so PlayerSpawn alone is enough.
	self.is_dead = FALSE;
	self.death_time = 0;
	self.pending_round_join = FALSE;
	PlayerRefreshScoreboardInfo(self);

	self.classname = "player";
	self.solid = SOLID_SLIDEBOX;

	// mp_noblock is handled by PM_NoblockStash/Restore in sh_pmove.qc:
	// per-cmd, the move loop temporarily sets every OTHER live player to
	// SOLID_NOT, runs the move (so pmove traces pass through them), and
	// restores solidity before bullet traces in PreThink. No per-player
	// dim bit, no 8-player cap, applies on the next tick when mp_noblock
	// toggles.

	PM_ReadMovevars();

	// mp_deadbodies 0: no persistent corpses — retire this player's body the
	// moment they respawn.  >=1: keep it (1-per-player is enforced in
	// DetachAsCorpse, which retires the PREVIOUS body on the next death), so
	// leave last_corpse pointing at it.  Networked retire — a bare remove() on
	// a PVSF_NOREMOVE corpse is silent and would ghost on clients.
	if (self.last_corpse)
	{
		if (cvar("mp_deadbodies") == 0)
		{
			if (self.last_corpse.classname == "player_visual_proxy"
			    && self.last_corpse.vis_is_corpse)
				VisProxy_RetireCorpse(self.last_corpse);
			self.last_corpse = world;
		}
	}

	Player_VisualProxy_Ensure(self);

	// Set the player entity's model to the same HLMDL as the visual proxy.
	// This gives MOVE_HITMODEL a mesh to trace against for hitbox detection.
	// The player entity is invisible — the visual proxy handles rendering.
	// Defensive: only read .model if the pointed-at entity is really a
	// visual proxy.  A stale alias to e.g. a func_breakable would otherwise
	// bind the player to a BSP submodel (*N), visibly "attaching" that
	// breakable's geometry to the player every tick.
	if (self.player_visual_proxy
	    && self.player_visual_proxy.classname == "player_visual_proxy")
		setmodel(self, self.player_visual_proxy.model);

	// alpha = -1 alone isn't a reliable "invisible" signal on QW player
	// entities — FTE's renderer sometimes ignores it and renders the player
	// model anyway, AND if server and client's precache tables are out of
	// sync (e.g. after a cl_menumap→connect transition), the engine can
	// even render the player with a BSP submodel's geometry — hence the
	// "breakable attached to player" ghost brush bug.
	//
	// Force the entity to be sent ONLY to the owning client (drawonlytoclient)
	// — the owner doesn't render their own body in first-person anyway, so
	// no visible copy ever exists on any client.  Hitbox traces happen
	// server-side, unaffected by this filter.
	self.alpha = -1;
	self.drawonlytoclient = self;

	self.frame = CSANIM_IDLE;
	self.movetype = MOVETYPE_NONE;  // engine physics off; we run our own
	self.health = 100;
	// CS economy: Kevlar / helmet / defuse kit are lost on death — clear
	// them every (re)spawn so they must be re-bought each life.  money is
	// NOT reset here (it persists across lives/rounds; see Money_EnsureStart).
	self.armor = 0;
	self.has_helmet = 0;
	self.has_defusekit = 0;
	self.velocity = '0 0 0';
	PlayerPlaceAtSpawnPoint();
	// PlayerPlaceAtSpawnPoint puts origin at the spawn point (typically the
	// floor). With pm_player_z_offset > 0 the bbox now extends below origin,
	// so the bbox bottom would be below the floor. Lift origin by the same
	// offset so the bbox bottom lands on the floor and the model renders
	// with its feet at the floor.
	setorigin(self, self.origin + [0, 0, pm_player_z_offset]);
	PlayerApplyTeamColours();
	self.fixangle = TRUE;
	// setmodel resets mins/maxs — restore collision box after
	SetHitboxSize(self, PM_MINS, PM_MAXS);
	self.view_ofs = PM_VIEW_OFS;

	// initialise our movement state
	self.pm_movetype     = PM_MOVETYPE_NORMAL;
	self.pm_jump_held    = FALSE;
	self.pm_jump_msec    = 0;
	self.pm_waterjumptime = 0;
	self.pm_in_duck      = FALSE;
	self.pm_duck_msec    = 0;
	self.pm_oldbuttons   = 0;
	self.pm_timecarry    = 0;
	self.pm_step_time    = 0;
	// Drop any live grapple from the previous life so it doesn't leak the
	// projectile entity or rope state past respawn; clear the held-edge
	// latch so the next life registers a fresh +grapple rising edge.
	W_GrappleRelease(self);
	self.grapple_rope_active  = 0;
	self.grapple_anchor       = '0 0 0';
	self.pm_grapple_held_last = 0;
	Carry_Drop(self);   // drop any prop carried from the previous life
	self.flags           = self.flags & ~FL_DUCKING;
	self.wep_action_id   = 0;
	self.gauss_charge_state = 0;
	self.gauss_charge_started = 0;
	self.gauss_charge_next_ammo = 0;
	self.glock_burst_count = 0;

	// Give starting weapons.
	//  - If survived_round is set, the player was alive when the round ended:
	//    keep their slot_* fields, but refill mag/reserve ammo to max for
	//    each weapon they're carrying. W_GiveStartingAmmo zeros every
	//    ammo field then refills based on the current slot_* values, so
	//    calling it with the preserved slots gives "respawn with full ammo
	//    for whatever you kept".
	//  - Otherwise, apply the server-configured default loadout from the
	//    sv_default_* cvars and (re)populate starting ammo.
	if (self.survived_round)
	{
		W_GiveStartingAmmo();
	}
	else if (cvar("sv_gamemode") == GAMEMODE_PAINTGUN)
	{
		// Paintgun gamemode: paintball-only loadout, no secondary /
		// melee / utility.  Players still spawn with snowballs because
		// snowball-tag also counts as a kill in this mode (the user
		// asked for the same lethality as the paintball), so a thrown
		// snowball is also a valid kill option.
		self.slot_primary   = WEP_PAINTBALL;
		self.slot_secondary = WEP_NONE;
		self.slot_melee     = WEP_NONE;
		self.slot_utility   = WEP_SNOWBALL;
		W_GiveStartingAmmo();
	}
	else
	{
		self.slot_primary   = Weapon_IdFromStringOrDefault(cvar_string("sv_default_primary"),   WEP_NONE);
		self.slot_secondary = Weapon_IdFromStringOrDefault(cvar_string("sv_default_secondary"), WEP_NONE);
		self.slot_melee     = Weapon_IdFromStringOrDefault(cvar_string("sv_default_melee"),     WEP_NONE);
		// "None" melee in the create-server loadout means bare fists, not an
		// empty hand — back-fill WEP_MELEE so every player spawns with a melee.
		if (self.slot_melee == WEP_NONE)
			self.slot_melee = WEP_MELEE;
		// Utility loadout is a comma-separated weapon-id list ("33,34" =
		// HE+Flash) so a single round-start can grant multiple grenades.
		// The active utility (slot_utility) is the first valid id; any
		// extras get their starting ammo in W_GiveStartingAmmo's post-
		// pass and are reachable via the utility-cycle key.
		self.slot_utility   = Weapon_FirstIdFromList(cvar_string("sv_default_utility"), WEP_NONE);
		W_GiveStartingAmmo();
	}
	self.survived_round = 0;  // consume the flag so it doesn't leak to future spawns

	// Defuse: if no terrorist was alive when the round's bomb assignment ran,
	// it deferred (sv_defuse_pending_red_pickup) — the first RED to spawn here
	// picks the bomb up.  Clears the flag so only one carrier is granted.
	if (cvar("sv_gamemode") == GAMEMODE_DEFUSE
	 && sv_defuse_pending_red_pickup
	 && self.player_team == TEAM_RED)
	{
		self.ammo_cfc4 = 1;
		sv_defuse_pending_red_pickup = 0;
	}

	// Wipe last life's damage report row + column so the next death-screen
	// panel only shows damage dealt/taken THIS life. (See sv_weapons.qc
	// DamageReport_Record / DamageReport_Send.)
	DamageReport_ClearForPlayer(num_for_edict(self) - 1);

	// Clear stale weapon state from previous life, then equip best available
	W_ClearWeaponBindings();
	self.weapon = WEP_NONE;
	if (self.slot_primary)
		W_SelectWeapon(self.slot_primary);
	else if (self.slot_secondary)
		W_SelectWeapon(self.slot_secondary);
	else if (self.slot_melee)
		W_SelectWeapon(self.slot_melee);
	else if (self.slot_utility)
		W_SelectWeapon(self.slot_utility);

	PM_EnsurePredictionProxy(self);
	PM_SyncPredictionProxy(self);

	// nettest: force a FULL ammo resync on EVERY spawn.  A respawn reuses the existing prediction proxy, so the
	// was_new full-send inside PM_EnsurePredictionProxy is skipped, and PM_SyncPredictionProxy only sends ammo
	// bytes that CHANGED vs the cached send — so respawning into a loadout that matches the cache sends NO ammo,
	// leaving the client's working registers stale (HUD reads 0/0) until a real change (drop+pickup) re-seeds
	// them.  Re-arm the AMMO section + every used mask bit (mirrors the was_new block ~line 1889) so the next
	// SendEntity writes all slot/utility ammo values.
	//
	// CRITICAL: mb1 MUST include bit 8 (ammo_cfc4 / C4 carry).  It was previously 7 (bits 1/2/4 only), so the
	// one ammo field never force-resent on respawn was the bomb-carry flag.  In Defuse, the round-start bomb
	// re-assignment can leave a SURVIVING re-picked carrier's ammo_cfc4 netting 1->0->1 in a single frame, which
	// the proxy change-detect (proxy.ammo_cfc4 != player.ammo_cfc4) sees as UNCHANGED -> no delta -> the client's
	// predicted_player.ammo_cfc4 stays stale at 0 -> the HUD C4 slot vanishes AND the plant animation never starts
	// (both gate on predicted_player.ammo_cfc4 > 0), even though the bomb plants server-side.  Forcing bit 8 here
	// (and in the was_new baseline) re-sends the carry flag on every (re)spawn regardless of the cache match.
	if (self.pm_prediction_proxy)
	{
		self.pm_prediction_proxy.SendFlags = self.pm_prediction_proxy.SendFlags | PM_SF_AMMO;
		self.pm_prediction_proxy.pm_ammo_mb0 = 255;
		self.pm_prediction_proxy.pm_ammo_mb1 = 15;   // bits 1/2/4 = he/flash/smoke, bit 8 = ammo_cfc4 (C4 carry)
		self.pm_prediction_proxy.pm_ammo_mb2 = 0;
		self.pm_prediction_proxy.pm_ammo_mb3 = 0;
		self.pm_prediction_proxy.pm_ammo_mb4 = 0;
		self.pm_prediction_proxy.pm_ammo_mb5 = 0;
		self.pm_prediction_proxy.pm_ammo_mb6 = 0;
	}

	// Push the new origin + cleared vis_is_dead to the visual proxy right
	// now so round-restart respawns don't leave the old corpse rendered at
	// the death location until the next PostThink tick. (Especially visible
	// on RoundRestart where many players teleport on the same frame.)
	Player_VisualProxy_Sync(self);

	// Debug: spawn pickup weapons in front of the player
	if (cvar("sv_debug_weapons"))
	{
		entity saved_self = self;
		makevectors(self.angles);
		sv_debug_weapon_spawning = TRUE;

		// Spawn manifest-listed debug weapons in a grid.
		float col, row, i, wep;
		vector base = saved_self.origin;

		for (i = 0; i < WeaponManifest_DebugCount(); i = i + 1)
		{
			wep = WeaponManifest_DebugWeapon(i);
			row = floor(i / 7);
			col = i - row * 7;
			SV_DebugSpawnWeaponId(SV_DebugWeaponOrigin(base, row, col), wep);
		}

		self = saved_self;
		sv_debug_weapon_spawning = FALSE;
	}
};

void() PutClientInServer =
{
	// Assign a unique dimension bit so we can exclude individual players
	// from multicasts (e.g. shooter doesn't get their own impact effects).
	// dimension_see = 255 means the player receives all dimensions.
	// dimension_seen = unique bit means multicasts can exclude just this player
	// via `dimension_send & ~target.dimension_seen`. Previously this was set
	// to 255, which made the dedupe trick silently exclude every player
	// (~255 == 0 → no recipients) — owner-exclude in W_GrenadeExplode /
	// W_HLGrenadeExplode / etc. did nothing. Per-slot unique bits fix that
	// (8 max; players past slot 7 fall back to 255 and can't be excluded).
	float slot = num_for_edict(self) - 1;  // 0-based player slot
	float dim_bits[8] = {1, 2, 4, 8, 16, 32, 64, 128};
	if (slot < 8)
		self.dimension_seen = dim_bits[slot];
	else
		self.dimension_seen = 255;
	self.dimension_see  = 255;

	player_chain_add(self);
	Prog_Load(self);	// nettest progression: load persistent XP/level (async, GUID-keyed)
	EnvSun_StuffPlayer(self);	// sun-direction cvars for r_shadows 2 (also keeps r_sun_colour blanked; god rays removed)
	PlayerBeginTeamSelection();
};

void() ClientDisconnect =
{
	Prog_Save(self);	// nettest progression: flush persistent XP/level before teardown

	self.is_bot = FALSE;	// engine recycles this slot — don't let a stale bot flag ride into a real client (see SV_PlayerHasNetchan)

	Carry_Drop(self);   // release any carried prop so it falls and the link clears

	if (self.pm_prediction_proxy)
	{
		remove(self.pm_prediction_proxy);
		self.pm_prediction_proxy = world;
	}

	// Remove visual proxy — without this it persists with PVSF_NOREMOVE
	// and keeps sending stale data (negative team byte) to all clients
	if (self.player_visual_proxy)
	{
		remove(self.player_visual_proxy);
		self.player_visual_proxy = world;
	}

	// Remove from player chain so round logic doesn't count this player
	player_chain_remove(self);

	// Clear model so the player entity disappears from the world
	setmodel(self, "");
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_NONE;

	// Reset state so a stale entity doesn't affect game logic
	self.health = 0;
	self.is_dead = TRUE;
	self.death_time = 0;
	self.player_team = TEAM_NONE;
	self.player_model_index = 0;
	self.weapon = WEP_NONE;
	self.velocity = '0 0 0';
	self.modelindex = 0;

	// Wipe info keys so the scoreboard doesn't render a ghost row for
	// this slot after disconnect. Especially important on map-change
	// hand-offs where info_blobs would otherwise persist across the
	// level load.
	forceinfokey(self, "name",     "");
	forceinfokey(self, "modteam",  "");
	forceinfokey(self, "dead",     "");
	forceinfokey(self, "deaths",   "");
	forceinfokey(self, "topcolor", "");
	forceinfokey(self, "bottomcolor", "");

	bprint(PRINT_HIGH, self.netname);
	bprint(PRINT_HIGH, " has left the game.\n");
};


void() SetNewParms =
{
};

void() SetChangeParms =
{
};

void() info_player_start =
{
};

void(float elapsedtime) SV_PausedTic =
{
	// The menu backdrop is a decorative listen server that MUST keep ticking (rbe physics settle dropped
	// weapons, camera cycles) even though the menu is up.  FTE auto-pauses a listen server when the menu is
	// open with no spawned player (the backdrop client is parked on TEAM_NONE) — the maxclients 2 /
	// deathmatch 1 hack in Menu_StartBackdrop does NOT suppress it.  Unpause the backdrop on sight so the
	// rbe (Box3D/ODE) world keeps stepping and drops reach their rest/sleep latch.  Real games
	// (sv_backdrop 0) keep the intended menu pause.
	if (cvar("sv_backdrop"))
		setpause(0);
};

// Hitclaim tracking fields (last_damaged_target, last_damaged_time)
// are declared in server/sv_customdefs.qc so sv_weapons.qc can also
// write them.

// Process a client-sent hitclaim. Wire format:
//     hitclaim <target_slot> <body_damage> <bone_id>
// where body_damage is the pre-hitgroup falloff result and bone_id is
// trace_bone_id from the client's MOVE_HITMODEL traceline (0 = no info,
// treated as generic/body — this is what melee sends).
//
// sv_trust_clienthits gates acceptance:
//   0 = ignore (server-auth only — existing lagcomp trace decides)
//   1 = soft trust (accept claim, apply sanity caps + friendly-fire + PVS)
//   2 = full trust (accept with minimal dedup only)
float(string command_string) SV_HandleHitclaim =
{
	// Diagnostics gated on sv_debug_hitclaim — uses print() so output is
	// visible without `developer 1`. Pairs with cl_debug_hitclaim on the
	// client. Cheap to leave the cvar at 0 in production: a single cvar
	// read per hit before any work happens.
	float dbg = cvar("sv_debug_hitclaim");
	if (dbg) print("[hitclaim] enter\n");

	float mode = cvar("sv_trust_clienthits");
	if (mode < 1) {
		if (dbg) print(sprintf("[hitclaim] reject: sv_trust_clienthits=%g (<1)\n", mode));
		return 0;
	}

	// self is the attacker (engine-set before SV_ParseClientCommand).
	if (!self || self.classname != "player") {
		if (dbg) print("[hitclaim] reject: self is not a player\n");
		return 0;
	}
	if (self.is_dead) {
		if (dbg) print(sprintf("[hitclaim] reject: %s is dead\n", self.netname));
		return 0;
	}
	// No TEAM_NONE early-exit — FFA / warmup / non-teamplay modes have
	// every player on TEAM_NONE, and rejecting those drops every claim
	// silently (the "splash but no damage" symptom).  The friendly-fire
	// branch below already enforces same-team-no-damage when applicable
	// and short-circuits cleanly when both players are TEAM_NONE.

	float target_slot = stof(argv(1));
	float body_damage = stof(argv(2));
	float bone_id     = stof(argv(3));
	// argv(4) = client-classified hitgroup (the server recomputes from bone
	// below); argv(5) = the proxy's life serial, used to reject stale claims.
	float claim_life_serial = stof(argv(5));

	if (target_slot <= 0 || target_slot > 32) {
		if (dbg) print(sprintf("[hitclaim] reject: target_slot %g out of 1..32\n", target_slot));
		return 0;
	}
	if (body_damage <= 0) {
		if (dbg) print(sprintf("[hitclaim] reject: body_damage %g <= 0\n", body_damage));
		return 0;
	}

	entity target = edict_num(target_slot);
	if (!target || target == world) {
		if (dbg) print(sprintf("[hitclaim] reject: edict_num(%g) returned world/null\n", target_slot));
		return 0;
	}
	if (target.classname != "player") {
		if (dbg) print(sprintf("[hitclaim] reject: target slot %g classname='%s' (not player)\n", target_slot, target.classname));
		return 0;
	}
	if (target.is_dead) {
		if (dbg) print(sprintf("[hitclaim] reject: target %s is dead\n", target.netname));
		return 0;
	}
	if (target == self) {
		if (dbg) print("[hitclaim] reject: self-hit\n");
		return 0;
	}
	// Stale-claim rejection (mirrors SV_HandleProjhitClaim).  The client sends
	// the proxy's life serial; if it no longer matches the target's CURRENT
	// life, the client shot an old-life ghost/corpse proxy (a stale visual
	// still rendered after the player respawned), so it must NOT damage the
	// freshly-respawned player.  Doing this rejection SERVER-side is what lets
	// us drop the brittle CLIENT-side vis_is_dead gate in CSQC_SendHitclaim that
	// was false-negating legitimate LIVE hits — the "blood but no damage under
	// sv_trust_clienthits 1" bug.
	if (claim_life_serial > 0
	    && target.player_life_serial > 0
	    && claim_life_serial != target.player_life_serial) {
		if (dbg) print(sprintf("[hitclaim] reject: stale life serial claim=%g live=%g target=%s\n",
		                       claim_life_serial, target.player_life_serial, target.netname));
		return 0;
	}

	// Hitgroup: TRUST the client's classification in argv(4).  The client ran
	// W_HitgroupClassify with the player model loaded for rendering, which is
	// far more reliable than re-deriving it here: W_BoneToHitgroup needs a ready
	// trace_ent + model tag state we don't have in the post-cmd-parse context,
	// and was silently returning GENERIC — so HEADSHOTS dealt only body damage
	// and the server didn't kill, while the shooter's client (which DID apply
	// the head multiplier) predicted the kill.  That mismatch is exactly the
	// "victim dead on the floor for the shooter, but alive with full-minus-body-
	// damage hp and walking around on their own screen" desync.  The projhit
	// handler already trusts the client hitgroup; do the same here.  argv(4) is
	// empty on a legacy 3-arg claim → fall back to the old bone lookup.
	float hitgroup;
	if (argv(4) != "")
	{
		hitgroup = stof(argv(4));
		if (hitgroup < 0 || hitgroup > 7)
			hitgroup = HITGROUP_GENERIC;
	}
	else
	{
		hitgroup = HITGROUP_GENERIC;
		if (bone_id > 0)
		{
			entity saved_te = trace_ent;
			trace_ent = target;
			hitgroup = W_BoneToHitgroup(bone_id);
			trace_ent = saved_te;
		}
	}
	float damage = body_damage * W_HitgroupDamageMultiplier(hitgroup);

	// Paintgun gamemode: every player-targeted hitclaim is a tag kill,
	// matching the server-side direct-damage path in sh_wpn_paintball /
	// sh_wpn_snowball.  Without this override the server's hitclaim
	// receiver would apply only the falloff body damage (~4-7) the
	// client computed, since W_ShouldDeferToClaim defers paintball
	// player damage to the client claim — and the client doesn't know
	// the gamemode-tagged-kill rule.  Bypass the soft-trust cap below
	// because 1000 is the gamemode's intended damage, not a manufactured
	// claim.
	float paintgun_kill = (cvar("sv_gamemode") == GAMEMODE_PAINTGUN);
	if (paintgun_kill)
		damage = 1000;

	// Soft-trust sanity: cap BODY damage, enforce friendly-fire, PVS
	// check. Headshot multiplier is applied AFTER the cap so a legit
	// ~50-body headshot can still land 200 final, but a manufactured
	// body=999 claim gets clipped before the multiplier.
	if (mode == 1 && !paintgun_kill)
	{
		if (body_damage > 200) damage = 200 * W_HitgroupDamageMultiplier(hitgroup);

		// FF check — bypassed in unified-team modes (FFA + Bhop) where
		// every player is fair game regardless of the backend team value.
		// Without this gate, FFA players who happened to pick same-side
		// models (both blue or both red) had their hitclaims silently
		// dropped — bullets did zero damage even though tracelines
		// landed. Mirrors the W_ApplyDamage FF gate in sv_weapons.qc.
		if (!Gamemode_HasUnifiedTeams()
		    && self.player_team == target.player_team
		    && self.player_team != TEAM_NONE
		    && !cvar("mp_friendlyfire"))
		{
			if (dbg) print(sprintf("[hitclaim] reject: friendly-fire (team=%g)\n", self.player_team));
			return 0;
		}

		// The checkpvs(attacker_eye -> target) LOS gate was REMOVED here.  It
		// existed ONLY on the trust path (the trust=0 server-auth trace has no
		// such gate) and silently dropped visually-valid client hitclaims:
		// checkpvs is leaf/cluster-granular (false negatives across portals,
		// just-relinked targets, coarse-vis maps), it ignores lag-comp (the
		// client saw the target a few ms ago), and it would reject legitimate
		// wallbangs (penetrating shots).  Net effect: bullets drew blood + a
		// hitmarker but dealt ZERO damage with sv_trust_clienthits 1, while
		// trust 0 (server-auth) hit fine.  Trust mode trusts the client's own
		// trace; the body-damage cap above + W_ApplyDamage's team/FF gate stay.
	}

	// No dedup: when sv_trust_clienthits >= 1, W_PenetratingHitscanShoot's
	// player-damage path is gated off via W_ShouldDeferToClaim for shooters
	// that push cl_predict_hits (default ON), so the claim is the SOLE
	// source of player damage and can't double-up. The previous dedup
	// check was rejecting visually-accurate claims because the server's
	// lag-comped trace landed a sliver of damage on the same target ~ms
	// earlier — the cause of the "blood particles, no damage" reports.

	// Stamp the target's death_hitgroup BEFORE W_ApplyDamage so a lethal
	// claim's gib-on-headshot path inside W_ApplyDamage sees the right
	// hitgroup (hitscan paths set this directly; without this write the
	// hitclaim path would always read whatever the previous shot stamped).
	target.death_hitgroup = hitgroup;

	float applied = W_ApplyDamage(self, target, damage);

	if (dbg)
	{
		print(sprintf("[hitclaim] %s -> slot %g body=%.0f bone=%g\n",
			self.netname, target_slot, body_damage, bone_id));
		print(sprintf("[hitclaim]   hg=%g dmg=%.0f applied=%.0f mode=%g\n",
			hitgroup, damage, applied, mode));
	}

	return applied;
};

// Client-trusted breakable damage handler.  Mirror of SV_HandleHitclaim
// for func_breakable targets — when sv_trust_clientbreak is on, the
// client emits `cmd breakclaim <entnum> <damage>` per damaging shot
// (CSQC_SendBreakClaim in sh_weapon_logic.qc) and we apply that damage
// here.  Server's own hitscan path defers via W_ShouldDeferBreakToClaim
// so the same shot doesn't double up.  Wire format:
//   cmd breakclaim <target_entnum> <damage>
// Validates: trust mode on, attacker is a live player, target is a
// damageable func_breakable.  Damage is sanity-capped at 500 per claim.
float(string command_string) SV_HandleBreakclaim =
{
	float dbg = cvar("sv_debug_hitclaim");

	if (cvar("sv_trust_clientbreak") < 1) {
		if (dbg) print("[breakclaim] reject: sv_trust_clientbreak < 1\n");
		return 0;
	}

	if (!self || self.classname != "player") {
		if (dbg) print("[breakclaim] reject: self is not a player\n");
		return 0;
	}
	if (self.is_dead) {
		if (dbg) print(sprintf("[breakclaim] reject: %s is dead\n", self.netname));
		return 0;
	}

	float target_entnum = stof(argv(1));
	float body_damage   = stof(argv(2));

	if (target_entnum <= 0) {
		if (dbg) print(sprintf("[breakclaim] reject: target_entnum %g <= 0\n", target_entnum));
		return 0;
	}
	if (body_damage <= 0) {
		if (dbg) print(sprintf("[breakclaim] reject: body_damage %g <= 0\n", body_damage));
		return 0;
	}

	entity target = edict_num(target_entnum);
	if (!target || target == world) {
		if (dbg) print(sprintf("[breakclaim] reject: edict_num(%g) returned world/null\n", target_entnum));
		return 0;
	}
	if (target.classname != "func_breakable") {
		if (dbg) print(sprintf("[breakclaim] reject: ent %g classname='%s' (not func_breakable)\n", target_entnum, target.classname));
		return 0;
	}
	if (target.takedamage != DAMAGE_YES) {
		if (dbg) print(sprintf("[breakclaim] reject: ent %g not damageable\n", target_entnum));
		return 0;
	}
	if (target.health <= 0) {
		if (dbg) print(sprintf("[breakclaim] reject: ent %g already broken\n", target_entnum));
		return 0;
	}

	// Sanity cap — bound the damage a single claim can apply so a
	// crafted client can't one-shot a high-HP brush.  500 covers any
	// legitimate single-shot damage in this mod (max base damage * any
	// reasonable falloff multiplier).
	float damage = body_damage;
	if (damage > 500) damage = 500;

	// Re-entrancy guard: W_ApplyDamage's breakable-defer gate would
	// otherwise reject this very call (see sv_weapons.qc).  Set the
	// flag so the gate skips, restore after.
	sv_in_breakclaim_apply = TRUE;
	float applied = W_ApplyDamage(self, target, damage);
	sv_in_breakclaim_apply = FALSE;

	if (dbg)
		print(sprintf("[breakclaim] %s -> #%g dmg=%.0f applied=%.0f\n",
			self.netname, target_entnum, damage, applied));

	return applied;
};

float(string command_string, string expected_classname) SV_HandleProjhitClaim =
{
	float dbg = cvar("sv_debug_hitclaim");

	float mode = cvar("sv_trust_clienthits");
	if (mode < 1) {
		if (dbg) print(sprintf("[projhit] reject: sv_trust_clienthits=%g (<1)\n", mode));
		return 0;
	}

	if (!self || self.classname != "player") {
		if (dbg) print("[projhit] reject: self is not a player\n");
		return 0;
	}
	if (self.is_dead) {
		if (dbg) print(sprintf("[projhit] reject: %s is dead\n", self.netname));
		return 0;
	}

	float target_slot     = stof(argv(1));
	float body_damage     = stof(argv(2));
	float claim_action_id = stof(argv(3));
	float claim_life_serial = stof(argv(4));
	// argv(5) = hitgroup byte (0..7, HITGROUP_*).  Client resolves it
	// on its CSQC fake-projectile touch via W_HitgroupClassify so the
	// server doesn't need an unreliable MOVE_HITMODEL probe from the
	// touch context here.  Missing on older clients → stof = 0 = GENERIC.
	float claim_hitgroup  = stof(argv(5));
	if (claim_hitgroup < 0 || claim_hitgroup > 7)
		claim_hitgroup = 0;

	if (target_slot <= 0 || target_slot > 32) {
		if (dbg) print(sprintf("[projhit] reject: target_slot %g out of 1..32\n", target_slot));
		return 0;
	}
	if (body_damage <= 0) {
		if (dbg) print(sprintf("[projhit] reject: body_damage %g <= 0\n", body_damage));
		return 0;
	}

	entity target = edict_num(target_slot);
	if (!target || target == world) {
		if (dbg) print(sprintf("[projhit] reject: edict_num(%g) returned world/null\n", target_slot));
		return 0;
	}
	if (target.classname != "player") {
		if (dbg) print(sprintf("[projhit] reject: target slot %g classname='%s' (not player)\n", target_slot, target.classname));
		return 0;
	}
	if (target.is_dead) {
		if (dbg) print(sprintf("[projhit] reject: target %s is dead\n", target.netname));
		return 0;
	}
	if (claim_life_serial > 0
	    && target.player_life_serial > 0
	    && claim_life_serial != target.player_life_serial) {
		if (dbg) print(sprintf("[projhit] reject: stale life serial claim=%g live=%g target=%s\n",
		                       claim_life_serial, target.player_life_serial,
		                       target.netname));
		return 0;
	}
	if (target == self) {
		if (dbg) print("[projhit] reject: self-hit\n");
		return 0;
	}

	// Anti-spoof: validate action_id against the player's monotonic
	// fire counter rather than requiring the live projectile entity
	// to still exist.  Server-side physics regularly consumes the
	// projectile (fuse expiry, world touch, ODE-driven settle) before
	// the client's hit claim arrives — they're independent sims and
	// the trajectories diverge slightly under any non-zero ping.
	// Looking for the entity in that window rejected ~95% of legit
	// hits ("[projhit] reject: no proj_paintball ... action_id=N" spam
	// for every shot the player fired).
	//
	// New gate:
	//   1. claim_action_id must be in (wep_action_id - 64, wep_action_id]
	//      — proves the player actually fired this shot recently.
	//   2. claim_action_id must not already appear in proj_consumed_ids
	//      — prevents a crafted client from replaying the same shot.
	if (claim_action_id <= 0 || claim_action_id > self.wep_action_id)
	{
		if (dbg) print(sprintf("[projhit] reject: action_id=%g out of range (current=%g)\n",
		                       claim_action_id, self.wep_action_id));
		return 0;
	}
	if (claim_action_id <= self.wep_action_id - 64)
	{
		if (dbg) print(sprintf("[projhit] reject: action_id=%g too old (current=%g window=64)\n",
		                       claim_action_id, self.wep_action_id));
		return 0;
	}
	float ri;
	for (ri = 0; ri < 32; ri = ri + 1)
	{
		if (self.proj_consumed_ids[ri] == claim_action_id)
		{
			if (dbg) print(sprintf("[projhit] reject: action_id=%g already consumed (replay)\n",
			                       claim_action_id));
			return 0;
		}
	}
	// Stamp this id into the ring (oldest slot wins).
	self.proj_consumed_ids[self.proj_consumed_ring_idx] = claim_action_id;
	self.proj_consumed_ring_idx = (self.proj_consumed_ring_idx + 1);
	if (self.proj_consumed_ring_idx >= 32)
		self.proj_consumed_ring_idx = 0;

	// Still scan for and remove the matching projectile if it's
	// alive — keeps the world clean of tagged orphans.  No early-
	// return on miss; the claim is authorised by the action_id
	// check above.
	entity proj = findchain(classname, expected_classname);
	while (proj)
	{
		if (proj.owner == self && proj.wep_action_id == claim_action_id)
		{
			remove(proj);
			break;
		}
		proj = proj.chain;
	}

	// Use the hitgroup the client already resolved.  Engine probes
	// from a projectile-touch context were unreliable (most landed
	// on HITGROUP_GENERIC even on clear arm / leg / head hits) so we
	// no longer try to re-classify here — the client's Z-height
	// classifier produces consistent results and is the authority.
	float proj_hitgroup = claim_hitgroup;
	target.death_hitgroup = proj_hitgroup;

	float damage = body_damage * W_HitgroupDamageMultiplier(proj_hitgroup);
	float paintgun_kill = (cvar("sv_gamemode") == GAMEMODE_PAINTGUN);
	if (paintgun_kill)
		damage = 1000;   // tag mode always lethal, override multiplier

	// Soft-trust sanity: cap body damage, enforce friendly-fire + PVS.
	// Mirrors SV_HandleHitclaim's gate exactly.
	if (mode == 1 && !paintgun_kill)
	{
		// Cap pre-multiplier body damage to match the hitscan path;
		// the headshot multiplier still applies on top.
		if (body_damage > 200)
			damage = 200 * W_HitgroupDamageMultiplier(proj_hitgroup);

		if (!Gamemode_HasUnifiedTeams()
		    && self.player_team == target.player_team
		    && self.player_team != TEAM_NONE
		    && !cvar("mp_friendlyfire"))
		{
			if (dbg) print(sprintf("[projhit] reject: friendly-fire (team=%g)\n", self.player_team));
			return 0;
		}

		if (!checkpvs(self.origin + self.view_ofs, target))
		{
			if (dbg) print(sprintf("[projhit] reject: target %s not in PVS of attacker\n", target.netname));
			return 0;
		}
	}


	float applied = W_ApplyDamage(self, target, damage);

	if (dbg)
		print(sprintf("[projhit] %s -> slot %g body=%.0f action=%g applied=%.0f\n",
			self.netname, target_slot, body_damage, claim_action_id, applied));

	return applied;
};

// Per-client flood cap for the hit-reporting stringcmds.  The engine applies no
// flood protection to client stringcmds (only chat/suicide), so a buggy/cheating
// client could spam hitclaim/cs/... toward a reliable-backbuf overflow.  Meters
// them in a 1s sliding window on the attacker (self); returns FALSE to drop once
// over sv_claim_flood_max.  Generous default (60) leaves >2x headroom over the
// ~26-30/s legit peak, so live play never trips it; 0 disables.
float() SV_ClaimFloodOK =
{
	float cap = cvar("sv_claim_flood_max");
	if (cap <= 0)
		return TRUE;                              // disabled
	if (time - self.claim_flood_window_start >= 1)
	{
		self.claim_flood_window_start = time;     // roll the window
		self.claim_flood_count = 0;
	}
	self.claim_flood_count = self.claim_flood_count + 1;
	if (self.claim_flood_count > cap)
	{
		if (cvar("sv_debug_hitclaim"))
			print(sprintf("[claim-flood] drop %s: %g > cap %g\n",
			              self.netname, self.claim_flood_count, cap));
		return FALSE;
	}
	return TRUE;
};

// Spectator PVS follow (consumed in SV_RunClientCommand's is_dead branch),
// sent by the client.  spec_track_slot = followed player (1..maxclients,
// 0 = none); spec_view_org/_time = freecam camera origin + when it arrived.
.float  spec_track_slot;
.vector spec_view_org;
.float  spec_view_time;

void(string command_string) SV_ParseClientCommand =
{
	tokenize(command_string);
	string cmd = argv(0);

	if (cmd == "spectrack")
	{
		float st = stof(argv(1));
		if (st < 0 || st > cvar("maxclients")) st = 0;
		self.spec_track_slot = st;
		return;
	}

	if (cmd == "specview")
	{
		// Freecam camera origin — park PVS here when not following a player.
		self.spec_view_org_x = bound(-65536, stof(argv(1)), 65536);
		self.spec_view_org_y = bound(-65536, stof(argv(2)), 65536);
		self.spec_view_org_z = bound(-65536, stof(argv(3)), 65536);
		self.spec_view_time  = time;
		return;
	}

	// Rate-cap the hit-reporting stringcmds before dispatch (engine has none).
	if (cmd == "hitclaim" || cmd == "breakclaim" || cmd == "paintprojhit"
	    || cmd == "snowprojhit" || cmd == "cs")
	{
		if (self && self.classname == "player" && !SV_ClaimFloodOK())
			return;   // silently drop excess
	}

	if (cmd == "hitclaim")
	{
		SV_HandleHitclaim(command_string);
		return;
	}

	if (cmd == "breakclaim")
	{
		SV_HandleBreakclaim(command_string);
		return;
	}

	if (cmd == "paintprojhit")
	{
		SV_HandleProjhitClaim(command_string, "proj_paintball");
		return;
	}

	if (cmd == "snowprojhit")
	{
		SV_HandleProjhitClaim(command_string, "proj_snowball");
		return;
	}

	if (cmd == "cs")
	{
		// Client-shot notification.  Sent by the client's
		// SH_StandardTryFire success path under sv_trust_clienthits >= 1.
		// The server's auto-fire in W_WeaponFrame is gated off in that
		// mode, so the client tells us "I just fired" and we run the
		// authoritative fire here.  Makes server's fire count exactly
		// match the client's — fixes the "extra server shot at end of
		// mag" rate-divergence symptom.
		if (cvar("sv_trust_clienthits") < 1)
			return;
		if (self.classname != "player" || self.is_dead)
			return;

		float reported_wep = stof(argv(1));
		if (reported_wep != self.weapon)
			return;

		// Scope sway bias: optional pitch / yaw deltas (degrees) the
		// client sends when scoped + sv_snipersway > 0.  Apply to
		// self.v_angle around the fire so the authoritative trace
		// direction matches the client's predicted (swayed) aim.
		// Clamp to ±5° (legit sway is bounded to ±2°/axis).
		vector sway_bias = '0 0 0';
		if (argv(2) != "")
			sway_bias_x = bound(-5, stof(argv(2)), 5);
		if (argv(3) != "")
			sway_bias_y = bound(-5, stof(argv(3)), 5);

		self.attack_finished = time;
		if (Weapon_LowerBlocksFire()) return;
		if (Weapon_SprintBlocksFire()) return;
		if (self.fire)
		{
			vector saved_v = self.v_angle;
			self.v_angle_x += sway_bias_x;
			self.v_angle_y += sway_bias_y;
			// Bypass the semi-auto rising-edge gate — the client already
			// edge-validated this shot; the server just executes.
			float saved_oldbtns = self.pm_oldbuttons;
			self.pm_oldbuttons = saved_oldbtns & ~1;   // bit 0 = PM_BTN_FIRE
			self.fire();
			self.pm_oldbuttons = saved_oldbtns;
			self.v_angle = saved_v;
		}
		return;
	}


	if (PlayerHandleTeamCommand(cmd))
		return;

	if (cmd == "setspray")
	{
		SV_HandleSetSpray(command_string);
		return;
	}

	// `cmd playermodel <idx>` — live model-change driven by the main-
	// menu picker.  Gated on sv_playerselect.  Index must be one of the
	// allowed picks (6/7/8).  Alive on a real team swaps immediately;
	// spec / dead stashes the index for next PlayerSpawn.
	if (cmd == "playermodel")
	{
		if (cvar("sv_playerselect") <= 0)
			return;
		float new_idx = stof(argv(1));
		if (new_idx != 6 && new_idx != 7 && new_idx != 8)
			return;
		self.player_model_index = new_idx;
		if ((self.player_team == TEAM_BLUE || self.player_team == TEAM_RED)
		    && !self.is_dead)
			PlayerApplyModel();
		return;
	}

	// `cmd buy <id>` — buy-menu purchase.  id is a weapon manifest id
	// (1..WMF_WEP_LAST) or a BUYITEM_* equipment id (>=10000).  Server is
	// authoritative: re-validate alive + affordability, deduct, then grant.
	// Buy is allowed anytime while alive (no phase gate, per design).
	if (cmd == "buy")
	{
		if (self.classname != "player" || self.is_dead)
			return;
		if (!Player_CanBuy(self))
		{
			sprint(self, PRINT_HIGH, "You can't buy here.\n");
			return;
		}
		float buy_id = stof(argv(1));
		float buy_cost;
		if (BuyItem_IsItem(buy_id))
		{
			buy_cost = BuyItem_Price(buy_id);
			if (self.money < buy_cost)
				return;
			if (!BuyItem_Apply(self, buy_id))
				return;
			AddMoney(self, -buy_cost);
			return;
		}
		// Otherwise a weapon id — must be in a buyable category.
		if (buy_id <= WMF_WEP_NONE || buy_id > WMF_WEP_LAST)
			return;
		if (WeaponManifest_BuyCat(buy_id) == BUYCAT_NONE)
			return;
		buy_cost = WeaponManifest_Price(buy_id);
		if (self.money < buy_cost)
			return;
		AddMoney(self, -buy_cost);
		W_GiveWeaponToSlot(buy_id);
		return;
	}

	if (cmd == "spawnbarrel")
	{
		if (cvar("mp_cheats"))
			phys_barrel_spawn_infront(self);
		else
			sprint(self, PRINT_HIGH, "spawnbarrel requires mp_cheats 1\n");
		return;
	}

	if (cmd == "spawncan")
	{
		if (cvar("mp_cheats"))
			phys_can_spawn_infront(self);
		else
			sprint(self, PRINT_HIGH, "spawncan requires mp_cheats 1\n");
		return;
	}

	if (cmd == "spawnfiles")
	{
		if (cvar("mp_cheats"))
			phys_files_spawn_infront(self);
		else
			sprint(self, PRINT_HIGH, "spawnfiles requires mp_cheats 1\n");
		return;
	}

	// nettest: worst-case physics stress. `spawnflood <N>` rains N barrels into a
	// grid pile in front of you (default 50). Fire the gravity-gun black hole at the
	// pile and A/B `physics_box3d_threads 1` vs `4` to see the Box3D multicore win.
	if (cmd == "spawnflood")
	{
		if (cvar("mp_cheats"))
		{
			float flood_n = stof(argv(1));
			if (flood_n <= 0)
				flood_n = 50;
			phys_flood_spawn(self, flood_n);
		}
		else
			sprint(self, PRINT_HIGH, "spawnflood requires mp_cheats 1\n");
		return;
	}

	// nettest: server-side ragdoll test spawner — fling a standalone leet ragdoll from your aim.
	// (Distinct name from the CSQC `throwragdoll` dev spawner so the two don't collide.)
	if (cmd == "throwragdollsv")
	{
		if (cvar("mp_cheats"))
			Ragdoll_SpawnTest(self);
		else
			sprint(self, PRINT_HIGH, "throwragdollsv requires mp_cheats 1\n");
		return;
	}

	// Clear all corpse ragdolls (test dolls have no corpse owner, so nothing else retires them).
	if (cmd == "killragdollssv")
	{
		if (cvar("mp_cheats"))
			Ragdoll_SweepAll();
		else
			sprint(self, PRINT_HIGH, "killragdollssv requires mp_cheats 1\n");
		return;
	}

	// HL2 carry: +attack while holding a prop throws it (the client suppresses
	// the actual fire and sends this instead of a `cs` client-shot).
	if (cmd == "throwprop")
	{
		// nettest: a held corpse ragdoll throws the same way (Ragdoll_CarryThrow), sharing the fire2 anim.
		if (self.carried_prop != world || self.carried_ragdoll != world)
		{
			if (self.carried_ragdoll != world)
				Ragdoll_CarryThrow(self);
			else
				Carry_Throw(self);
			// Gravity gun: play "fire2" on the throw (the display frame shows
			// fire2 in WS_FIRE while not carrying — Carry_Throw just cleared
			// pm_carrying).  Other carriers (bare-hands +use) have no viewmodel.
			if (self.weapon == WEP_GRAVITYGUN)
			{
				self.weaponstate    = WS_FIRE;
				self.weaponframe    = GRAVGUN_SEQ_FIRE2;
				self.wep_anim_start = time;
				self.wep_nextframe  = time + GRAVGUN_FRAME_INTERVAL;
			}
		}
		return;
	}

	// Menu-driven camera phase selector (see CAM_PHASE_* in sh_customdefs.qc).
	// Stuffcmd'd by m_teamselect as the user navigates the menu so the
	// server can cycle the appropriate set of flagged cameras.
	if (cmd == "cam_phase")
	{
		self.cam_phase = stof(argv(1));
		return;
	}

	// Diagnostic: CSQC's `probe` stuffs this cmd. Fire a matching
	// player-hull tracebox forward from the server-authoritative eye
	// and sprint the result. Compared with the CSQC print side-by-side,
	// any divergence is exactly the prediction-mismatch entity.
	if (cmd == "probe")
	{
		makevectors(self.v_angle);
		vector eye = self.origin + self.view_ofs;
		vector end = eye + v_forward * 1024;
		tracebox(eye, '-16 -16 0', '16 16 56', end, MOVE_NORMAL, self);
		if (trace_fraction < 1)
		{
			sprint(self, PRINT_HIGH, sprintf("^3[probe]^7 server: hit classname='%s' ent=%g origin=%v solid=%g\n",
				trace_ent.classname, num_for_edict(trace_ent), trace_ent.origin, trace_ent.solid));
			sprint(self, PRINT_HIGH, sprintf("              mins=%v maxs=%v model='%s' frac=%.3f endpos=%v\n",
				trace_ent.mins, trace_ent.maxs, trace_ent.model, trace_fraction, trace_endpos));
		}
		else
			sprint(self, PRINT_HIGH, sprintf("^3[probe]^7 server: no hit (full 1024 trace, endpos=%v)\n", trace_endpos));
		return;
	}

	// Diagnostic: dump every SSQC edict whose ACTUAL world bbox is
	// within radius of a given point. BSP submodels keep origin=0,0,0
	// and store their geometry in mins/maxs, so a naive origin-based
	// distance check matches every brush in the map. Use proper
	// point-to-AABB distance instead. Empty engine slots (no class,
	// no model) are skipped. Usage: edicts_near "0 0 0" 32
	if (cmd == "edicts_near")
	{
		vector p = stov(argv(1));
		float  r = stof(argv(2));
		if (r <= 0)
			r = 32;
		sprint(self, PRINT_HIGH, sprintf("^3[edicts_near]^7 scanning bbox within %g of %v:\n", r, p));
		float hits = 0;
		entity e = world;
		while ((e = nextent(e)))
		{
			// Skip unused engine edict slots.
			if (e.classname == "" && e.model == "")
				continue;

			// Closest point on entity's axis-aligned world bbox to p.
			// Works for BSP submodels (origin=0, geom in mins/maxs)
			// AND point entities (mins=maxs=0 → amin=amax=origin, so
			// this collapses to the origin-distance case).
			vector amin = e.origin + e.mins;
			vector amax = e.origin + e.maxs;
			vector closest;
			closest_x = max(amin_x, min(p_x, amax_x));
			closest_y = max(amin_y, min(p_y, amax_y));
			closest_z = max(amin_z, min(p_z, amax_z));
			if (vlen(closest - p) > r)
				continue;

			sprint(self, PRINT_HIGH, sprintf(" ent=%g class='%s' origin=%v solid=%g\n",
				num_for_edict(e), e.classname, e.origin, e.solid));
			sprint(self, PRINT_HIGH, sprintf("    absmin=%v absmax=%v model='%s' send=%s\n",
				amin, amax, e.model, e.SendEntity ? "yes" : "no"));
			hits = hits + 1;
		}
		sprint(self, PRINT_HIGH, sprintf("^3[edicts_near]^7 done, %g matched\n", hits));
		return;
	}

	// Intercept the engine's "noclip" so `bind v noclip` routes to the mod's
	// pmove toggle.  The engine version flips self.movetype which our custom
	// QC pmove ignores, producing the "noclip ON / noclip OFF" print with no
	// actual behaviour change.
	if (cmd == "noclip")
	{
		if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
		{
			self.pm_movetype = PM_MOVETYPE_NORMAL;
			self.solid       = SOLID_SLIDEBOX;
			sprint(self, PRINT_HIGH, "noclip OFF\n");
		}
		else if (cvar("mp_cheats"))
		{
			self.pm_movetype = PM_MOVETYPE_NOCLIP;
			self.solid       = SOLID_NOT;
			sprint(self, PRINT_HIGH, "noclip ON\n");
		}
		else
		{
			sprint(self, PRINT_HIGH, "noclip requires mp_cheats 1\n");
		}
		PM_SyncPredictionProxy(self);
		return;
	}

	if (cmd == "respawn")
	{
		if (!cvar("mp_cheats"))
		{
			sprint(self, PRINT_HIGH, "respawn requires mp_cheats 1\n");
			return;
		}
		if (self.player_team <= TEAM_NONE || self.player_team == TEAM_SPEC)
		{
			sprint(self, PRINT_HIGH, "respawn requires joining a playing team first\n");
			return;
		}
		if (!self.is_dead)
		{
			sprint(self, PRINT_HIGH, "respawn: you're already alive\n");
			return;
		}

		PlayerSpawn();
		sprint(self, PRINT_HIGH, "respawned\n");
		return;
	}

	clientcommand(self, command_string);
};


void() SV_RunClientCommand =
{
	// Team-selecting players: skip pmove entirely. StartFrame's camera
	// cycle owns their position and angles; any pmove step here would
	// leak gravity/friction and cause slow drift off the camera.
	if (self.player_team <= TEAM_NONE)
	{
		input_movevalues = '0 0 0';
		input_buttons = 0;
		self.velocity = '0 0 0';
		return;
	}

	// Dead players: skip pmove entirely. PlayerKilled set solid=SOLID_NOT
	// and velocity=0 already, so the corpse doesn't need physics. Running
	// pmove anyway would let PM_DisentangleFromPlayer fire on the corpse's
	// own tick — when a live player walked into the corpse's bbox, the
	// dead-player pmove would detect "overlap with solid" and shove the
	// corpse away, looking like the live player was pushing it.
	if (self.is_dead)
	{
		input_movevalues = '0 0 0';
		input_buttons = 0;
		self.velocity = '0 0 0';
		// Spectator PVS follow: park this (invisible, SOLID_NOT) edict on
		// the player we're watching so the engine networks the PVS-culled
		// map models around THEM, not our frozen death spot — without this
		// every static prop / cycler / sprite / brushsync model is invisible
		// while spectating.  Slot arrives via the client's "cmd spectrack".
		if (self.spec_track_slot >= 1 && self.spec_track_slot <= cvar("maxclients"))
		{
			entity tgt = edict_num(self.spec_track_slot);
			if (tgt != self && !wasfreed(tgt) && tgt.classname == "player" && !tgt.is_dead)
				setorigin(self, tgt.origin);
		}
		else if (time - self.spec_view_time < 1.0)
		{
			// Freecam: no follow target — park on the client's camera origin
			// (sent throttled via "cmd specview") so map models around the
			// free camera get networked too.
			setorigin(self, self.spec_view_org);
		}
		PM_SyncPredictionProxy(self);
		return;
	}

	// Freeze time: block WASD movement and primary attack
	if (round_phase == ROUND_PHASE_FREEZE)
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
		input_buttons = input_buttons & ~1;
	}

	// func_vehicle: capture the driver's REAL throttle/steer intent HERE, before
	// PM_PlayerMove's driver-lock zeros input_movevalues.  Capturing in the real
	// command path (not the shared pmove stash) stops the low-netfps continuation
	// replay — which replays the already-zeroed cmd_last — from clobbering it back
	// to 0 (which was freezing the car at fwd=0 every tick).
	if (self.pm_driving)
	{
		self.veh_in_fwd  = input_movevalues_x;
		self.veh_in_side = input_movevalues_y;
	}
	if (self.pm_incar)
	{
		self.car_in_fwd   = input_movevalues_x;
		self.car_in_side  = input_movevalues_y;
		self.car_in_brake = (input_buttons & PM_BTN_JUMP) ? 1 : 0;   // Space = handbrake / drift
	}

	PM_PlayerMove();

	if (cvar("sv_debug_wepswap"))
	{
		vector dbg_mv = '0 0 0';
		dbg_mv_x = input_movevalues_x; dbg_mv_y = input_movevalues_y;
		Drift_Append(time, input_timelength * 1000, dbg_mv,
			input_buttons, self.weapon, self.origin, self.velocity);
	}
	SV_CheckTouchTriggers();

	// If a teleport angle snap fired this command, send an engine-level
	// fixangle so the client's view accumulator is updated persistently.
	PM_SyncPredictionProxy(self);

	// Store this command's inputs so PlayerPreThink can replay them on the
	// next frame if no new command arrives in time.
	self.cmd_last_movevalues = input_movevalues;
	self.cmd_last_buttons    = input_buttons;
	self.cmd_last_angles     = input_angles;
	self.cmd_last_time       = time;
};
