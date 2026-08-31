// server/sv_ai_defs.qc
// ----------------------------------------------------------------------------
// Monster AI substrate: activity ids, condition bits, states, per-entity fields.
//
// Constants only — no code, no arrays that anything else needs to reach through
// a forward declaration.  This file compiles FIRST of the AI set so every other
// AI file can use the names without ordering games.
//
// The engine defines NO ACT_* or EVENT_* constants at all: getmodeleventidx and
// frameforaction are raw passthrough, so the meaning of every number below is
// owned here.  The values are Half-Life's, and the ones this mod actually uses
// were read back out of the shipped models rather than copied from memory:
//
// The tables below were re-read directly from the .mdl files with a struct
// reader, not from the engine, after the engine probe disagreed with an earlier
// hand-transcription.  The models do NOT live in the FTE tree: FTE mounts the
// Steam Half-Life install (the search path shows "steam:Half-Life/valve"), so
// they are under Steam\steamapps\common\Half-Life\valve\models.  Anyone trying
// to verify these numbers by searching C:\FTEQuake will find nothing.
//
//   models/headcrab.mdl (21 sequences, 0 bone controllers):
//     act  1  idle1(w15,loop) / idle2(w1) / idle3(w1)  -> ACT_IDLE
//     act  3  walk        35f @30, loop                -> ACT_WALK
//     act  4  run         29f @30, loop                -> ACT_RUN
//     act 15  180_left    23f @15, loop                -> ACT_TURN_LEFT
//     act 16  180_right   23f @15, loop                -> ACT_TURN_RIGHT
//     act 26  flinch      19f @30, one-shot            -> ACT_SMALL_FLINCH
//     act 28  jump(w2) / jump_variation1(w1) / jump_variation2(w1)
//             31f @30, one-shot, ONE event each: t=0.000s code=2
//                                                      -> ACT_RANGE_ATTACK1
//     act 31  yaw_adjustment  21f @30, loop            -> ACT_MELEE_ATTACK2 (!)
//     act 36  dieback     51f @30, one-shot            -> ACT_DIESIMPLE
//
// Two things there are traps rather than trivia:
//
//   The headcrab's attack is RANGE_ATTACK1, not a melee activity — it is a leap,
//   and its launch is an ANIM EVENT (code 2) on frame 0 of every jump variant,
//   not something the schedule fires directly.  The schedule starts the
//   animation; the animation decides when the crab actually leaves the ground.
//
//   Valve tagged "yaw_adjustment" — a looping in-place turn — with activity 31,
//   which in HL's own activity.h is ACT_MELEE_ATTACK2.  Ask this model for a
//   melee attack and it will placidly turn on the spot.  mon_headcrab.qc leaves
//   ai_melee_range at 0 so COND_CAN_MELEE1 can never be set for the class, which
//   is what keeps the mis-tag unreachable.
//
//   models/zombie.mdl (44 sequences), same treatment:
//     act  1  idle1                     31f @15, loop
//     act  3  walk                      60f @22, loop, SIX code-2003 footsteps
//     act  9  falling                   21f @26, loop
//     act 15/16  turnleft / turnright
//     act 26  flinchsmall(w5) / flinch(w1)
//     act 27  bigflinch
//     act 30  attack1(w5) 36f @15: code 1 @0.667s, code 2 @1.267s
//             attack2(w1) 21f @15: code 3 @0.400s
//     act 36  diesimple    + 37/38 die backward/forward, 66/68 headshot/gutshot
//     act 73..76  per-limb flinches
//
//   THERE IS NO ACT_RUN.  A zombie has one gait, so ai_speed_run must equal
//   ai_speed_walk or it skates: AI_ActivityFallback resolves ACT_RUN to ACT_WALK
//   and the walk cycle would be played at running pace.
//
//   The walk cycle's six events are code 1004 = EVENT_SOUND, and each one names
//   a real file in its options string: common/npc_step1.wav, npc_step3, npc_step2,
//   npc_step4, npc_step1, npc_step3.  An earlier version of this note claimed
//   they were code 2003 and "vestigial in Half-Life too" - both wrong, and the
//   consequence was that every zombie in the mod walked in complete silence while
//   its own model was asking for footsteps.  AI_HandleSharedEvent now plays them
//   generically, which is also where HL handles them (CBaseMonster, not the
//   per-monster class).
//
//   models/barnacle.mdl (7 sequences, 1 bone controller) - for W6.  The plan
//   recorded this model as having "no activities"; that is wrong, it has them for
//   everything EXCEPT its attack:
//     [0] idle1 act 1 61f@15 | [1] idle2 act 1 (2x code 1) | [2] idle3 act 1 loop
//     [3] flinch_sm act 26   | [4] attack1 act 0 (!) 51f@30 loop
//     [5] chewcycle act 35 (ACT_EAT) loop
//     [6] death act 36 101f@15, four code-2 events
//   So only "attack1" needs AI_SetSequenceNamed; the rest resolve by activity.
//   ACT_BARNACLE_HIT/PULL/CHOMP/CHEW (40-43) are the VICTIM's activities, played
//   by whatever the barnacle is eating - they are not in barnacle.mdl at all.
//
//   models/sentry.mdl, miniturret.mdl, turret.mdl (6 sequences each) - for W6.
//   These really do have NO activities: every sequence is act 0, so
//   frameforaction is useless on them and AI_SetSequenceNamed is mandatory.
//   All three carry the same six names, confirmed present in this install:
//     idle_off(1f, once)  deploy(once)  spin(LOOP)  fire(LOOP)  retire(once)  die(once)
//   "fire" loops on all three and carries code 5001 = EVENT_MUZZLEFLASH events
//   whose options string is HL's "<attachment><brightness>" pair ("21", "31",
//   "41", "51"), which is what the turret's shots should be timed off.
// ----------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// activities  (Half-Life activity.h)
// ---------------------------------------------------------------------------
const float ACT_RESET              = 0;
const float ACT_IDLE               = 1;
const float ACT_GUARD              = 2;
const float ACT_WALK               = 3;
const float ACT_RUN                = 4;
const float ACT_FLY                = 5;
const float ACT_SWIM               = 6;
const float ACT_HOP                = 7;
const float ACT_LEAP               = 8;
const float ACT_FALL               = 9;
const float ACT_LAND               = 10;
const float ACT_STRAFE_LEFT        = 11;
const float ACT_STRAFE_RIGHT       = 12;
const float ACT_ROLL_LEFT          = 13;
const float ACT_ROLL_RIGHT         = 14;
const float ACT_TURN_LEFT          = 15;
const float ACT_TURN_RIGHT         = 16;
const float ACT_CROUCH             = 17;
const float ACT_CROUCHIDLE         = 18;
const float ACT_STAND              = 19;
const float ACT_USE                = 20;
const float ACT_SIGNAL1            = 21;
const float ACT_SIGNAL2            = 22;
const float ACT_SIGNAL3            = 23;
const float ACT_TWITCH             = 24;
const float ACT_COWER              = 25;
const float ACT_SMALL_FLINCH       = 26;
const float ACT_BIG_FLINCH         = 27;
const float ACT_RANGE_ATTACK1      = 28;
const float ACT_RANGE_ATTACK2      = 29;
const float ACT_MELEE_ATTACK1      = 30;
const float ACT_MELEE_ATTACK2      = 31;
const float ACT_RELOAD             = 32;
const float ACT_ARM                = 33;
const float ACT_DISARM             = 34;
const float ACT_EAT                = 35;
const float ACT_DIESIMPLE          = 36;
const float ACT_DIEBACKWARD        = 37;
const float ACT_DIEFORWARD         = 38;
const float ACT_DIEVIOLENT         = 39;
const float ACT_BARNACLE_HIT       = 40;
const float ACT_BARNACLE_PULL      = 41;
const float ACT_BARNACLE_CHOMP     = 42;
const float ACT_BARNACLE_CHEW      = 43;
const float ACT_SLEEP              = 44;
const float ACT_INSPECT_FLOOR      = 45;
const float ACT_INSPECT_WALL       = 46;
const float ACT_IDLE_ANGRY         = 47;
const float ACT_WALK_HURT          = 48;
const float ACT_RUN_HURT           = 49;
const float ACT_HOVER              = 50;
const float ACT_GLIDE              = 51;
const float ACT_FLY_LEFT           = 52;
const float ACT_FLY_RIGHT          = 53;
const float ACT_DETECT_SCENT       = 54;
const float ACT_SNIFF              = 55;
const float ACT_BITE               = 56;
const float ACT_THREAT_DISPLAY     = 57;
const float ACT_FEAR_DISPLAY       = 58;
const float ACT_EXCITED            = 59;
const float ACT_SPECIAL_ATTACK1    = 60;
const float ACT_SPECIAL_ATTACK2    = 61;
const float ACT_COMBAT_IDLE        = 62;
const float ACT_WALK_SCARED        = 63;
const float ACT_RUN_SCARED         = 64;
const float ACT_VICTORY_DANCE      = 65;
const float ACT_DIE_HEADSHOT       = 66;
const float ACT_DIE_CHESTSHOT      = 67;
const float ACT_DIE_GUTSHOT        = 68;
const float ACT_DIE_BACKSHOT       = 69;
const float ACT_FLINCH_HEAD        = 70;
const float ACT_FLINCH_CHEST       = 71;
const float ACT_FLINCH_STOMACH     = 72;
const float ACT_FLINCH_LEFTARM     = 73;
const float ACT_FLINCH_RIGHTARM    = 74;
const float ACT_FLINCH_LEFTLEG     = 75;
const float ACT_FLINCH_RIGHTLEG    = 76;

// ---------------------------------------------------------------------------
// animation events  (Half-Life monsters.h / per-monster headers)
// ---------------------------------------------------------------------------
// Codes below 1000 are monster-specific and mean whatever that monster's C++
// class decided; codes from 1000 up are the shared engine/SDK set.  Because the
// low range is per-class, the dispatcher has to key on (classname, code) — the
// same number means different things to different monsters.
// These are Half-Life's real values (scriptevent.h / monsters.h), corrected
// against the codes actually present in the shipped models: zombie.mdl uses
// 1000, 1003, 1004, 1008, 2001 and 2003, headcrab.mdl uses 1000 and 1003.  An
// earlier version of this table had 1005 and 1009-1012 wrong; nothing consumed
// them yet, but a wrong constant here would have silently mis-dispatched the
// first script event that mattered.
const float EVENT_SPECIFIC_BASE    = 0;
const float EVENT_SHARED_BASE      = 1000;
const float EVENT_DEAD             = 1000;
const float EVENT_NOINTERRUPT      = 1001;
const float EVENT_CANINTERRUPT     = 1002;
const float EVENT_FIREEVENT        = 1003;
const float EVENT_SOUND            = 1004;	// options = sound to play
const float EVENT_SENTENCE         = 1005;
const float EVENT_INAIR            = 1006;
const float EVENT_ENDANIMATION     = 1007;
const float EVENT_SOUND_VOICE      = 1008;
const float EVENT_SENTENCE_RND1    = 1009;
const float EVENT_NOT_DEAD         = 1010;
// 1011 is Sven Co-op's / Opposing Force's generic "play this sound" event, and
// handling it is worth more than any single monster fix in this round: EVERY
// gearbox and Sven model puts its voice on 1011 rather than on HL's 1004.
// Measured out of the shipped models - strooper.mdl carries its attack and all
// four death sounds there and nothing else, and gonome.mdl carries its melee,
// footstep, jump and death sounds there.  Both monsters were completely silent
// because this constant did not exist.
//
// The options string is NOT consistent about the file extension: strooper writes
// "shocktrooper/shock_trooper_attack" and gonome writes
// "gonome/gonome_step1.wav".  AI_EventSoundName normalises the two.
const float EVENT_SOUND_SVEN       = 1011;
const float EVENT_BODYDROP_LIGHT   = 2001;
const float EVENT_BODYDROP_HEAVY   = 2002;
// The two body-drop samples, named HERE rather than at the point of use, because
// the point of use and the precache have to agree and they did not: the play site
// in AI_AnimEventShared hardcoded them, nothing precached them, and every zombie
// death printed "SV_StartSound: sound common/bodydrop3.wav not precached" in a
// live game.  AI_PrecacheModelSounds cannot catch these - it only harvests sounds
// NAMED in an event's options string, and HL leaves BODYDROP's name to its client
// dll, so the options field is empty.  Any future hardcoded event sound belongs
// beside these for the same reason.
// Named LIGHT/HEAVY only because the two EVENT codes are.  Half-Life picks
// between these two files AT RANDOM for BOTH codes (monsters.cpp:2694-2719) - the
// difference between light and heavy is PITCH, not file: heavy goes out through
// EMIT_SOUND_DYN at pitch 90.  The old one-file-per-code mapping here was an
// invention, and it made every heavy landing sound identical to a light one.
const string SND_BODYDROP_A        = "common/bodydrop3.wav";
const string SND_BODYDROP_B        = "common/bodydrop4.wav";
const float EVENT_SWISHSOUND       = 2010;
// 2010's sample is NOT anonymous, and the comment that used to sit on the swallow
// branch in sv_ai_anim.qc was simply wrong: monsters.cpp:2721-2726 names the file
// inline, right next to the warning that any monster using the event must precache
// it.  Thirteen melee wind-ups across six rigs (hgrunt/massn/strooper frontkicks)
// have been swinging in silence because the options field is empty and empty was
// read as "nothing to play".
const string SND_SWISH             = "zombie/claw_miss2.wav";
// 2003 is Sven Co-op's footstep event; it does not exist in the Half-Life SDK
// (monsterevent.h stops at 2010).  Measured across all 12038 loose models in the
// mounts: 104 occurrences in 19 rigs, and every single one sits on a LOCOMOTION
// sequence - walk, walk_new, walk_scared, run, run1, run2, creeping_walk,
// pistol_walk - with an EMPTY options string in all 104.  Nothing else it could be.
//
// Empty options means the sample has to be named here, exactly like BODYDROP.  The
// family is quoted from the corpus rather than chosen: Half-Life's own models name
// common/npc_step1..4.wav in 843 EVENT_SOUND events, which is the same sound for
// the same purpose on the rigs that spell it out instead of using code 2003.
const float EVENT_FOOTSTEP_SVEN    = 2003;
const string SND_NPC_STEP1         = "common/npc_step1.wav";
const string SND_NPC_STEP2         = "common/npc_step2.wav";
const string SND_NPC_STEP3         = "common/npc_step3.wav";
const string SND_NPC_STEP4         = "common/npc_step4.wav";
// 5001 is the client-side muzzleflash event.  Measured, not assumed: it is what
// all three turret models put on their "fire" sequences, options = HL's
// "<attachment><brightness>" digit pair.  Nothing consumes it until W6.
const float EVENT_MUZZLEFLASH      = 5001;

// headcrab.mdl: event code 2 on frame 0 of jump / jump_variation1 /
// jump_variation2.  This is the launch — the leap is driven by the ANIMATION,
// not by the schedule, so the attack task starts the sequence and the event
// pump applies the velocity when the model says so.
const float HCEV_JUMPATTACK        = 2;

// ---------------------------------------------------------------------------
// monster states  (Half-Life MONSTERSTATE)
// ---------------------------------------------------------------------------
const float MS_NONE                = 0;
const float MS_IDLE                = 1;	// dormant: one cheap check, then sleep
const float MS_COMBAT              = 2;
const float MS_ALERT               = 3;
const float MS_HUNT                = 4;
const float MS_PRONE               = 5;	// held by a barnacle / scripted
const float MS_SCRIPT              = 6;	// under scripted_sequence control
const float MS_PLAYDEAD            = 7;
const float MS_DEAD                = 8;

// ---------------------------------------------------------------------------
// condition bits  —  .int ai_cond, NEVER a float
// ---------------------------------------------------------------------------
// QC floats are exact only to 2^24, and a condition set is a bitfield that will
// keep growing; an int keeps every bit addressable and makes the & tests cheap.
const int COND_NONE                = 0;
const int COND_SEE_ENEMY           = 1;
const int COND_ENEMY_DEAD          = 2;
const int COND_ENEMY_OCCLUDED      = 4;
const int COND_ENEMY_TOOFAR        = 8;
const int COND_LIGHT_DAMAGE        = 16;
const int COND_HEAVY_DAMAGE        = 32;
const int COND_CAN_MELEE1          = 64;
const int COND_CAN_RANGE1          = 128;
const int COND_TASK_FAILED         = 256;
const int COND_SCHEDULE_DONE       = 512;
const int COND_HEAR_SOUND          = 1024;
const int COND_BLOCKED             = 2048;
const int COND_PROVOKED            = 4096;
const int COND_FRIEND_DAMAGED      = 8192;
const int COND_IN_SCRIPT           = 16384;
const int COND_NO_PATH             = 32768;
const int COND_ENEMY_FACING_ME     = 65536;
// A DANGER sound - HL's bits_SOUND_DANGER, the one that makes a squad scatter when
// a grenade lands among them.  Distinct from COND_HEAR_SOUND because the response is
// opposite: a heard gunshot makes a monster look TOWARDS it, a danger sound makes it
// run AWAY.  Nothing in this tree emitted one, which is why grenades have always
// been free damage against anything that was not already moving.
const int COND_HEAR_DANGER         = 131072;
// The player is shoving me out of the way.  CTalkMonster::Touch sets this when a
// player with more than 50 u/s of horizontal speed walks into a talker
// (talkmonster.cpp:876-896), and it is the ONLY input that makes an ally step
// aside - "you should be able to bump into a scientist to move them around" is
// the reported symptom of it not existing.
const int COND_CLIENT_PUSH         = 262144;

// Interrupt masks worth naming once rather than re-deriving per schedule.
const int COND_DAMAGE              = 48;	// LIGHT|HEAVY
const int COND_ATTACK_READY        = 192;	// CAN_MELEE1|CAN_RANGE1
const int COND_LOST_ENEMY          = 14;	// ENEMY_DEAD|OCCLUDED|TOOFAR

// ---------------------------------------------------------------------------
// world-sound TYPES  —  Half-Life's bits_SOUND_*, soundent.h:23-30
// ---------------------------------------------------------------------------
// A NOISE WITHOUT A TYPE IS THE SAME NOISE AS EVERY OTHER NOISE, and that single
// omission is the whole of "the scientists gently follow me around and don't care
// when I shoot".  Both symptoms are one bug seen from two ends:
//
//   * A footstep and a gunshot arrived here as the same event, so AI_HeardNoise
//     promoted MS_IDLE -> MS_ALERT for either, and the ALERT ladder handed out
//     SCHED_INVESTIGATE_SOUND - a WALK to wherever the player was standing.  Every
//     0.35s of walking re-aimed it.  That is not following; it is a scientist
//     repeatedly setting off to look at your feet.
//
//   * ...and the reverse: nothing could ask "was that a GUN", so the cower that
//     Half-Life gates on exactly that question could not be written at all.
//
// Half-Life filters twice and both halves matter.  CBaseMonster::Listen
// (monsters.cpp:211-217) ANDs the monster's own ISoundMask with the mask of the
// SCHEDULE it is currently running - `iMySounds &= m_pSchedule->iSoundMask` - and
// the SDK's comment on that line is "!!!WATCH THIS SPOT IF YOU ARE HAVING SOUND
// RELATED BUGS!  Make sure your schedule AND personal sound masks agree!".
//
// The values are Half-Life's own, unshifted, so the SDK reads across 1:1.
const int SND_COMBAT   = 1;	// gunshots, explosions
const int SND_WORLD    = 2;	// doors, breaking glass
const int SND_PLAYER   = 4;	// footsteps, splashing - anything the player emits
const int SND_CARCASS  = 8;	// unused here; kept so the bit numbering stays HL's
const int SND_MEAT     = 16;	// ditto
const int SND_DANGER   = 32;	// a grenade about to go off

// What a monster listens for when its class says nothing.  CBaseMonster::ISoundMask
// (monsters.cpp) is "all sounds, no scents", and CScientist::ISoundMask
// (scientist.cpp:791-796) is WORLD|COMBAT|DANGER|PLAYER - the same set.  Read
// through AI_SoundMaskNow so an unset .ai_soundmask means "the default", not
// "deaf": a zero mask fails every & test, and defaulting it per class would have
// meant editing 20 spawn functions to keep the status quo.
const int SND_DEFAULT  = 39;	// COMBAT|WORLD|PLAYER|DANGER

// ---------------------------------------------------------------------------
// classification  (Half-Life CLASS_*, consumed from the map's `classify` key)
// ---------------------------------------------------------------------------
// 2969 uses across the corpus and nothing reads them today.  The relationship
// matrix that turns these into "shoot / ignore / follow" lands with the ally
// work; the constants live here so the spawn path can store the key meanwhile.
const float CLASS_NONE             = 0;
const float CLASS_MACHINE          = 1;
const float CLASS_PLAYER           = 2;
const float CLASS_HUMAN_PASSIVE    = 3;
const float CLASS_HUMAN_MILITARY   = 4;
const float CLASS_ALIEN_MILITARY   = 5;
const float CLASS_ALIEN_PASSIVE    = 6;
const float CLASS_ALIEN_MONSTER    = 7;
const float CLASS_ALIEN_PREY       = 8;
const float CLASS_ALIEN_PREDATOR   = 9;
const float CLASS_INSECT           = 10;
const float CLASS_PLAYER_ALLY      = 11;
const float CLASS_PLAYER_BIOWEAPON = 12;
const float CLASS_ALIEN_BIOWEAPON  = 13;

// ---------------------------------------------------------------------------
// per-entity AI fields
// ---------------------------------------------------------------------------
// .enemy is deliberately NOT reused: it is already an activator stash on
// buttons, momentary and trigger_camera in this codebase, and quietly sharing it
// would make a monster's target and a button's last presser the same slot.  The
// bots set the same precedent with .bot_enemy.
.entity ai_enemy;
// A separate slot from ai_enemy on purpose.  The barnacle needs "what my tongue is
// holding", which is NOT the same question as "who am I fighting": the generic
// sighting path kept assigning a player it could see across the room to ai_enemy,
// and the class kept clearing it, so the monster oscillated between two schedules
// 295 times in 45 seconds without ever touching anything.
.entity ai_victim;
.float  ai_state;		// MS_*
.int    ai_cond;		// COND_* bitfield
.float  ai_class;		// CLASS_*, from the map's `classify` key

.float  ai_sched;		// current schedule id
.float  ai_task;		// cursor into that schedule's task list
.float  ai_taskend;		// time the current task completes / times out at
.float  ai_taskdone;		// set by AI_TaskComplete; the run loop consumes it
.float  ai_lasttick;		// last decision tick, and the multiplethinks guard
.float  ai_lasthealth;		// health at the previous damage event, to size the hit
.float  ai_nextflinch;		// flinch rate limit, so sustained fire cannot stunlock
.float  ai_dead_done;		// death schedule has finished; the corpse may stop thinking

// WHERE AND FROM WHAT DIRECTION THE LAST HIT LANDED.  Half-Life's m_LastHitGroup
// (monsters.h) and g_vecAttackDir (globals.cpp:34), which between them are the
// entire input to GetDeathActivity and GetSmallFlinchActivity - the two functions
// that decide a monster falls forward when shot in the back, clutches its head
// when shot in the head, and grabs the arm that was hit.  Neither existed here,
// which is why every monster in the game died the same way from every angle.
//
// The hitgroup is COPIED off .death_hitgroup rather than re-derived: the weapon
// layer already resolves a hitgroup per bullet (W_BoneToHitgroup and the OBB
// fallback, sh_weapon_logic.qc:560-670) and stamps it on the victim before
// calling W_ApplyDamage, so re-tracing here would be a second, differently-wrong
// answer to a question already answered.
//
// PER-HIT, NOT STICKY, and that is a deliberate divergence.  .death_hitgroup is
// written by the eleven paths that KNOW a hitgroup and by nobody else, while
// W_ApplyDamage has 63 callers - doors, lasers, radius blasts, debug commands.
// Left sticky (which is what Half-Life does: m_LastHitGroup is only ever written
// in TraceAttack) a monster shot once in the head and later crushed by a door
// plays the headshot death.  AI_ConsumeHit resets it, so a path that does not
// stamp reads HITGROUP_GENERIC - which is precisely what GENERIC means to both
// of the pickers: "no region, use the direction".
.float  ai_lasthitgroup;	// HITGROUP_*, valid only for the hit being processed
.vector ai_attackdir;		// unit vector from the victim's centre TOWARD the inflictor
// The activity the last death or flinch pick RESOLVED to, latched at the moment
// the task ran.  A latch rather than reading .ai_activity afterwards, because a
// flinch is over in about half a second: any test that samples the field later is
// racing the animation and would report "generic flinch" for a monster that had
// already gone back to idle.  Read by sv_ai_deathtest and by `cmd ai_hurt`.
.float  ai_dbg_hitact;

// ---------------------------------------------------------------------------
// the gargantua's flame
// ---------------------------------------------------------------------------
// Declared here rather than in mon_bigfoes.qc because sv_ai_sched.qc builds the
// schedule that carries the duration and compiles long before any class file.
//
// Numbers are Half-Life's own: GARG_FLAME_LENGTH 330 (gargantua.cpp:55),
// GARG_ATTACKDIST 80 (:37), the 0.8 facing dot and the 6-second cooldown
// (:938-946, :1092), and the 4.5-second sweep (:401).
const float GARG_FLAME_LENGTH  = 330;
const float GARG_FLAME_MINDIST = 80;	// closer than this and it slashes instead
const float GARG_FLAME_DOT     = 0.8;	// must be facing the enemy this squarely
const float GARG_FLAME_SECONDS = 4.5;	// how long one sweep burns
const float GARG_FLAME_COOLDOWN = 6;	// before it may flame again

// HL's m_seeTime, the STOMP's gate.  Two things write it: the stomp event pushes it
// 12 seconds out, and PrescheduleThink resets it to time + 5 on every think where
// the gargantua cannot see its enemy (gargantua.cpp:693-703).  So a gargantua needs
// five continuous seconds of line-of-sight before its first stomp and twelve between
// them, which is most of the difference between a boss you can outmanoeuvre and one
// that shockwaves you every four seconds.  Same shape as ai_flametime above.
.float ai_seetime;
.float  ai_flametime;		// earliest time this gargantua may flame again

// ---------------------------------------------------------------------------
// squads  (Half-Life CSquadMonster, squadmonster.h / squadmonster.cpp)
// ---------------------------------------------------------------------------
// Nothing here had a QC equivalent, and the tell was that COND_FRIEND_DAMAGED
// (above) had exactly one reference tree-wide: its own declaration.  Three
// behaviours fall out of the absence, and all three are things players notice
// without being able to name:
//
//   grunts never call out, so a squad only knows about you one man at a time;
//   grunts all fire at once, because nothing rations who may engage;
//   houndeyes never form the pack, so their blast is stuck on the solo colour.
//
// A CHAIN, not Half-Life's five handles.  m_hSquadMember[4] plus the
// "MySquadMember(4) returns the leader" trick exists because the C++ side needed
// a fixed-size save/restore block; a QC entity chain has neither constraint, and
// the cap is enforced on the way in instead.  The leader is the HEAD of its own
// chain, so "walk the squad" is one loop with no special case for the leader.
.entity ai_squad_leader;	// self if leader, world if not in a squad
.entity ai_squad_next;		// next member along the leader's chain
.float  ai_squad_tried;		// recruitment has been attempted (once per monster)

// The attack slots, which are what stop a squad firing as one animal.  Held on
// the LEADER as a bitfield; each member remembers which single bit it took.
// squadmonster.h:22-48 exactly, because the bit layout is per-family and a class
// asking for the wrong pair would silently share a slot with another species.
.int    ai_squad_slots;		// leader only: which bits are taken
.int    ai_slot;		// this monster's bit, or SQSLOT_NONE

const int SQSLOT_NONE            = 0;
const int SQSLOT_ENGAGE1         = 1;
const int SQSLOT_ENGAGE2         = 2;
const int SQSLOTS_ENGAGE         = 3;
const int SQSLOT_GRENADE1        = 4;
const int SQSLOT_GRENADE2        = 8;
const int SQSLOTS_GRENADE        = 12;
const int SQSLOT_AGRUNT_HORNET1  = 16;
const int SQSLOT_AGRUNT_HORNET2  = 32;
const int SQSLOT_AGRUNT_CHASE    = 64;
const int SQSLOTS_AGRUNT_HORNET  = 48;
const int SQSLOT_HOUND_ATTACK1   = 128;
const int SQSLOT_HOUND_ATTACK2   = 256;
const int SQSLOT_HOUND_ATTACK3   = 512;
const int SQSLOTS_HOUND_ATTACK   = 896;
// squadmonster.h:47.  When the squad is not all fighting the same enemy the
// slot system is DISABLED rather than enforced - otherwise a member whose enemy
// is nobody else's can be locked out of attacking by slots that have nothing to
// do with its fight.
const int SQSLOT_SQUAD_SPLIT     = 1024;
const float SQUAD_NUM_SLOTS    = 11;	// squadmonster.h:49

const float SQUAD_MAX_MEMBERS  = 5;	// squadmonster.h:51, leader included
const float SQUAD_RECRUIT_DIST = 1024;	// hgrunt.cpp / houndeye.cpp StartMonster

// Which slots a class wants for its ranged attack.  0 means "this class has no
// slot discipline" - most do not, and giving every monster slots would make a
// pair of headcrabs take turns, which is not a behaviour Half-Life has.
.int    ai_slots_attack;

// ---------------------------------------------------------------------------
// take cover  (sv_ai_cover.qc)
// ---------------------------------------------------------------------------
// TASK_FIND_COVER_ENEMY has two successful outcomes that finish differently: a
// sidestep is a LOCAL move and is ready at once, a nav-node relocation has a
// path request in flight and must be waited on.  The task cannot tell them apart
// from its opcode, so the finder records which it was.
.float  ai_coverwait;		// TRUE while a cover path request is outstanding
// When this monster may next go looking.  A search that finds nothing is not
// free - it is a gather plus up to COVER_TRACE_MAX tracelines - and a monster
// standing in an open room under fire would otherwise run one every time it
// re-selected, for as long as the fight lasted.
.float  ai_covernext;
.vector ai_dangerpos;		// where the danger sound came from - cover is taken FROM this
.float  ai_danger_until;	// how long that position stays the thing worth fleeing
.vector ai_soundpos;		// where the last heard noise was, for going to look at it
.float  ai_investigate_next;	// rate limit on leaving a post to investigate

.float  ai_activity;		// ACT_* currently playing
.string ai_seqname;		// ...or the sequence NAME, for models with no activity tags
.float  ai_seq;			// resolved sequence index for it
.float  ai_seqstart;		// time it began
.float  ai_seqdur;		// its duration, 0 = looping / unknown
.float  ai_seqend;		// time the sequence finishes (0 = never, i.e. looping)
.float  ai_evtcursor;		// seconds into the sequence already pumped for events

.float  ai_yaw_ideal;		// desired facing; turned toward at ai_yaw_speed
.float  ai_yaw_speed;
// When AI_ChangeYaw last actually rotated this monster.  Half-Life's
// m_flLastYawTime, and here for the same reason: ChangeYaw is called from two
// places in a tick - inside AI_MoveAlongPath right after the ideal is computed,
// and again after the schedule for monsters that turn without moving - and the
// rotation must not stack.  The second call of a frame finds zero elapsed and
// returns without moving anything.
.float  ai_yawtime;
// Throttle for the `sv_ai_debug 2` blocked-step diagnostic in AI_StepToward.
.float  ai_dbg_blockgripe;
// The floor under ai_nextpath that a route-less monster may NOT skip.  ai_nextpath
// is the ordinary courtesy throttle and a monster with no path at all is allowed
// past it; this one is set only by a real failure (queue full, goal unreachable)
// and is what keeps that exemption from becoming a retry storm.
.float  ai_nextpath_hard;

.float  ai_lastseen;		// time the enemy was last visible
.vector ai_lastseenpos;		// where it was then, for search behaviour

// --- locomotion ---
.float  ai_moveact;		// ACT_* to play while moving
.vector ai_goalpos;		// where the current path is trying to reach
.float  ai_stuck;		// consecutive decision ticks that made no progress
.vector ai_lastorg;		// origin at the previous tick, for the stuck test
.float  ai_avoidside;	// latched corner-avoidance side: 0 none, +1 left, -1 right
// Expiry stamp for a straight-line move granted by AI_LocalMoveClear, i.e. the
// case Half-Life's BuildRoute returns on before it ever consults the node graph.
// While this is in the future AI_MoveAlongPath walks at ai_goalpos and ignores
// any stored route entirely.  See the block above AI_LocalMoveClear.
.float  ai_directmove;
// ...and the bar on being granted another one, set when a route ends BLOCKED.
// AI_LocalMoveClear traces MOVE_NOMONSTERS, so the one obstruction it cannot
// see is another monster; without a bar, a monster blocked by a squadmate is
// re-granted the same still-"clear" line every 0.25s forever.
.float  ai_nodirect;
.float  ai_turnticks;	// consecutive ticks spent turning without ever stepping

// Per-ACTIVITY turn rate, Half-Life's CBaseMonster::SetYawSpeed.
//
// HL does not carry one turn rate per monster; it carries one per monster PER
// ANIMATION, and re-picks it inside SetActivity (monsters.cpp:1240) every time
// the activity changes.  An hgrunt turns at 180 while turning on the spot, 150
// while running and 120 while shooting (hgrunt.cpp:643-683), and that spread is
// most of why an HL monster reads as heavy when it fights and nimble when it
// repositions.
//
// A class that leaves this unset keeps whatever ai_yaw_speed its init assigned,
// which is the mod's own hand-picked figure - so adding a table to a class is
// opt-in and no class regresses by omission.
.float(entity m, float act) ai_yawspeed;

// Per-ACTIVITY sequence override, Half-Life's per-class SetActivity.
//
// Half-Life reaches a whole family of sequences BY NAME rather than through the
// activity tag, and CHGrunt::SetActivity (hgrunt.cpp:1866-1972) is the canonical
// example: it switches on the requested activity and calls LookupSequence with a
// literal string for the ones where the model carries several candidates and only
// the loadout can say which is right.  Anything it does not name falls through to
// LookupActivity, i.e. the ordinary path.
//
// Without this the mod resolves those through frameforaction, which RE-ROLLS its
// weighted random on every call - so a rig with two sequences sharing an activity
// tag plays each of them about half the time, and there is no relationship at all
// between what the monster is holding and what it is seen to do.  Measured tag
// collisions in the rigs the mod ships:
//
//   hgrunt         act 28 crouching_mp5 / crouching_shotgun
//                  act 29 launchgrenade / throwgrenade
//   hgrunt_opfor   act 28 adds crouching_saw;  act 32 reload_mp5 / reload_saw
//   massn          act 28 adds crouching_m40a1
//   hwgrunt        act 28 attack / pistol_shoot / pistol_crouchshoot
//                  act  3 creeping_walk / pistol_walk
//                  act  4 run / pistol_run
//
// Returning "" (or a name the model does not carry) falls through to the normal
// activity resolution, so a class that leaves this unset behaves exactly as before
// and a Sven replacement model missing a name degrades instead of freezing.
.string(entity m, float act) ai_seqfor;
.float  ai_nextpath;		// earliest time this monster may request another path
.float  ai_nextscan;		// earliest time it may sweep the MONSTER chain for a target
.float  ai_failsched;		// SCHED_* to run if a task fails (TASK_SET_FAIL_SCHED)
// (no ai_wake field: dormancy ended up needing no per-entity state.  AI_Think
// simply picks its own nextthink interval, so a sleeping monster re-checks on
// its own schedule rather than against a stored wake time.)

// --- locomotion mode ---
// How a class gets around.  Dispatched at exactly four points — spawn placement,
// the step itself, the reach test, and the schedule ladder — and GROUND is tested
// FIRST at every one of them, so the walkmove path the shipped monsters were
// verified against stays byte for byte what it was.
//
// FLY and SWIM share one physics contract: MOVETYPE_STEP with FL_FLY.  The engine
// then applies no gravity and integrates no velocity (WPhys_Physics_Step,
// sv_phys.c:1537), so the monster moves only when QC moves it — exactly the
// contract the ground path already runs under.  Two traps this avoids on purpose:
//
//   MOVETYPE_FLY is NOT used.  It falls through to WPhys_Physics_Toss, which does
//   skip gravity but sets FL_ONGROUND and zeroes velocity on any impact with a
//   >0.7-up plane normal (sv_phys.c:1485), after which the "if onground, return
//   without moving" early-out (:1381) skips the entity entirely.  A flyer that
//   grazes a floor once is pinned there for the rest of the map.
//
//   FL_SWIM is NOT used and .waterlevel is NEVER read.  FL_SWIM's no-gravity rule
//   is `freefall = waterlevel <= 0` (:1542), and on a MOVETYPE_STEP monster that
//   field is not merely unfilled, it is wrong: WPhys_CheckWaterTransition writes
//   waterlevel = 1 unconditionally on its first call regardless of contents
//   (:1319), samples the ORIGIN POINT only, and on the dry path writes
//   Q1CONTENTS_EMPTY = -1 rather than 0 (:1348).  Swimmers carry FL_FLY and use
//   their own pointcontents probe (AI_InWater) instead.
const float AIMODE_GROUND = 0;	// walkmove, gravity, FL_ONGROUND
const float AIMODE_FLY    = 1;	// free 3D movement, no gravity
const float AIMODE_SWIM   = 2;	// free 3D movement, confined to liquid
const float AIMODE_STATIC = 3;	// bolted down: turrets, barnacles, tripmines

// ---------------------------------------------------------------------------
// Half-Life monster spawnflags (CBaseMonster, HL SDK monsters.h)
// ---------------------------------------------------------------------------
// These have been sitting unread on every map-placed monster since B2, and two of
// them explain behaviour that reads as broken when it is not.  Measured on
// hl_c01_a1: of ~41 monsters, nearly all carry 256, several 384 (= 256|128) and a
// few 258 (= 256|2).
//
// WAIT_FOR_SCRIPT is the big one.  A monster carrying it is SUPPOSED to stand
// perfectly still doing nothing until a scripted_sequence claims it - so a map
// full of statues is the correct rendering of a map whose scripts do not run yet,
// not a broken AI.
//
// PRE_DISASTER is Half-Life's "before the resonance cascade" mode: the talkers
// are going about their jobs, will not fight, and REFUSE to follow the player.
// We currently let them follow, which makes the one working interaction on that
// map the one that should not happen.
const float SF_MON_WAIT_TILL_SEEN  = 1;
const float SF_MON_GAG             = 2;		// silent until provoked
const float SF_MON_MONSTERCLIP     = 4;
const float SF_MON_PRISONER        = 16;	// never fights, never targeted; latched into .ai_prisoner
// Bit 32 belongs to squadmonster.h, not monsters.h - CSquadMonster::StartMonster
// (squadmonster.cpp:415-435) reads it as "this one is allowed to form the squad".
// A monster that names a squad in `netname` but does NOT carry it recruits nobody
// and waits to be recruited; without the gate every member tried to lead.
const float SF_SQUADMONSTER_LEADER = 32;
const float SF_MON_WAIT_FOR_SCRIPT = 128;	// inert until a scripted_sequence takes it
const float SF_MON_PRE_DISASTER    = 256;	// pre-cascade: passive, will not follow
const float SF_MON_FADE_CORPSE     = 512;

// monster_generic ONLY, and it collides with SF_MONSTER_MONSTERCLIP on every
// other class - genericmonster.cpp:25 reuses bit 4 for its own meaning, which is
// why it is named after its class rather than filed with the shared flags above.
// 94 of the corpus's 166 placements set it.
const float SF_GENERICMONSTER_NOTSOLID = 4;

// SF_MON_PRISONER, decoded once at spawn.  AI_ValidEnemy asks this per candidate
// per tick and a spawnflag decode there would be the same answer computed a few
// hundred times a second.
.float ai_prisoner;

// Set by AI_Spawn when the body cannot be stood anywhere.  The caller keeps an
// unplaced map-placed monster as an inert prop (its targetname may anchor a
// chain), but squadmaker removes its own and retries next interval - which it can
// only decide if it is told, and the FALSE return never reached it through
// Monster_Build.
.float ai_placefail;

// The inverse switch: set by Monster_Spawn from the maker's spawn_mode 2, "Force
// spawn, never block" (sven-coop.fgd:5451).  AI_Spawn keeps a body that failed
// placement instead of stripping it to an inert prop, so the maker books a slot
// and the wave arrives even when the spawn point is occupied.  22 of
// pizza_ya_san1's 97 makers ask for this.
.float ai_forceplace;

// ---------------------------------------------------------------------------
// scripted_sequence possession  (server/sv_scripted.qc)
// ---------------------------------------------------------------------------
// Half-Life's CCineMonster takes a monster AWAY from its own AI for the duration
// of a scene: the monster stops choosing schedules and does exactly what the
// script says.  MS_SCRIPT has been sitting in the state list unused since B2
// waiting for this; these are the sub-states within it, mirroring HL's
// SCRIPT_WALK_TO_MARK / RUN_TO_MARK / WAIT / PLAYING.
//
// The split matters because "possessed" is two different situations.  A monster
// on its way to the mark is walking and can be blocked; a monster AT the mark is
// holding a pose and is doing nothing at all until the script is triggered - and
// the second of those is the common case by a wide margin.  Measured on
// hl_c01_a1: 7 of the map's 95 scripts claim their monster at spawn and hold it,
// which is the entire opening tableau (the barney at the desk, the leaning
// barney, the arguing gman and scientist, the coffee scientist, the airlock
// barney).  Those seven sit in WAIT for as long as the player takes to walk past.
const float SCRIPTST_NONE = 0;
const float SCRIPTST_WALK = 1;	// heading for the mark on foot
const float SCRIPTST_RUN  = 2;
const float SCRIPTST_WAIT = 3;	// at the mark, holding m_iszIdle, waiting to be told to go
const float SCRIPTST_PLAY = 4;	// playing m_iszPlay

// Declared here rather than in sv_scripted.qc for the same reason as the talk
// fields below: sv_ai_core.qc reads them (the schedule gate, the death path and
// the dormancy test all do) and it compiles first.
.entity ai_script;		// the scripted_sequence that owns this monster
.float  ai_scriptstate;		// SCRIPTST_*
.float  ai_scriptgo;		// the script has been told to play; wake up and do it
.float  ai_scriptretry;		// re-paths spent trying to reach the current mark
// Latched TRUE the first time a scripted_sequence hands this monster back
// (Script_Release).  It exists so "still waiting for its script" can be asked as
// a question: SF_MON_WAIT_FOR_SCRIPT is a spawnflag and is never cleared, and
// .ai_script is world both BEFORE a script claims the actor and AFTER it lets go,
// so neither of them can tell those two states apart on its own.
.float  ai_script_played;

// Sven Co-op's arrival tolerance at a script mark (157 uses corpus-wide).  It is
// a scripted_sequence KEY and belongs with the rest of them in sv_scripted.qc,
// but TASK_WAIT_FOR_MOVE reads it off .ai_script and that lives in sv_ai_core.qc,
// which compiles first - so the declaration has to be here or the interpreter
// cannot see the field.
.float  moveto_radius;

// ---------------------------------------------------------------------------
// world-sound hearing  (server/sv_ai_core.qc)
// ---------------------------------------------------------------------------
// .ai_soundmask is HL's ISoundMask - the TYPES this class cares about.  Left 0 by
// every class today, which AI_SoundMaskNow reads as SND_DEFAULT; a class that
// wants to be deaf to something sets its own.
//
// .ai_soundtype is HL's PBestSound()->m_iType: the type of the noise currently
// sitting in .ai_soundpos.  Recorded at the same instant as the position, because
// the two are one fact and the schedule picker has to ask about both - "walk over
// and look" is right for a gunshot and wrong for a footstep, and until this field
// existed the picker could not tell them apart.
.int    ai_soundmask;
.int    ai_soundtype;

// Where the player was standing when they shoved me.  TASK_GET_PATH_AWAY needs a
// threat POSITION for its cover fallback and cannot use .ai_enemy, because the
// whole point of COND_CLIENT_PUSH is that the person in the way is a friend.
.vector ai_pushpos;

// Cower rate-limit.  CScientist::GetSchedule (scientist.cpp:948-953) refuses to
// duck again within 3 seconds of the last time - `m_fearTime` - so a firefight
// nearby startles a scientist once rather than pinning him in a crouch loop for
// its duration.  It is also stamped on SEEING the enemy, which is what stops him
// ducking at the gun that is already pointed at him.
.float  ai_feartime;

// ---------------------------------------------------------------------------
// CTalkMonster state  (server/sv_ai_talk.qc)
// ---------------------------------------------------------------------------
// Declared here rather than beside the code that uses them because the talk
// layer compiles LAST - it speaks through the sentence table - while both
// sv_ai_core.qc and the class inits touch these fields and compile before it.
.float  ai_talker;		// this class does the CTalkMonster behaviours
.string ai_talk_group;		// sentence group prefix, e.g. "SC" / "BA"
.entity ai_lookat;		// who we are deliberately looking at
.float  ai_lookend;		// ...until when
.float  ai_talk_next;		// next idle line
.float  ai_talk_greet;		// next allowed greeting
.float  ai_scared_next;		// next allowed "you're shooting!" reaction

// Who this monster is escorting.  Set by +use on an ally, cleared by +use again
// or by that player dying/disconnecting.  It is an ENTITY rather than a flag
// because HL allies follow the specific person who asked, not "the players".
.entity ai_follow;
.float  ai_followsay;		// rate limit on the follow/wait acknowledgement
.float  ai_enemy_since;		// time this engagement began; HL's bits_COND_NEW_ENEMY

// --- CScientist's syringe (scientist.cpp:1080-1100) -------------------------
// m_healTime: absolute time before which CanHeal refuses.  HL sets it to
// time+60 only on a heal that actually LANDED, never on one refused for range,
// which is what lets a scientist keep chasing a hurt player instead of going on
// cooldown for a near miss.
.float  ai_healtime;
// Who the needle is for.  HL has no separate field - it heals m_hTargetEnt, the
// person being escorted, because in HL a scientist only ever heals someone who
// asked him to follow.  We seat this separately so the far more common case in
// this corpus (a hurt player walks up to a scientist who is not escorting
// anybody) also works; when an escort IS in progress it holds ai_follow and the
// behaviour is Half-Life's.  See Scientist_CanHeal.
.entity ai_healtarget;

// --- Sven guard_ent / freeroam (see AI_WantsToGuard / AI_WantsToRoam) --------
// The RESOLVED guard goal.  Resolved lazily rather than at spawn, because the
// thing being guarded frequently does not exist yet when the guard does:
// desertcircle creates every one of its guard objects at runtime with
// trigger_createentity, after the first wave of grunts has already spawned.
.entity ai_guard;
.float  ai_guard_next;		// re-resolve throttle; a missing goal is the common case
.float  ai_guard_retry;		// backoff after a guard walk that never arrived
.vector ai_roam_goal;		// current wander destination (world coords)
.float  ai_roam_next;		// earliest time a new wander leg may be picked

.float  ai_movemode;		// AIMODE_*; 0 is GROUND, so the default needs no help
.float  ai_flyheight;		// FLY: wanted clearance under the hull, 0 = keep placement height

// --- per-class data, filled in by the class init ---
.float  ai_melee_range;
.float  ai_range_range;
// FIELD OF VIEW, as a dot threshold against the monster's own forward - Half-Life's
// m_flFieldOfView, and the whole thing was missing.  AI_CanSee is a bare line of
// sight, so a monster could ACQUIRE a target standing directly behind it: not blind,
// omniscient, with no blind side to flank and no way to sneak past anything.
//
// 0.5 is CBaseMonster's default (60 degrees off centre, 120 total).  0 means 360 and
// is right for things with eyes all round or no eyes at all.  Read ONLY on
// acquisition, never on tracking or shooting - HL's Look() tests FInViewCone &&
// FVisible while FVisible alone has no cone, so once a monster has you it keeps you.
.float  ai_fov;
// Per-class acquisition range, 0 = "use the global sv_ai_sight".
//
// sv_ai_sight is one number for every monster in the game, and for most of them
// that is right - HL's own default is 1024 and the classes cluster around it.
// It is badly wrong for the small ones.  CRoach::Look is a 150-unit sphere
// (roach.cpp:425-430), so a Half-Life cockroach only notices you when you are
// almost on top of it; ours noticed at 2048 and spent the entire map in a
// permanent panic, which is what "are they supposed to run away from the player?"
// was actually asking about.
.float  ai_sight;
.float  ai_spread;		// hitscan cone, HL's vecSpread (sine of the half-angle)
.float  ai_dmg_scale;		// size scale for rescaled variants (babygarg vs gargantua)
.float  ai_speed_walk;
.float  ai_speed_run;
.float  ai_nextattack;		// per-class attack cooldown, armed by AI_ArmAttackCooldown
.float  ai_nextimplode;		// houndeye: rate limit on the wind-up ring multicast

// Half-Life bodygroup values for this monster's rig, in .body terms.
//
// GoldSrc packs every bodypart's choice into ONE integer: studiomdl gives each
// bodypart a `base` multiplier and the renderer recovers the choice with
// (body / base) % nummodels (gl_hlmdl.c:1883).  So a single number selects the
// head AND the weapon AND the torso, and the values below are dumped from each
// model's bodyparts lump rather than guessed.
//
// Three states is all any rig in the corpus needs, and all three are things the
// player sees: the weapon in hand, the weapon put away, and the weapon gone
// because the corpse just dropped it.  A model with no weapon bodygroup leaves
// all three at 0 and nothing changes for it.
.float  ai_body_armed;		// weapon in hand
.float  ai_body_holster;	// weapon stowed (HL's idle state for talkers)
.float  ai_body_gone;		// weapon dropped - no gun on the corpse
.float  ai_nextpain;		// pain-sound rate limit; sustained fire must not machine-gun it

// The per-class base delay BETWEEN attack sequences, in seconds, and 0 is a real
// and common value rather than "unset".
//
// Half-Life's shooters mostly have no cooldown at all - CHGrunt::CheckRangeAttack1
// (hgrunt.cpp:444-468) has no time gate whatsoever and tlGruntSuppress chains FIVE
// TASK_RANGE_ATTACK1 back to back, and CBarney never touches m_flNextAttack.  In
// both cases the firing ANIMATION is the rate limit.  So 0 here means "as fast as
// the sequence plays", which is the faithful default, and anything above it is a
// deliberate slowdown for a class that would otherwise be unfair.
.float  ai_attackrate;

// ---------------------------------------------------------------------------
// grudges  —  HL's m_afMemory / m_flPlayerDamage
// ---------------------------------------------------------------------------
// An ally that cannot be angered is not an ally, it is scenery that talks.  Ours
// could not: AI_Damaged only ever adopted an attacker that AI_ValidEnemy already
// approved of, and the faction matrix says a player is a friend - so a player
// could empty a magazine into Barney's chest and he would apologise for being in
// the way.
//
// Half-Life keeps this as two memory BITS plus an accumulated damage total
// (barney.cpp:509-546), and every part of that structure is load-bearing:
//
//   SUSPICIOUS  first hit that did NOT look deliberate.  "Hey, watch it."
//   PROVOKED    he means it.  He shoots back and the escort is over.
//
// The escalation between them is the whole design - one stray round is a
// warning, the second is a war - and it is why a single bit would not do.
const float MEMORY_SUSPICIOUS = 1;
const float MEMORY_PROVOKED   = 2;

.float  ai_memory;		// MEMORY_* bits
.float  ai_playerdmg;		// HL's m_flPlayerDamage: total taken from players
.float  ai_grudge_end;		// when PROVOKED lapses; 0 = not provoked
.float  ai_noshoot_next;	// rate limit on the "stop shooting my friend" line
.float  ai_provoke_instant;	// scientist rule: first hit provokes, no warning shot
.float  ai_follow_kick;		// grace window after +use: ignore the resume band

// Counted separately, for the same reason every other feature here is counted:
// "Barney shot back" and "Barney was hit by a player" are different events, and
// the GAP between them is the entire crossfire exemption.  One number could not
// tell a working escalation from one that fires on every stray round - which is
// exactly the way this feature fails.
//
// Declared here rather than beside the code in sv_ai_talk.qc because
// sv_ai_factions.qc bumps ai_dbg_forgiven and compiles first, and QC
// forward-declares functions but not globals.
float ai_dbg_plhit;		// player landed a hit on a talker
float ai_dbg_suspicious;	// -> "hey, watch it"
float ai_dbg_provoked;		// -> he means it
float ai_dbg_forgiven;		// grudge lapsed
float ai_dbg_noshoot;		// a bystander told the player off

// Per-class shots fired.  Split out rather than lumped into one total because
// the bug this was written for was class-specific: the assassin's event code
// fell off the end of the grunt's dispatch, so the ROSTER fired normally while
// 504 placements of one class fired nothing at all.  A single total would have
// hidden that completely.
float ai_dbg_shots_grunt;
float ai_dbg_shots_barney;
float ai_dbg_shots_assassin;

// ---------------------------------------------------------------------------
// per-class virtuals
// ---------------------------------------------------------------------------
// Entity function-pointer fields, the same idiom as .on_killed (sv_doors.qc:1168)
// and dispatched the same way: save `self`, assign, call, restore.
//
// ai_event deliberately takes no arguments and reads two globals instead.  That
// is this codebase's existing convention for parameterised .use dispatch
// (sub_use_type / sub_use_caller in sv_goldsrc_compat.qc), and it keeps every
// virtual the same `.void()` shape so the dispatch helper is one function
// rather than one per signature.
.float() ai_selectsched;	// conditions -> SCHED_*; 0 means "use the generic pick"
.void()  ai_checkattack;	// veto COND_CAN_MELEE1/RANGE1 the generic gather just set
// Half-Life's CBaseMonster::TakeDamage override, as a virtual: the last chance to
// change or refuse an incoming hit BEFORE it is subtracted from health.  It has to
// run before rather than after, which is what .on_damaged (AI_Damaged) cannot do -
// that hook only fires once the health is already gone, and only while the target
// still has some, so nothing installed there can stop a killing blow.
//
// The gonarch is the first caller and the reason it exists: she is unkillable
// until she has finished walking her info_bigmomma chain, so a fatal hit has to be
// cut down to leave her at 1 health and advance a stage instead.  Returns the
// damage to actually apply.  Unset means "apply it unchanged", so this costs one
// null test per hit for every monster that has no opinion.
.float(entity m, float damage, float dmgbits) ai_damagefilter;
// Unconditional per-decision-tick hook, for behaviour that is not an attack and
// not driven by an anim event.  ai_checkattack cannot serve this purpose: it only
// runs when COND_ATTACK_READY is already set, which requires a non-zero attack
// range - so a class with no conventional attack (the barnacle, whose ranges are
// both 0 because the generic ladder must never offer it an attack schedule) would
// never be called at all.  Measured: the barnacle's tongue check ran zero times.
.void()  ai_tick;
.void()  ai_startattack;	// schedule-driven attack windup (the anim event lands the hit)
.void()  ai_death;
.void()  ai_idlesound;
.void()  ai_alertsound;
.void()  ai_painsound;		// rate-limited by AI_Damaged, not by the class
// The same four voices as DATA rather than as code.  A family is a space-separated
// list of complete sound paths; AI_SndPlay picks one, AI_SndPrecache walks the
// identical string.  Each is consulted only when the matching .void() virtual is
// unset, so no existing class changes behaviour.
//
// Two things this buys that a per-class sprintf("...%g...", ceil(random()*n))
// cannot:
//
//   FAMILIES HAVE GAPS.  Half-Life's ichthyosaur takes pain 2, 3 and 5; the
//   gonarch takes 2, 4 and 5; the islave takes alert 1, 3 and 4.  Every %g
//   formulation is an unwritten claim that the family runs 1..n unbroken, and the
//   audit that produced these fields found four places where that claim is false
//   and the missing file has never existed in any mount: ichy_bite3, gon_pain3,
//   con_fire1 and con_fire2.
//
//   ONE STRING PRECACHES AND PLAYS.  Precached-but-never-played and
//   played-but-never-precached are the two failure modes of a hand-maintained
//   sound list, and both of them are present in this tree today.  Sharing the
//   literal makes them unrepresentable rather than merely detectable.
.string ai_snd_pain;
.string ai_snd_die;
.string ai_snd_idle;
.string ai_snd_alert;
// Two more families, owned by the CLASS rather than by the AI core: nothing here
// plays them, the class's own event handler does.  They exist as fields instead of
// as constants because a class can arrive wearing either of two rigs - a pitdrone
// without Opposing Force mounted is a bullsquid, and it must not ask for a
// gearbox-only sample it has no file for.  Same reasoning as .ai_seqfor.
.string ai_snd_shoot;
.string ai_snd_melee;
// The two knobs Half-Life's per-class emit macros vary.  0 means HL's own default
// for that knob: ATTN_NORM, and +/-5 of pitch jitter.  The ichthyosaur overrides
// the attenuation to 0.6 and the leech its alert to 0.4 - both engines cut a
// sound off at 1000/attenuation units, so those numbers carry across unchanged.
// A negative ai_snd_pitch means no jitter at all.
.float  ai_snd_atten;
.float  ai_snd_pitch;
// A looping sample the class started at spawn - the apache's rotor is the first,
// the turret's spin loop is the obvious second.  Held on the entity so AI_Died can
// stop it: SOUNDFLAG_FORCELOOP runs until something replaces it on that entity
// channel, and a wrecked helicopter still beating its rotor is a worse bug than a
// silent one.  Stopping is a re-emit at volume 0, this codebase's existing idiom
// (AmbientGeneric_Stop, sv_ambient_generic.qc:464-477).
.string ai_snd_loop;
.float  ai_snd_loopchan;
.float  ai_snd_loopatten;	// 0 = ATTN_NORM
.void()  ai_event;		// anim event fired; reads ai_event_code / ai_event_data
// The gun report, split out from the event handler because the RIG and the WEAPON
// are independent: strooper.mdl shares the hgrunt's entire event vocabulary and
// carries a shock rifle, so it needs Grunt_Event and its own bang.  Half-Life
// splits these too - CHGrunt::HandleAnimEvent branches on pev->weapons for the
// sound and calls the same Shoot() either way (hgrunt.cpp:913-937).
.void(entity m) ai_gunsound;
// What this monster leaves on the floor when it dies.  A virtual rather than a
// table in AI_Died because the answer depends on per-class constants (the hgrunt
// loadout bits) that live in the class file and compile after the AI core.
.void(entity m) ai_dropweapon;

float  ai_event_code;
string ai_event_data;

// Per-frame cvar cache, filled by AI_Tick / AI_Init in sv_ai_core.qc.  Declared
// here rather than there because the movement and animation layers compile
// FIRST and read it for their own diagnostics.
float  ai_cached_enable;
float  ai_cached_sight;
float  ai_cached_debug;
float  ai_cached_arcturns;	// sv_ai_arcturns: travel along the BODY, not the wanted heading
float  ai_cached_forcemode;	// sv_ai_forcemode: debug override of ai_movemode
float  ai_cached_engageslots;	// sv_ai_engageslots: shooters per squad, 2 == HL

// ---------------------------------------------------------------------------
// info_bigmomma
// ---------------------------------------------------------------------------
// The gonarch's patrol nodes (bigmomma.cpp:33-96, CInfoBM).  DECLARED HERE, not
// in the file that spawns them: the spawn function belongs with the other HL
// point entities in server/sv_hl_entities.qc, which compiles at :356 - long
// AFTER monsters/mon_bosses.qc at :292, where the walk that READS these keys
// lives.  Fields have to precede both, and sv_ai_defs.qc at :29 is the only
// place that satisfies that for the AI layer.
//
// FIVE OF THE SIX ARE HL's OWN KEY NAMES SPELLED STRAIGHT.  Half-Life overloads
// stock entvars for all of them - radius onto pev->scale, reachdelay onto
// pev->speed, reachtarget onto pev->message, reachsequence onto pev->netname -
// because CInfoBM has nowhere else to put them.  We are not short of fields, and
// an overload here would be actively dangerous: .scale is the RENDER scale in
// this engine and .speed is read by half the brush entities.  Every name below
// was checked to be free tree-wide before it was taken.
// .radius IS SHARED, and was already declared before this patch: sv_env_sound.qc
// re-declares it at :9 for env_sound's own reverb radius, and
// ScriptedSentence_Speaker reads it as the search radius for the 342 corpus
// scripted_sentences that set the key.  Three unrelated classes, one field name,
// because "radius" is what all three spell it in the BSP - which is fine (no
// entity is two of these at once) but is worth stating, since the alternative
// reading is that one of them has quietly taken another's data.  This
// declaration is simply the EARLIEST: sv_env_sound.qc compiles at :202 and the
// gonarch's walk needs the field by :292.
.float  radius;			// arrival tolerance; HL's pev->scale
.float  reachdelay;		// seconds to hold at the node; HL's pev->speed
.string reachtarget;		// fired on arrival; HL's pev->message
.string reachsequence;		// played at the node; HL's pev->netname
.string presequence;		// played BEFORE setting off for the node

// Runtime state for the walk.  HL keeps the first in pev->netname on the MONSTER
// (which is why a map seeds the chain by putting the first node's name in the
// gonarch's own netname key) and the rest in private members and memory bits.
.string ai_bm_next;		// name of the node to head for next
.entity ai_bm_node;		// the node currently being worked; HL's m_hTargetEnt
.float  ai_bm_mem;		// BMMEM_* below; HL's bits_MEMORY_*
.float  ai_bm_nodetime;		// earliest re-attempt after a failed leg; m_nodeTime

const float BMMEM_ADVANCE   = 1;	// bits_MEMORY_ADVANCE_NODE: move on
const float BMMEM_FIRED     = 2;	// bits_MEMORY_FIRED_NODE: reachtarget already went
const float BMMEM_FINISHED  = 4;	// bits_MEMORY_PATH_FINISHED: no node left
// bits_MEMORY_COMPLETED_NODE.  SET AND NEVER READ, here and in Half-Life alike -
// the SDK has exactly two references to it, its own #define and the one Remember()
// in TakeDamage (bigmomma.cpp:163, :594).  Kept because it costs a bit in a field
// that already exists and it is the only record of WHY a stage ended; dropping it
// would make the next reader wonder what the SDK's fourth memory bit did.
const float BMMEM_COMPLETED = 8;	// health gate satisfied, rather than timed out

const float SF_INFOBM_RUN   = 1;	// run rather than walk to this node
const float SF_INFOBM_WAIT  = 2;	// hold here until something else moves her on

// Sven's "Max Attack Range" (sven-coop.fgd:4597 and two siblings), default 1200.
// 202 corpus uses over 31 maps, and it is overwhelmingly a TURRET key -
// monster_miniturret 116, monster_sentry 44, monster_turret 32, squadmaker 10 -
// because a turret's reach is the one thing a mapper genuinely needs to tune per
// placement: the same model guards a corridor and an open yard.  186 of the 202
// write 1200, which is the default and therefore a no-op; the ones that matter
// are the 8 at 3000, the 6 at 1600 and the 2 at 4000.
.float  attackrange;

// ---------------------------------------------------------------------------
//  Deferred ground placement — HL's MonsterInit / StartMonster split
//
//  Half-Life never drops a monster to the floor inside its own spawn function.
//  MonsterInit arms a think (monsters.cpp:2047-2048) and StartMonster does the
//  DROP_TO_FLOOR afterwards (monsters.cpp:2085-2089), so by the time anything
//  asks what is underneath a monster, every brush entity in the map exists.
//
//  Doing it during the lump parse means a monster standing on a func_wall that
//  appears LATER in the .bsp falls straight through it — measured on
//  th_ep1_03's raft (func_wall entity #266 under monster_otis entity #26) and
//  again on th_ep1_04.  Corpus-wide, a few hundred map-placed monsters stand on
//  a brush entity with a higher entity index.
// ---------------------------------------------------------------------------

// Set on a map-placed GROUND body whose drop was deferred; consumed once by
// AI_DeferredPlacePass.
.float  ai_needplace;

// TRUE only while ED_LoadFromFile is still reading the map's entity lump.
// Raised by worldspawn (which is entity 0, so it always spawns first) and
// cleared by AI_DeferredPlacePass at time+0.001 — so a monster created at
// RUNTIME, by a squadmaker or the console, still places immediately and
// synchronously, which is what the squadmaker's .ai_placefail retry needs.
float   ai_lump_parsing;
