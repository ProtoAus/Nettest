//
// sv_env_hud.qc — HL env_fade / env_message point entities
//
// Server entities only dispatch compact CSQC events.  The client owns
// the actual full-screen fade and titles.txt rendering.
//

void(entity caller, entity who, float useType) SUB_UseTargets;        // sv_triggers.qc

const float ENV_FADE_FROM           = 1;
const float ENV_FADE_MODULATE       = 2;
const float ENV_FADE_ACTIVATOR_ONLY = 4;

const float ENV_MESSAGE_PLAY_ONCE   = 1;
const float ENV_MESSAGE_ALL_CLIENTS = 2;
const float ENVHUD_EVENT_FADE       = 1;
const float ENVHUD_EVENT_MESSAGE    = 2;
const float ENVHUD_SERVER_PENDING_MAX = 32;

.float  duration;
.float  holdtime;
.string messagesound;
.float  messagevolume;
.float  messageattenuation;
.float  env_once_fired;
.float  envhud_startup_replayed;
.float  envhud_kind;
.vector envhud_colour;
.float  envhud_alpha;
.float  envhud_duration;
.float  envhud_hold;
.float  envhud_flags;
.string envhud_message;

float  envhud_sv_pending_count;
float  envhud_sv_pending_base_time;
float  envhud_sv_pending_kind[32];
float  envhud_sv_pending_delay[32];
vector envhud_sv_pending_colour[32];
float  envhud_sv_pending_alpha[32];
float  envhud_sv_pending_duration[32];
float  envhud_sv_pending_hold[32];
float  envhud_sv_pending_flags[32];
string envhud_sv_pending_message[32];

void() EnvHud_ClearStartupPending =
{
    float i;
    for (i = 0; i < ENVHUD_SERVER_PENDING_MAX; i = i + 1)
    {
        if (envhud_sv_pending_message[i] != "")
            strunzone(envhud_sv_pending_message[i]);
        envhud_sv_pending_message[i] = "";
        envhud_sv_pending_kind[i] = 0;
    }
    envhud_sv_pending_count = 0;
    envhud_sv_pending_base_time = 0;
};

entity() EnvHud_FirstPlayer =
{
    entity p = find(world, classname, "player");
    return p;
};

float(entity p, vector col, float alpha, float duration_s, float hold_s, float flags) EnvFade_SendOne =
{
    if (!p || p.classname != "player" || bot_adding || clienttype(p) != CLIENTTYPE_REAL)   // skip bots (engine-truth guard; bot_adding = spawn window)
        return FALSE;

    msg_entity = p;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_ENV_FADE);
    WriteByte(MSG_ONE, bound(0, rint(col_x), 255));
    WriteByte(MSG_ONE, bound(0, rint(col_y), 255));
    WriteByte(MSG_ONE, bound(0, rint(col_z), 255));
    WriteByte(MSG_ONE, bound(0, rint(alpha), 255));
    WriteFloat(MSG_ONE, duration_s);
    WriteFloat(MSG_ONE, hold_s);
    WriteByte(MSG_ONE, flags);
    return TRUE;
};

float(string msg, entity p) EnvMessage_SendOne =
{
    if (!p || p.classname != "player" || bot_adding || clienttype(p) != CLIENTTYPE_REAL)   // skip bots (engine-truth guard; bot_adding = spawn window)
        return FALSE;

    msg_entity = p;
    WriteByte(MSG_ONE, SVC_CGAMEPACKET);
    WriteByte(MSG_ONE, CSQC_EVENT_ENV_MESSAGE);
    WriteString(MSG_ONE, msg);
    return TRUE;
};

float(vector col, float alpha, float duration_s, float hold_s, float flags) EnvFade_SendAll =
{
    float sent = 0;
    entity p = find(world, classname, "player");
    while (p)
    {
        if (EnvFade_SendOne(p, col, alpha, duration_s, hold_s, flags))
            sent = sent + 1;
        p = find(p, classname, "player");
    }
    return sent;
};

float(string msg) EnvMessage_SendAll =
{
    float sent = 0;
    entity p = find(world, classname, "player");
    while (p)
    {
        if (EnvMessage_SendOne(msg, p))
            sent = sent + 1;
        p = find(p, classname, "player");
    }
    return sent;
};

float() EnvHud_QueueSlot =
{
    if (envhud_sv_pending_count >= ENVHUD_SERVER_PENDING_MAX)
    {
        if (cvar("sv_debug_use"))
            print("[envhud sv] startup pending queue full; dropping event\n");
        return -1;
    }

    if (envhud_sv_pending_count <= 0)
        envhud_sv_pending_base_time = time;

    float slot = envhud_sv_pending_count;
    envhud_sv_pending_count = envhud_sv_pending_count + 1;
    envhud_sv_pending_delay[slot] = time - envhud_sv_pending_base_time;
    if (envhud_sv_pending_delay[slot] < 0)
        envhud_sv_pending_delay[slot] = 0;
    return slot;
};

void(vector col, float alpha, float duration_s, float hold_s, float flags) EnvHud_QueueFade =
{
    float slot = EnvHud_QueueSlot();
    if (slot < 0)
        return;

    envhud_sv_pending_kind[slot]     = ENVHUD_EVENT_FADE;
    envhud_sv_pending_colour[slot]   = col;
    envhud_sv_pending_alpha[slot]    = alpha;
    envhud_sv_pending_duration[slot] = duration_s;
    envhud_sv_pending_hold[slot]     = hold_s;
    envhud_sv_pending_flags[slot]    = flags;

    if (cvar("sv_debug_use"))
        print(sprintf("[envhud sv] queued startup fade delay=%.2f\n",
                      envhud_sv_pending_delay[slot]));
};

void(string msg) EnvHud_QueueMessage =
{
    float slot = EnvHud_QueueSlot();
    if (slot < 0)
        return;

    envhud_sv_pending_kind[slot] = ENVHUD_EVENT_MESSAGE;
    envhud_sv_pending_message[slot] = strzone(msg);

    if (cvar("sv_debug_use"))
        print(sprintf("[envhud sv] queued startup message '%s' delay=%.2f\n",
                      msg, envhud_sv_pending_delay[slot]));
};

void() EnvHud_DelayedSendThink =
{
    entity p = self.owner;
    if (p && p.classname == "player")
    {
        if (self.envhud_kind == ENVHUD_EVENT_FADE)
        {
            EnvFade_SendOne(p,
                            self.envhud_colour,
                            self.envhud_alpha,
                            self.envhud_duration,
                            self.envhud_hold,
                            self.envhud_flags);
        }
        else if (self.envhud_kind == ENVHUD_EVENT_MESSAGE)
        {
            EnvMessage_SendOne(self.envhud_message, p);
        }
    }

    if (self.envhud_message != "")
        strunzone(self.envhud_message);
    remove(self);
};

void(entity p, float slot) EnvHud_SchedulePendingForPlayer =
{
    entity e = spawn();
    e.classname = "env_hud_delayed";
    e.owner = p;
    e.envhud_kind     = envhud_sv_pending_kind[slot];
    e.envhud_colour   = envhud_sv_pending_colour[slot];
    e.envhud_alpha    = envhud_sv_pending_alpha[slot];
    e.envhud_duration = envhud_sv_pending_duration[slot];
    e.envhud_hold     = envhud_sv_pending_hold[slot];
    e.envhud_flags    = envhud_sv_pending_flags[slot];
    if (envhud_sv_pending_message[slot] != "")
        e.envhud_message = strzone(envhud_sv_pending_message[slot]);
    e.think = EnvHud_DelayedSendThink;
    e.nextthink = time + 0.1 + envhud_sv_pending_delay[slot];
};

void(entity p) EnvHud_ReplayPendingForPlayer =
{
    if (!p || p.classname != "player")
        return;
    if (p.envhud_startup_replayed)
        return;
    if (envhud_sv_pending_count <= 0)
        return;

    p.envhud_startup_replayed = TRUE;

    float i;
    for (i = 0; i < envhud_sv_pending_count; i = i + 1)
        EnvHud_SchedulePendingForPlayer(p, i);

    if (cvar("sv_debug_use"))
        print(sprintf("[envhud sv] scheduled %g startup HUD event(s) for %s\n",
                      envhud_sv_pending_count, p.netname));
};

void() env_fade_use =
{
    float duration_s = bound(0, self.duration, 16);
    if (duration_s <= 0)
        return;

    float hold_s = bound(0, self.holdtime, 16);
    float alpha = self.renderamt;
    if (alpha <= 0)
        alpha = 255;

    vector col = self.rendercolor;
    float flags = self.spawnflags & (ENV_FADE_FROM | ENV_FADE_MODULATE);

    if (self.spawnflags & ENV_FADE_ACTIVATOR_ONLY)
    {
        entity p = activator;
        if (!p || p.classname != "player")
            p = EnvHud_FirstPlayer();
        if (!EnvFade_SendOne(p, col, alpha, duration_s, hold_s, flags))
            EnvHud_QueueFade(col, alpha, duration_s, hold_s, flags);
    }
    else
    {
        if (EnvFade_SendAll(col, alpha, duration_s, hold_s, flags) <= 0)
            EnvHud_QueueFade(col, alpha, duration_s, hold_s, flags);
    }
};

float() EnvMessage_Attenuation =
{
    if (self.messageattenuation == 3) return ATTN_NONE;
    if (self.messageattenuation == 2) return 0.6;
    if (self.messageattenuation == 1) return 1.25;
    return 2.0;
};

void() EnvMessage_PlaySound =
{
    if (self.messagesound == "")
        return;

    float vol = self.messagevolume;
    if (vol <= 0)
        vol = 10;
    sound(self, CHAN_VOICE, self.messagesound, bound(0, vol / 10, 1), EnvMessage_Attenuation());
};

void() env_message_use =
{
    if ((self.spawnflags & ENV_MESSAGE_PLAY_ONCE) && self.env_once_fired)
        return;
    self.env_once_fired = 1;

    string msg = self.message;
    if (msg == "")
        msg = self.targetname;

    if (self.spawnflags & ENV_MESSAGE_ALL_CLIENTS)
    {
        if (EnvMessage_SendAll(msg) <= 0)
            EnvHud_QueueMessage(msg);
    }
    else
    {
        entity p = activator;
        if (!p || p.classname != "player")
            p = EnvHud_FirstPlayer();
        if (!EnvMessage_SendOne(msg, p))
            EnvHud_QueueMessage(msg);
    }

    EnvMessage_PlaySound();

    if (self.target != "")
        SUB_UseTargets(self, activator, USE_TOGGLE);
};

/*QUAKED env_fade (.5 .5 .5) (-8 -8 -8) (8 8 8) FADE_FROM MODULATE ACTIVATOR_ONLY
HL-style screen fade.

"duration"    seconds to fade (0 = no-op, clamped to 16)
"holdtime"    seconds to hold at full alpha (clamped to 16)
"renderamt"   alpha 0..255
"rendercolor" RGB 0..255
*/
void() env_fade =
{
    if (self.renderamt <= 0)
        self.renderamt = 255;
    self.use = env_fade_use;
};

/*QUAKED env_message (.5 .5 .5) (-8 -8 -8) (8 8 8) PLAY_ONCE ALL_CLIENTS
HL-style titles.txt message trigger.

"message"            title key in titles.txt, or literal text fallback
"messagesound"       sound path relative to sound/
"messagevolume"      0..10, default 10
"messageattenuation" 0 small, 1 medium, 2 large, 3 everywhere
*/
void() env_message =
{
    if (self.messagesound != "")
        precache_sound(self.messagesound);
    self.use = env_message_use;
};
