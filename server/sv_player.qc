
//
//	Player.qc - Various stuff done for the player, including per-frame functions like PlayerPreThink and PlayerPostThink, also client specific stuff like PutClientInServer etc.
//

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
	default: break;
	}
	self.impulse = 0;
};

vector() get_spawn_point =
{
	entity spawnpoint = world;
	spawnpoint = find(spawnpoint, classname, "info_player_start");

	return spawnpoint.origin + '0 0 1';
};

void() PlayerPreThink =
{	
	CheckImpulses();
	makevectors(self.v_angle);
	if(self.button0)
	{
		
	}
	if(self.button2)
	{
		PlayerJump();
	}
	else
	{
		self.flags = self.flags | FL_JUMPRELEASED;
	}
};

void() PlayerPostThink =
{
};

void() ClientKill =
{
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
	WriteFloat(MSG_ENTITY, self.pm_step_time);

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
	proxy.pm_step_time            = player.pm_step_time;
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
	setorigin(self, get_spawn_point());
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

	PM_EnsurePredictionProxy(self);
	PM_SyncPredictionProxy(self);
};

void() PutClientInServer =
{
	player_chain_add(self);
	PlayerSpawn();
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
	switch (cmd)
	{
	default: break;
	}
	clientcommand(self, command_string);
};


void() SV_RunClientCommand =
{
	PM_PlayerMove();
	SV_CheckTouchTriggers();

	// If a teleport angle snap fired this command, send an engine-level
	// fixangle so the client's view accumulator is updated persistently.
	PM_SyncPredictionProxy(self);
};
