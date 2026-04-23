
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

// Strict team-spawn policy: TEAM_BLUE only ever spawns at blue classnames,
// TEAM_RED only ever spawns at red classnames. The opposing team's spawns
// are NEVER queried from the wrong branch. The final fallback to the
// neutral "info_player_start" is only reached if the map has no team-
// specific spawns for this player's team at all — that's a map bug, and
// we emit a developer warning so the mapper notices.
entity() PlayerGetSpawnPointEntity =
{
    entity spawnpoint;
    float is_team_player;

    spawnpoint = world;
    is_team_player = FALSE;

    if (self.player_team == TEAM_BLUE)
    {
        is_team_player = TRUE;
        spawnpoint = PlayerFindSpawnByClassname("info_player_blue");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_start_blue");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_team1");
    }
    else if (self.player_team == TEAM_RED)
    {
        is_team_player = TRUE;
        spawnpoint = PlayerFindSpawnByClassname("info_player_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_start_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_team2");
    }

    float fell_back_to_neutral = FALSE;
    if (!spawnpoint)
    {
        fell_back_to_neutral = is_team_player;
        if (fell_back_to_neutral && cvar("developer"))
        {
            // Gated behind `developer` because FTE's dprint is unconditional
            // (unlike vanilla QC's). Map authors want to see this; end users
            // running vanilla-compat CS maps on the mod don't.
            dprint(sprintf("[spawn] WARNING: no team-%s spawn points found on map %s — "
                "falling back to neutral info_player_start. Mapper should add "
                "info_player_%s / info_player_start_%s entities.\n",
                (self.player_team == TEAM_BLUE) ? "blue" : "red",
                serverkey("mapname"),
                (self.player_team == TEAM_BLUE) ? "blue" : "red",
                (self.player_team == TEAM_BLUE) ? "blue" : "red"));
        }
        spawnpoint = PlayerFindSpawnByClassname("info_player_start");
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
        string team_str = (self.player_team == TEAM_BLUE) ? "BLUE"
                        : (self.player_team == TEAM_RED)  ? "RED"
                        : "NONE";
        string state_str;
        if (fell_back_to_neutral)
            state_str = "FALLBACK (no team spawns)";
        else if (Spawn_IsClear(spawnpoint))
            state_str = "CLEAR";
        else
            state_str = "OCCUPIED (all spawns blocked)";
        string line = sprintf("[spawn] slot %g team=%s picked %s at %v — %s\n",
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

// Apply the correct player model based on team + model_index.
void() PlayerApplyModel =
{
    string mdl;

    if (self.player_model_index == 5)
        mdl = "models/player/sini.mdl";
    else
    {
        float idx = bound(0, self.player_model_index, TEAM_MODEL_COUNT - 1);
        if (self.player_team == TEAM_BLUE)
            mdl = team_blue_models[idx];
        else if (self.player_team == TEAM_RED)
            mdl = team_red_models[idx];
        else
            mdl = "models/player/leet/leet.mdl";
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

    model_idx = bound(0, model_idx, 5); // 0-3 = team models, 5 = sini

    // Same team, just changing model — swap instantly without respawn
    if (self.player_team == new_team && !PlayerNeedsTeamSelection())
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
    PlayerSpawn();

    // Start the first round when the first player joins a team
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
	W_WeaponFrame();
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

            // Send damage flash only to the victim
            {
                msg_entity = self;
                WriteByte(MSG_ONE, SVC_CGAMEPACKET);
                WriteByte(MSG_ONE, CSQC_EVENT_DAMAGE_FLASH);
                WriteByte(MSG_ONE, bound(1, damage, 255));
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

// Cached "last-sent" values for fields that come from the owner (not
// mirrored on the proxy itself) or need encoding. Compared in
// Player_VisualProxy_Sync to decide which section bits to dirty.
.float vps_last_v_pitch;
.float vps_last_anim_top_gen;
.float vps_last_weapon;
.float vps_last_team_model;
.float vps_last_is_dead;
.float vis_last_pose_resync;

.entity player_visual_proxy;

float(entity playerent, float changedflags) Player_Visual_SendEntity =
{
	// Don't send if owner disconnected or has no team
	if (!self.owner || self.owner.player_team < TEAM_BLUE)
		return FALSE;

	WriteByte(MSG_ENTITY, CSQC_ENT_PLAYER_VISUAL);
	WriteByte(MSG_ENTITY, num_for_edict(self.owner));

	float bits = changedflags & (VP_SF_POSE | VP_SF_ANIM | VP_SF_IDENTITY);
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
	}

	if (bits & VP_SF_IDENTITY)
	{
		WriteByte(MSG_ENTITY, self.vps_last_weapon);
		WriteByte(MSG_ENTITY, self.skin);
		WriteByte(MSG_ENTITY, self.colormap);
		WriteByte(MSG_ENTITY, self.vps_last_team_model);
		WriteByte(MSG_ENTITY, self.vps_last_is_dead);
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
		vis.pvsflags = PVSF_NOREMOVE;
		setmodel(vis, "models/player/leet/leet.mdl"); // default until model applied
		vis.SendEntity = Player_Visual_SendEntity;
		player.player_visual_proxy = vis;
	}

	// Apply correct model for team+index (runs every ensure, not just first create)
	entity oldself = self;
	self = player;
	PlayerApplyModel();
	self = oldself;
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
		next_tmbyte = 255;
	else
		next_tmbyte = (player.player_team - 1) * 4 + player.player_model_index;

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
	float ticks = cvar("sv_pose_keepalive_ticks");
	if (ticks < 1) ticks = 1;
	float keepalive_interval = cvar("sv_mintic") * ticks;
	if (keepalive_interval < 0.005) keepalive_interval = 0.015;

	if (vis.origin != player.origin
	    || vis.angles != next_angles
	    || vis.velocity != player.velocity
	    || (time - vis.vis_last_pose_resync) > keepalive_interval)
		bits |= VP_SF_POSE;

	if (vis.frame != player.frame
	    || vis.baseframe != player.baseframe
	    || vis.flags != player.flags
	    || vis.vps_last_v_pitch != player.v_angle_x
	    || vis.vps_last_anim_top_gen != player.anim_top_gen)
		bits |= VP_SF_ANIM;

	if (vis.vps_last_weapon != player.weapon
	    || vis.skin != player.skin
	    || vis.colormap != player.colormap
	    || vis.vps_last_team_model != next_tmbyte
	    || vis.vps_last_is_dead != next_is_dead)
		bits |= VP_SF_IDENTITY;

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
	vis.vps_last_weapon       = player.weapon;
	vis.vps_last_team_model   = next_tmbyte;
	vis.vps_last_is_dead      = next_is_dead;

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
		WriteCoord(MSG_ENTITY, self.origin_x);
		WriteCoord(MSG_ENTITY, self.origin_y);
		WriteCoord(MSG_ENTITY, self.origin_z);

		WriteCoord(MSG_ENTITY, self.velocity_x);
		WriteCoord(MSG_ENTITY, self.velocity_y);
		WriteCoord(MSG_ENTITY, self.velocity_z);

		WriteCoord(MSG_ENTITY, self.view_ofs_x);
		WriteCoord(MSG_ENTITY, self.view_ofs_y);
		WriteCoord(MSG_ENTITY, self.view_ofs_z);

		WriteFloat(MSG_ENTITY, self.flags);
		WriteFloat(MSG_ENTITY, self.pm_movetype);
		WriteFloat(MSG_ENTITY, self.pm_jump_held);
		WriteFloat(MSG_ENTITY, self.pm_jump_msec);
		WriteFloat(MSG_ENTITY, self.pm_waterjumptime);
		WriteFloat(MSG_ENTITY, self.pm_in_duck);
		WriteFloat(MSG_ENTITY, self.pm_duck_msec);
		WriteFloat(MSG_ENTITY, self.pm_oldbuttons);
		WriteFloat(MSG_ENTITY, self.pm_timecarry);
		WriteFloat(MSG_ENTITY, self.pm_teleport_time);
		WriteFloat(MSG_ENTITY, self.pm_ladder_detach_time);
		WriteFloat(MSG_ENTITY, self.pm_fuser2);
		WriteFloat(MSG_ENTITY, self.spread_penalty);
		WriteFloat(MSG_ENTITY, self.fire_spread_penalty);
		WriteFloat(MSG_ENTITY, self.pm_step_time);
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
	}

	if (changedflags & PM_SF_AMMO)
	{
		WriteByte(MSG_ENTITY, self.mag_deagle);
		WriteByte(MSG_ENTITY, self.ammo_deagle);
		WriteByte(MSG_ENTITY, self.mag_ak47);
		WriteByte(MSG_ENTITY, self.ammo_ak47);
		WriteByte(MSG_ENTITY, self.mag_m4a1);
		WriteByte(MSG_ENTITY, self.ammo_m4a1);
		WriteByte(MSG_ENTITY, self.m4a1_silenced);
		WriteByte(MSG_ENTITY, self.mag_flakshotgun);
		WriteByte(MSG_ENTITY, self.mag_pistol);
		WriteByte(MSG_ENTITY, self.ammo_pistol);
		WriteByte(MSG_ENTITY, self.mag_scout);
		WriteByte(MSG_ENTITY, self.ammo_scout);
		WriteByte(MSG_ENTITY, self.mag_357);
		WriteByte(MSG_ENTITY, self.ammo_357);
		WriteByte(MSG_ENTITY, self.mag_m249);
		WriteByte(MSG_ENTITY, self.ammo_m249);
		WriteByte(MSG_ENTITY, self.mag_awp);
		WriteByte(MSG_ENTITY, self.ammo_awp);
		WriteByte(MSG_ENTITY, self.mag_98k);
		WriteByte(MSG_ENTITY, self.ammo_98k);
		WriteByte(MSG_ENTITY, self.mag_shotgun);
		WriteByte(MSG_ENTITY, self.ammo_shotgun);
		WriteByte(MSG_ENTITY, self.mag_m3);
		WriteByte(MSG_ENTITY, self.ammo_m3);
		WriteByte(MSG_ENTITY, self.mag_mp5);
		WriteByte(MSG_ENTITY, self.ammo_mp5);
		WriteByte(MSG_ENTITY, self.mag_crossbow);
		WriteByte(MSG_ENTITY, self.ammo_crossbow);
		WriteByte(MSG_ENTITY, self.mag_grenadelauncher);
		WriteByte(MSG_ENTITY, self.mag_rebar);
		WriteByte(MSG_ENTITY, self.ammo_gauss);
		WriteByte(MSG_ENTITY, self.mag_glock);
		WriteByte(MSG_ENTITY, self.ammo_glock);
		WriteByte(MSG_ENTITY, self.mag_g3sg1);
		WriteByte(MSG_ENTITY, self.ammo_g3sg1);
		WriteByte(MSG_ENTITY, self.mag_hlsmg);
		WriteByte(MSG_ENTITY, self.ammo_hlsmg);
		WriteByte(MSG_ENTITY, self.ammo_hlsmg_grenades);
		WriteByte(MSG_ENTITY, self.mag_hlrpg);
		WriteByte(MSG_ENTITY, self.ammo_hlrpg);
		WriteByte(MSG_ENTITY, self.ammo_hlgrenade);
		WriteByte(MSG_ENTITY, self.mag_hlglock);
		WriteByte(MSG_ENTITY, self.ammo_hlglock);
		WriteByte(MSG_ENTITY, self.ammo_hlegon);
		WriteByte(MSG_ENTITY, self.mag_csusp);
		WriteByte(MSG_ENTITY, self.ammo_csusp);
		WriteByte(MSG_ENTITY, self.csusp_silenced);
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
	WriteString(MSG_ENTITY, self.model);

	float mag = 0, ammo = 0, silencer = 0;
	float wep = self.weapon;
	     if (wep == WEP_AK47)            { mag = self.mag_ak47;            ammo = self.ammo_ak47;            }
	else if (wep == WEP_M4A1)            { mag = self.mag_m4a1;            ammo = self.ammo_m4a1;            silencer = self.m4a1_silenced; }
	else if (wep == WEP_CSAWP)           { mag = self.mag_awp;             ammo = self.ammo_awp;             }
	else if (wep == WEP_G3SG1)           { mag = self.mag_g3sg1;           ammo = self.ammo_g3sg1;           }
	else if (wep == WEP_CSM3)            { mag = self.mag_m3;              ammo = self.ammo_m3;              }
	else if (wep == WEP_CSMP5)           { mag = self.mag_mp5;             ammo = self.ammo_mp5;             }
	else if (wep == WEP_DOD98K)          { mag = self.mag_98k;             ammo = self.ammo_98k;             }
	else if (wep == WEP_FLAKSHOTGUN)     { mag = self.mag_flakshotgun;                                       }
	else if (wep == WEP_GAUSS)           {                                 ammo = self.ammo_gauss;           }
	else if (wep == WEP_GRENADELAUNCHER) { mag = self.mag_grenadelauncher;                                   }
	else if (wep == WEP_CROSSBOW)        { mag = self.mag_crossbow;        ammo = self.ammo_crossbow;        }
	else if (wep == WEP_HLEGON)          {                                 ammo = self.ammo_hlegon;          }
	else if (wep == WEP_HLRPG)           { mag = self.mag_hlrpg;           ammo = self.ammo_hlrpg;           }
	else if (wep == WEP_HLSHOTGUN)       { mag = self.mag_shotgun;         ammo = self.ammo_shotgun;         }
	else if (wep == WEP_HLSMG)           { mag = self.mag_hlsmg;           ammo = self.ammo_hlsmg;           }
	else if (wep == WEP_M249)            { mag = self.mag_m249;            ammo = self.ammo_m249;            }
	else if (wep == WEP_REBAR)           { mag = self.mag_rebar;                                             }
	else if (wep == WEP_SCOUT)           { mag = self.mag_scout;           ammo = self.ammo_scout;           }
	else if (wep == WEP_CSUSP)           { mag = self.mag_csusp;           ammo = self.ammo_csusp;           silencer = self.csusp_silenced; }
	else if (wep == WEP_DEAGLE)          { mag = self.mag_deagle;          ammo = self.ammo_deagle;          }
	else if (wep == WEP_GLOCK)           { mag = self.mag_glock;           ammo = self.ammo_glock;           }
	else if (wep == WEP_357)             { mag = self.mag_357;             ammo = self.ammo_357;             }
	else if (wep == WEP_HLGLOCK)         { mag = self.mag_hlglock;         ammo = self.ammo_hlglock;         }
	else if (wep == WEP_PISTOL)          { mag = self.mag_pistol;          ammo = self.ammo_pistol;          }
	else if (wep == WEP_HLGRENADE)       {                                 ammo = self.ammo_hlgrenade;       }
	// Melee (WRENCH/KNIFE/HLCROWBAR) — no ammo, leave both zero.

	WriteByte(MSG_ENTITY, mag);
	WriteByte(MSG_ENTITY, ammo);
	WriteByte(MSG_ENTITY, silencer ? 1 : 0);

	// Classic-Quake spin opt-in (per-weapon flag on the dropped entity).
	// CSQC derives rotation locally from cltime for spinning weapons.
	WriteByte(MSG_ENTITY, self.dropped_spin ? 1 : 0);

	// Settled angles from weapon_settle_think's floor-normal trace.  CSQC
	// ignores these when dropped_spin is set (spin derives yaw locally),
	// but for the common non-spin case they let the networked entity
	// inherit the same pitch/roll the fake drop settled to — otherwise
	// the real ent pops in at 0 0 0 and visually jumps off the slope.
	WriteCoord(MSG_ENTITY, self.angles_x);
	WriteCoord(MSG_ENTITY, self.angles_y);
	WriteCoord(MSG_ENTITY, self.angles_z);
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
	    proxy.pm_step_time        != player.pm_step_time)
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
	    proxy.zoomstage       != player.zoomstage)
		bits |= PM_SF_WEAPON_STATE;

	// Detect ammo changes
	if (proxy.mag_deagle         != player.mag_deagle ||
	    proxy.ammo_deagle        != player.ammo_deagle ||
	    proxy.mag_ak47           != player.mag_ak47 ||
	    proxy.ammo_ak47          != player.ammo_ak47 ||
	    proxy.mag_m4a1           != player.mag_m4a1 ||
	    proxy.ammo_m4a1          != player.ammo_m4a1 ||
	    proxy.m4a1_silenced      != player.m4a1_silenced ||
	    proxy.mag_flakshotgun    != player.mag_flakshotgun ||
	    proxy.mag_pistol         != player.mag_pistol ||
	    proxy.ammo_pistol        != player.ammo_pistol ||
	    proxy.mag_scout          != player.mag_scout ||
	    proxy.ammo_scout         != player.ammo_scout ||
	    proxy.mag_357            != player.mag_357 ||
	    proxy.ammo_357           != player.ammo_357 ||
	    proxy.mag_m249           != player.mag_m249 ||
	    proxy.ammo_m249          != player.ammo_m249 ||
	    proxy.mag_awp            != player.mag_awp ||
	    proxy.ammo_awp           != player.ammo_awp ||
	    proxy.mag_98k            != player.mag_98k ||
	    proxy.ammo_98k           != player.ammo_98k ||
	    proxy.mag_shotgun        != player.mag_shotgun ||
	    proxy.ammo_shotgun       != player.ammo_shotgun ||
	    proxy.mag_m3             != player.mag_m3 ||
	    proxy.ammo_m3            != player.ammo_m3 ||
	    proxy.mag_mp5            != player.mag_mp5 ||
	    proxy.ammo_mp5           != player.ammo_mp5 ||
	    proxy.mag_crossbow       != player.mag_crossbow ||
	    proxy.ammo_crossbow      != player.ammo_crossbow ||
	    proxy.mag_grenadelauncher != player.mag_grenadelauncher ||
	    proxy.mag_rebar          != player.mag_rebar ||
	    proxy.ammo_gauss         != player.ammo_gauss ||
	    proxy.mag_glock          != player.mag_glock ||
	    proxy.ammo_glock         != player.ammo_glock ||
	    proxy.mag_g3sg1          != player.mag_g3sg1 ||
	    proxy.ammo_g3sg1         != player.ammo_g3sg1 ||
	    proxy.mag_hlsmg          != player.mag_hlsmg ||
	    proxy.ammo_hlsmg         != player.ammo_hlsmg ||
	    proxy.ammo_hlsmg_grenades != player.ammo_hlsmg_grenades ||
	    proxy.mag_hlrpg          != player.mag_hlrpg ||
	    proxy.ammo_hlrpg         != player.ammo_hlrpg ||
	    proxy.ammo_hlgrenade     != player.ammo_hlgrenade ||
	    proxy.mag_hlglock        != player.mag_hlglock ||
	    proxy.ammo_hlglock       != player.ammo_hlglock ||
	    proxy.ammo_hlegon        != player.ammo_hlegon ||
	    proxy.mag_csusp          != player.mag_csusp ||
	    proxy.ammo_csusp         != player.ammo_csusp ||
	    proxy.csusp_silenced     != player.csusp_silenced)
		bits |= PM_SF_AMMO;

	// Copy player → proxy cache (so next call compares against this snapshot)
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
	proxy.mag_hlglock     = player.mag_hlglock;
	proxy.ammo_hlglock    = player.ammo_hlglock;
	proxy.ammo_hlegon     = player.ammo_hlegon;
	proxy.mag_csusp       = player.mag_csusp;
	proxy.ammo_csusp      = player.ammo_csusp;
	proxy.csusp_silenced  = player.csusp_silenced;

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
	if (was_new)
		proxy.SendFlags = proxy.SendFlags | PM_SF_MOVEMENT | PM_SF_WEAPON_STATE | PM_SF_AMMO;
};

// ------------------------------------------------------------
//  W_GiveStartingAmmo
//    Reads self.slot_primary / slot_secondary / slot_melee / slot_utility
//    (already populated from sv_default_* cvars) and sets the matching
//    slot_X_equip / slot_X_drop function pointers plus starting mag + reserve
//    ammo for the chosen weapon in each slot.  All known mag/ammo fields are
//    zeroed first so nothing bleeds over from a previous inventory.
// ------------------------------------------------------------
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
	self.mag_csusp = 0;            self.ammo_csusp = 0;
	self.mag_deagle = 0;           self.ammo_deagle = 0;
	self.mag_glock = 0;            self.ammo_glock = 0;
	self.mag_357 = 0;              self.ammo_357 = 0;
	self.mag_hlglock = 0;          self.ammo_hlglock = 0;
	self.mag_pistol = 0;           self.ammo_pistol = 0;
	self.ammo_hlgrenade = 0;

	// Primary slot
	self.slot_primary_equip = __NULL__;
	self.slot_primary_drop  = __NULL__;
	switch (self.slot_primary)
	{
	case WEP_AK47:
		self.slot_primary_equip = W_AK47Equip;
		self.slot_primary_drop  = W_AK47Drop;
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
	default:
		self.slot_primary = WEP_NONE;
		break;
	}

	// Secondary slot
	self.slot_secondary_equip = __NULL__;
	self.slot_secondary_drop  = __NULL__;
	switch (self.slot_secondary)
	{
	case WEP_CSUSP:
		self.slot_secondary_equip = W_CSUSPEquip;
		self.slot_secondary_drop  = W_CSUSPDrop;
		self.mag_csusp = MAX_MAG_CSUSP;   self.ammo_csusp = MAX_AMMO_CSUSP;
		break;
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
	default:
		self.slot_secondary = WEP_NONE;
		break;
	}

	// Melee slot
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
	default:
		self.slot_melee = WEP_NONE;
		break;
	}

	// Utility slot
	self.slot_utility_equip = __NULL__;
	self.slot_utility_drop  = __NULL__;
	switch (self.slot_utility)
	{
	case WEP_HLGRENADE:
		self.slot_utility_equip = W_HLGrenadeEquip;
		self.slot_utility_drop  = W_HLGrenadeDrop;
		self.ammo_hlgrenade = MAX_AMMO_HLGRENADE;
		break;
	default:
		self.slot_utility = WEP_NONE;
		break;
	}
};

void() PlayerSpawn =
{
	self.classname = "player";
	self.solid = SOLID_SLIDEBOX;

	// Reserve dimension bit 2 for physics props (sv_physprop.qc). Player pmove
	// and tracelines must not see that bit, otherwise passthrough filter fails.
	self.dimension_hit = self.dimension_hit & ~2;
	self.dimension_solid = self.dimension_solid & ~2;

	// Noblock: give each player a unique dimension_solid bit so they pass
	// through each other but still collide with world geometry (dim_solid=255).
	// Bit value 2 is reserved for physics props — excluded from the table.
	//
	// LIMIT: FTE's default world bitmask is 8 bits (dimension_default=255),
	// minus bit 2 for props = 7 unique slots. Player 8+ can't get a unique
	// bit without bumping world.dimension_solid to a wider mask AND
	// refactoring every hitscan trace to save/restore dimension_hit. Until
	// that refactor happens we cap noblock at 7 players: the 8th+ falls
	// through to normal SOLID_SLIDEBOX collision (can push teammates) and
	// logs once so the operator knows to either cap the server or take the
	// bigger refactor.
	if (cvar("mp_noblock"))
	{
		float pnum = num_for_edict(self) - 1;
		float noblock_bits[7] = {1, 4, 8, 16, 32, 64, 128};
		if (pnum < 7)
		{
			self.dimension_solid = noblock_bits[pnum];
			self.dimension_hit = 253; // 255 & ~2, can trace-hit all players
		}
		else
		{
			bprint(PRINT_HIGH, sprintf("^1[noblock]^7 player slot %g exceeds 7-slot limit — collides normally.\n", pnum + 1));
		}
	}

	PM_ReadMovevars();
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
	self.flags           = self.flags & ~FL_DUCKING;
	self.wep_action_id   = 0;
	self.gauss_charge_state = 0;
	self.gauss_charge_started = 0;
	self.gauss_charge_next_ammo = 0;
	self.glock_burst_count = 0;

	// Give starting weapons.
	//  - If survived_round is set, the player was alive when the round ended:
	//    keep their slot_* and mag_*/ammo_* fields from the previous life.
	//  - Otherwise, apply the server-configured default loadout from the
	//    sv_default_* cvars and (re)populate starting ammo.
	if (self.survived_round)
	{
		// Keep existing inventory.  Nothing to do.
	}
	else
	{
		self.slot_primary   = cvar("sv_default_primary");
		self.slot_secondary = cvar("sv_default_secondary");
		self.slot_melee     = cvar("sv_default_melee");
		self.slot_utility   = cvar("sv_default_utility");
		W_GiveStartingAmmo();
	}
	self.survived_round = 0;  // consume the flag so it doesn't leak to future spawns

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

		// Spawn weapons in a grid: 6 columns wide, 48 units apart
		// Row spacing = 64 forward, Column spacing = 48 right
		float col, row;
		vector base = saved_self.origin;

		// Row 1
		col = 0; row = 0;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_ak47();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_m4a1();         col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_csawp();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_scout();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_g3sg1();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_m249();

		// Row 2
		col = 0; row = 1;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_csmp5();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_dod98k();       col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_crossbow();     col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_grenadelauncher(); col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_rebar();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_gauss();

		// Row 3: shotguns + flak + HL new primaries
		col = 0; row = 2;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlshotgun();    col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_csm3();         col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_flakshotgun();  col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlsmg();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlrpg();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlegon();

		// Row 4: grenade
		col = 0; row = 3;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlgrenade();

		// Row 5: secondaries + melee
		col = 0; row = 4;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_pistol();       col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_deagle();       col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_357();          col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_glock();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_csusp();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlglock();      col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlcrowbar();    col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_wrench();

		self = saved_self;
		sv_debug_weapon_spawning = FALSE;
	}
};

void() PutClientInServer =
{
	// Assign a unique dimension bit so we can exclude individual players
	// from multicasts (e.g. shooter doesn't get their own impact effects).
	// dimension_see = 255 means the player receives all dimensions.
	// dimension_seen = unique bit means multicasts can exclude just this player.
	float slot = num_for_edict(self) - 1;  // 0-based player slot
	self.dimension_seen = 255;
	self.dimension_see  = 255;

	player_chain_add(self);
	PlayerBeginTeamSelection();
};

void() ClientDisconnect =
{
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
	// if (elapsedtime > 2) setpause(0);
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
	float mode = cvar("sv_trust_clienthits");
	if (mode < 1) return 0;

	// self is the attacker (engine-set before SV_ParseClientCommand).
	if (!self || self.classname != "player") return 0;
	if (self.is_dead) return 0;
	if (self.player_team <= TEAM_NONE) return 0;

	float target_slot = stof(argv(1));
	float body_damage = stof(argv(2));
	float bone_id     = stof(argv(3));

	if (target_slot <= 0 || target_slot > 32) return 0;
	if (body_damage <= 0) return 0;

	entity target = edict_num(target_slot);
	if (!target || target == world) return 0;
	if (target.classname != "player") return 0;
	if (target.is_dead) return 0;
	if (target == self) return 0;

	// Look up hitgroup from the bone_id. W_BoneToHitgroup reads the
	// global `trace_ent` to resolve bone names; we haven't done a trace
	// in this handler, so point it at the target entity around the call.
	float hitgroup = HITGROUP_GENERIC;
	if (bone_id > 0)
	{
		entity saved_te = trace_ent;
		trace_ent = target;
		hitgroup = W_BoneToHitgroup(bone_id);
		trace_ent = saved_te;
	}
	float damage = body_damage * W_HitgroupDamageMultiplier(hitgroup);

	// Soft-trust sanity: cap BODY damage, enforce friendly-fire, PVS
	// check. Headshot multiplier is applied AFTER the cap so a legit
	// ~50-body headshot can still land 200 final, but a manufactured
	// body=999 claim gets clipped before the multiplier.
	if (mode == 1)
	{
		if (body_damage > 200) damage = 200 * W_HitgroupDamageMultiplier(hitgroup);

		if (self.player_team == target.player_team
		    && self.player_team != TEAM_NONE
		    && !cvar("mp_friendlyfire"))
			return 0;

		if (!checkpvs(self.origin + self.view_ofs, target))
			return 0;
	}

	// Dedup: if the server's own trace already hit this target within
	// the last 100 ms, the client's claim is a duplicate — skip.
	if (self.last_damaged_target == target
	    && (time - self.last_damaged_time) < 0.1)
		return 0;

	float applied = W_ApplyDamage(self, target, damage);

	if (cvar("sv_debug_clienthits"))
	{
		dprint(sprintf("[hitclaim] %s -> slot %g body=%.0f bone=%g\n",
			self.netname, target_slot, body_damage, bone_id));
		dprint(sprintf("[hitclaim]   hg=%g dmg=%.0f applied=%.0f mode=%g\n",
			hitgroup, damage, applied, mode));
	}

	return applied;
};

void(string command_string) SV_ParseClientCommand =
{
	tokenize(command_string);
	string cmd = argv(0);

	if (cmd == "hitclaim")
	{
		SV_HandleHitclaim(command_string);
		return;
	}

	if (PlayerHandleTeamCommand(cmd))
		return;

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
	PM_PlayerMove();
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
