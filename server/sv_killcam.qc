// ============================================================
//  server/sv_killcam.qc  -  Server-side killcam camera track.
//
//  The client killcam (client/cl_killcam.qc) replays only the poses the
//  client RECEIVED, so a killer who was outside the victim's PVS during
//  the approach has no buffered frames — the rewind camera holds the last
//  pose it had.  Here the SERVER (which sees everyone, no PVS gating)
//  records every alive player's CAMERA fields each ~30Hz tick into a ring,
//  and on a kill reliably unicasts the KILLER's last ~2.2s to the victim.
//  The victim's CSQC writes them into a separate kc_srv_* track that the
//  rewind prefers for the killer when its own buffer has a gap.
//
//  Only CAMERA + viewmodel fields are needed: the killcam sits at the
//  killer's eye (first-person) and HIDES the killer's body, so we never
//  need their body animation — just origin, view pitch/yaw, weaponstate,
//  weapon id.  That keeps the blob ~13 bytes/frame (~860B per death).
//
//  Safe by construction: the blob is sent only on death, to a now-dead
//  player, describing the PAST — no live/wallhack advantage.  Gated on
//  sv_killcam; the client degrades to its own buffer if it's absent.
//
//  Mirrors sv_lagcomp.qc's `auto` ring pattern (memalloc at load, keeps
//  qwprogs under the 65530 16-bit globals threshold).  See [[fteqcc-compiler-hang]].
// ============================================================

const float KCS_HZ            = 30;     // record rate
const float KCS_RING          = 96;     // ring frames per player — 96/30 = 3.2s (covers the ~2.2s send)
const float KCS_MAX           = 32;     // player slots (1-based entnum)
const float KCS_TOTAL         = 3072;   // KCS_MAX * KCS_RING
const float KCS_SEND_SECONDS  = 2.2;    // history sent on a kill (a touch over the 2.0s default lookback)

// auto (memalloc) — see the file header + sv_lagcomp.qc:51-59.  Indexed [pid*KCS_RING + f].
auto vector kcs_origin [KCS_TOTAL];
auto float  kcs_pitch  [KCS_TOTAL];     // v_angle_x (view pitch, +down)
auto float  kcs_yaw    [KCS_TOTAL];     // v_angle_y (view yaw)
auto float  kcs_wstate [KCS_TOTAL];     // weaponstate (drives the replayed idle/reload viewmodel)
auto float  kcs_wepid  [KCS_TOTAL];     // weapon id (which gun model)
auto float  kcs_valid  [KCS_TOTAL];     // 1 if this slot was recorded in frame f

float kcs_time [KCS_RING];              // per-frame server timestamp (shared by all slots, like the client kc_rtime)
float kcs_head;                         // next ring frame to write
float kcs_last_rec;                     // last record time (KCS_HZ gate)

void() Killcam_SV_Init =
{
	float i;
	for (i = 0; i < KCS_RING; i = i + 1)
		kcs_time[i] = 0;
	for (i = 0; i < KCS_TOTAL; i = i + 1)
		kcs_valid[i] = 0;
	kcs_head = 0;
	kcs_last_rec = 0;
};

// Snapshot every alive player's camera fields into the current ring frame.
// Called each StartFrame (sv_main.qc), self-gated to KCS_HZ.
void() Killcam_SV_RecordAll =
{
	if (!cvar("sv_killcam"))
		return;
	if (time - kcs_last_rec < 1 / KCS_HZ)
		return;
	kcs_last_rec = time;

	float f = kcs_head;
	kcs_time[f] = time;

	float i;
	for (i = 0; i < KCS_MAX; i = i + 1)
		kcs_valid[i * KCS_RING + f] = 0;	// clear the frame (slots with no live player stay invalid)

	entity p = player_chain_head;
	while (p)
	{
		if (!p.is_dead && p.classname == "player")	// bots included — a bot killer needs a track too
		{
			float pid = num_for_edict(p) - 1;
			if (pid >= 0 && pid < KCS_MAX)
			{
				float idx = pid * KCS_RING + f;
				kcs_origin[idx] = p.origin;
				kcs_pitch[idx]  = p.v_angle_x;
				kcs_yaw[idx]    = p.v_angle_y;
				kcs_wstate[idx] = p.weaponstate;
				kcs_wepid[idx]  = p.weapon;
				kcs_valid[idx]  = 1;
			}
		}
		p = p.player_chain_next;
	}

	kcs_head = f + 1;
	if (kcs_head >= KCS_RING)
		kcs_head = 0;
};

// On a kill, reliably unicast the killer's last KCS_SEND_SECONDS of camera
// frames to the victim's client.  Sent as deltas-before-kill (not absolute
// times) so the client anchors them to its own death time, dodging clock skew.
void(entity attacker, entity victim) Killcam_SV_SendTrack =
{
	if (!cvar("sv_killcam"))
		return;
	if (attacker.classname != "player" || attacker == victim)
		return;
	if (clienttype(victim) != CLIENTTYPE_REAL)	// bots have no client to receive the blob (engine-truth guard)
		return;

	float pid = num_for_edict(attacker) - 1;
	if (pid < 0 || pid >= KCS_MAX)
		return;

	float kill_time = time;
	float oldest    = kill_time - KCS_SEND_SECONDS;
	float base      = pid * KCS_RING;
	float j, f;

	// Pass 1: count the killer's valid frames in the send window (need the count first).
	float n = 0;
	for (j = 0; j < KCS_RING; j = j + 1)
	{
		f = (kcs_head + j) % KCS_RING;		// oldest → newest in record order
		if (kcs_time[f] <= 0 || kcs_time[f] < oldest || kcs_time[f] > kill_time)
			continue;
		if (kcs_valid[base + f])
			n = n + 1;
	}
	if (n < 2)				// not enough history (just spawned / sv_killcam just toggled)
		return;
	if (n > 255)
		n = 255;

	// Pass 2: write the blob (oldest → newest).
	msg_entity = victim;
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_KILLCAM_TRACK);
	WriteByte(MSG_MULTICAST, pid + 1);	// 1-based killer entnum (client killcam_killer = atk_slot+1)
	WriteByte(MSG_MULTICAST, n);

	float written = 0;
	for (j = 0; j < KCS_RING && written < n; j = j + 1)
	{
		f = (kcs_head + j) % KCS_RING;
		if (kcs_time[f] <= 0 || kcs_time[f] < oldest || kcs_time[f] > kill_time)
			continue;
		float idx = base + f;
		if (!kcs_valid[idx])
			continue;

		vector o = kcs_origin[idx];
		WriteShort(MSG_MULTICAST, (kill_time - kcs_time[f]) * 1000);	// delta_ms before the kill
		WriteCoord(MSG_MULTICAST, o_x);
		WriteCoord(MSG_MULTICAST, o_y);
		WriteCoord(MSG_MULTICAST, o_z);
		WriteAngle(MSG_MULTICAST, kcs_pitch[idx]);
		WriteAngle(MSG_MULTICAST, kcs_yaw[idx]);
		WriteByte(MSG_MULTICAST, kcs_wstate[idx]);
		WriteByte(MSG_MULTICAST, kcs_wepid[idx]);
		written = written + 1;
	}

	multicast('0 0 0', MULTICAST_ONE_R);	// reliable, to msg_entity, PVS-bypassing
};
