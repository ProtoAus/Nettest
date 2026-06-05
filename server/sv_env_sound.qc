//
// sv_env_sound.qc - GoldSrc env_sound room/reverb trigger point
//
// The server only owns mapper state and replication.  The actual audio
// listener/reverb selection lives in CSQC because FTE exposes SetListener
// and setup_reverb only to the client VM.
//

.float radius;
.float roomtype;

float(entity playerent, float changedflags) env_sound_SendEntity =
{
    WriteByte(MSG_ENTITY, CSQC_ENT_ENV_SOUND);
    WriteCoord(MSG_ENTITY, self.origin_x);
    WriteCoord(MSG_ENTITY, self.origin_y);
    WriteCoord(MSG_ENTITY, self.origin_z);
    WriteCoord(MSG_ENTITY, self.radius);
    WriteByte(MSG_ENTITY, self.roomtype);
    return TRUE;
};

/*QUAKED env_sound (.4 .8 1) (-8 -8 -8) (8 8 8)
GoldSrc room/reverb trigger.  When the listener enters radius, the
selected room type is applied and remains active until another env_sound
changes it.

"radius"    trigger radius in quake units (default 128)
"roomtype"  GoldSrc room type 0..28
*/
void() env_sound =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;

    if (self.radius <= 0)
        self.radius = 128;

    self.roomtype = floor(self.roomtype + 0.5);
    if (self.roomtype < 0)  self.roomtype = 0;
    if (self.roomtype > 28) self.roomtype = 28;

    // Reverb zones need to be known even when the point is not in the
    // current render PVS; GoldSrc's effect is listener-area state, not a
    // visible/audio-emitting entity.
    self.pvsflags = PVSF_IGNOREPVS | PVSF_NOREMOVE;
    self.SendEntity = env_sound_SendEntity;
    self.SendFlags = 1;
};
