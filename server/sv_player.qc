
//
//	Player.qc - Various stuff done for the player, including per-frame functions like PlayerPreThink and PlayerPostThink, also client specific stuff like PutClientInServer etc.
//

void(entity player) PM_SyncPredictionProxy;

// =============================================
//  Team System
// =============================================

entity(string spawn_classname) PlayerFindSpawnByClassname =
{
    entity spot;
    entity choice;
    float count;

    spot = world;
    choice = world;
    count = 0;
    while (TRUE)
    {
        spot = find(spot, classname, spawn_classname);
        if (!spot)
            break;

        count = count + 1;
        if (random() < (1 / count))
            choice = spot;
    }

    return choice;
};

entity() PlayerGetSpawnPointEntity =
{
    entity spawnpoint;

    spawnpoint = world;

    if (self.player_team == TEAM_BLUE)
    {
        spawnpoint = PlayerFindSpawnByClassname("info_player_blue");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_start_blue");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_team1");
    }
    else if (self.player_team == TEAM_RED)
    {
        spawnpoint = PlayerFindSpawnByClassname("info_player_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_start_red");
        if (!spawnpoint)
            spawnpoint = PlayerFindSpawnByClassname("info_player_team2");
    }

    if (!spawnpoint)
        spawnpoint = PlayerFindSpawnByClassname("info_player_start");

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
    self.team_menu_request_serial = 0;
    self.velocity = '0 0 0';
    self.fixangle = TRUE;
    PlayerPlaceAtSpawnPoint();
    PlayerRefreshScoreboardInfo(self);
};

void() PlayerSpawn;

void(float new_team) PlayerJoinTeam =
{
    if (new_team != TEAM_BLUE && new_team != TEAM_RED)
        return;

    if (self.player_team == new_team && !PlayerNeedsTeamSelection())
        return;

    if (!PlayerNeedsTeamSelection() && self.player_team != new_team)
        self.deaths = self.deaths + 1;

    self.player_team = new_team;
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

float(string cmd) PlayerHandleTeamCommand =
{
    string team_name;
    float new_team;

    if (cmd != "jointeam" && cmd != "team")
        return FALSE;

    team_name = argv(1);
    new_team = TEAM_NONE;

    if (team_name == "blue")
        new_team = TEAM_BLUE;
    else if (team_name == "red")
        new_team = TEAM_RED;

    if (new_team != TEAM_NONE)
        PlayerJoinTeam(new_team);

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
		else
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
            self.dmg_take = damage;
            self.dmg_inflictor = self;

            if (self.health <= 0)
            {
                sound(self, CHAN_VOICE, "sounds/player/fallpain2.wav", 1, ATTN_NORM);
                bprint(PRINT_HIGH, self.netname);
                bprint(PRINT_HIGH, " fell to their death\n");
                self.deaths = self.deaths + 1;
                self.frags = self.frags - 1;
                PlayerRefreshScoreboardInfo(self);

                // Deferred death — handled by StartFrame after mp_deathdelay
                self.is_dead = TRUE;
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

void() PlayerPostThink =
{
    if (PlayerNeedsTeamSelection())
        return;

    PlayerCheckFallDamage();
};

void() ClientKill =
{
	if (PlayerNeedsTeamSelection())
		return;

	self.frags = self.frags - 1;
	self.deaths = self.deaths + 1;
	PlayerRefreshScoreboardInfo(self);
	bprint(PRINT_HIGH, self.netname);
	bprint(PRINT_HIGH, " suicides\n");

	// Deferred death — handled by StartFrame after mp_deathdelay
	self.is_dead = TRUE;
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

float(entity playerent, float changedflags) PM_PredictionProxy_SendEntity =
{
	if (playerent != self.drawonlytoclient)
		return FALSE;

	WriteByte(MSG_ENTITY, PM_CSQC_PROXY_VERSION);

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

	// Weapon state  (for client-side fire prediction)
	// wep_anim_start is sent as elapsed seconds since animation began so
	// the client can reconstruct the absolute cltime on its end.
	WriteFloat(MSG_ENTITY, self.slot_primary);
	WriteFloat(MSG_ENTITY, self.slot_secondary);
	WriteFloat(MSG_ENTITY, self.slot_melee);
	WriteFloat(MSG_ENTITY, self.weapon);
	WriteFloat(MSG_ENTITY, self.previous_weapon);
	WriteFloat(MSG_ENTITY, self.weaponstate);
	WriteFloat(MSG_ENTITY, self.wep_action_id);
	WriteFloat(MSG_ENTITY, max(0, self.attack_finished - time));
	WriteFloat(MSG_ENTITY, (self.wep_anim_start > 0) ? max(0, time - self.wep_anim_start) : 0);
	WriteFloat(MSG_ENTITY, self.mag_deagle);
	WriteFloat(MSG_ENTITY, self.ammo_deagle);
	WriteFloat(MSG_ENTITY, self.mag_ak47);
	WriteFloat(MSG_ENTITY, self.ammo_ak47);
	WriteFloat(MSG_ENTITY, self.mag_m4a1);
	WriteFloat(MSG_ENTITY, self.ammo_m4a1);
	WriteFloat(MSG_ENTITY, self.m4a1_silenced);
	WriteFloat(MSG_ENTITY, self.mag_flakshotgun);
	WriteFloat(MSG_ENTITY, self.mag_pistol);
	WriteFloat(MSG_ENTITY, self.ammo_pistol);
	WriteFloat(MSG_ENTITY, self.mag_scout);
	WriteFloat(MSG_ENTITY, self.ammo_scout);
	WriteFloat(MSG_ENTITY, self.mag_357);
	WriteFloat(MSG_ENTITY, self.ammo_357);
	WriteFloat(MSG_ENTITY, self.mag_m249);
	WriteFloat(MSG_ENTITY, self.ammo_m249);
	WriteFloat(MSG_ENTITY, self.zoomstage);
	WriteFloat(MSG_ENTITY, self.mag_awp);
	WriteFloat(MSG_ENTITY, self.ammo_awp);
	WriteFloat(MSG_ENTITY, self.mag_98k);
	WriteFloat(MSG_ENTITY, self.ammo_98k);
	WriteFloat(MSG_ENTITY, self.mag_shotgun);
	WriteFloat(MSG_ENTITY, self.ammo_shotgun);
	WriteFloat(MSG_ENTITY, self.mag_m3);
	WriteFloat(MSG_ENTITY, self.ammo_m3);
	WriteFloat(MSG_ENTITY, self.mag_mp5);
	WriteFloat(MSG_ENTITY, self.ammo_mp5);
	WriteFloat(MSG_ENTITY, self.mag_crossbow);
	WriteFloat(MSG_ENTITY, self.ammo_crossbow);
	WriteFloat(MSG_ENTITY, self.mag_grenadelauncher);
	WriteFloat(MSG_ENTITY, self.mag_rebar);
	WriteFloat(MSG_ENTITY, self.ammo_gauss);
	WriteFloat(MSG_ENTITY, self.mag_glock);
	WriteFloat(MSG_ENTITY, self.ammo_glock);
	WriteFloat(MSG_ENTITY, self.mag_g3sg1);
	WriteFloat(MSG_ENTITY, self.ammo_g3sg1);

	return TRUE;
};

void(entity player) PM_SyncPredictionProxy =
{
	entity proxy;

	proxy = player.pm_prediction_proxy;
	if (!proxy)
		return;

	proxy.owner = player;
	proxy.drawonlytoclient = player;
	setorigin(proxy, player.origin);
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

	// Weapon state
	proxy.slot_primary     = player.slot_primary;
	proxy.slot_secondary   = player.slot_secondary;
	proxy.slot_melee       = player.slot_melee;
	proxy.weapon          = player.weapon;
	proxy.previous_weapon = player.previous_weapon;
	proxy.weaponstate     = player.weaponstate;
	proxy.wep_action_id   = player.wep_action_id;
	proxy.attack_finished = player.attack_finished;
	proxy.wep_anim_start  = player.wep_anim_start;
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
	proxy.zoomstage       = player.zoomstage;
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

	proxy.SendFlags = proxy.SendFlags | PM_CSQC_PROXY_SEND_STATE;
};

void(entity player) PM_EnsurePredictionProxy =
{
	entity proxy;

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
	}

	proxy.owner = player;
	proxy.drawonlytoclient = player;
	PM_SyncPredictionProxy(player);
};

void() PlayerSpawn =
{
	PM_ReadMovevars();  // ensure hull constants reflect pm_hull_height before setsize
	self.classname = "player";
	self.solid = SOLID_SLIDEBOX;
	setmodel(self, "models/testplayer.iqm");
	self.movetype = MOVETYPE_NONE;  // engine physics off; we run our own
	self.health = 100;
	PlayerPlaceAtSpawnPoint();
	PlayerApplyTeamColours();
	self.fixangle = TRUE;
	setsize(self, PM_MINS, PM_MAXS);
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

	// Give starting weapons
	self.slot_primary         = WEP_M4A1;
	self.slot_primary_equip   = W_M4A1Equip;
	self.slot_primary_drop    = W_M4A1Drop;
	self.mag_m4a1             = MAX_MAG_M4A1;
	self.ammo_m4a1            = MAX_AMMO_M4A1;

	self.slot_secondary       = WEP_DEAGLE;
	self.slot_secondary_equip = W_DeagleEquip;
	self.slot_secondary_drop  = W_DeagleDrop;
	self.mag_deagle           = MAX_MAG_DEAGLE;
	self.ammo_deagle          = MAX_AMMO_DEAGLE;

	self.slot_melee           = WEP_KNIFE;
	self.slot_melee_equip     = W_KnifeEquip;
	self.slot_melee_drop      = W_KnifeDrop;

	W_SelectWeapon(WEP_M4A1);

	PM_EnsurePredictionProxy(self);
	PM_SyncPredictionProxy(self);

	// Debug: spawn pickup weapons in front of the player
	{
		entity saved_self = self;
		makevectors(self.angles);

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

		// Row 3: shotguns + flak
		col = 0; row = 2;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlshotgun();    col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_csm3();         col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_flakshotgun();

		// Row 4: secondaries + melee
		col = 0; row = 3;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_pistol();       col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_deagle();       col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_357();          col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_glock();        col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_hlcrowbar();    col++;
		self = spawn(); setorigin(self, base + v_forward * (64 + row * 64) + v_right * ((col - 2.5) * 48)); weapon_wrench();

		self = saved_self;
	}
};

void() PutClientInServer =
{
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

void(string command_string) SV_ParseClientCommand =
{
	tokenize(command_string);
	string cmd = argv(0);

	if (PlayerHandleTeamCommand(cmd))
		return;

	clientcommand(self, command_string);
};


void() SV_RunClientCommand =
{
	// Dead players: zero all input
	if (self.is_dead)
	{
		input_movevalues = '0 0 0';
		input_buttons = 0;
	}
	// Freeze time: block WASD movement and primary attack
	else if (round_phase == ROUND_PHASE_FREEZE)
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
};
