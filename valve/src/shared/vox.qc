/*
 * Copyright (c) 2022-2025 Marco Cawthorne <marco@icculus.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
*/

#ifdef CLIENT
class
VOX:ncTalkMonster
{
public:
	void(void) VOX;
	virtual void(string) SentenceSample;
};

void
VOX::SentenceSample(string sample)
{
	sound(this, CHAN_VOICE, sample, 1.0, ATTN_NONE, 100, SOUNDFLAG_FOLLOW | SOUNDFLAG_NOSPACIALISE);
}

void
VOX:: VOX(void)
{
}

void
Vox_Parse(void)
{
	static VOX voxDelegate;
	string msg = readstring();

	if (!voxDelegate) {
		voxDelegate = spawn(VOX);
	}

	voxDelegate.SentenceFromString(msg);
} 
#endif

#ifdef SERVER
void
Vox_Sentence_Broadcast(string wordsToBroadcast)
{
	if (!STRING_SET(wordsToBroadcast)) {
		return;
	}

	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, EV_CHAT_VOX);
	WriteString(MSG_MULTICAST, wordsToBroadcast);
	multicast(g_vec_null, MULTICAST_ALL_R);
}

void
Vox_Sentence_Single(entity targetClient, string wordsToVOX)
{
	if (!STRING_SET(wordsToVOX)) {
		return;
	}

	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, EV_CHAT_VOX);
	WriteString(MSG_MULTICAST, wordsToVOX);
	msg_entity = targetClient;
	multicast(g_vec_null, MULTICAST_ONE_R);
}
#endif
