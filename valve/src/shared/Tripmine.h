/*
 * Copyright (c) 2016-2021 Marco Cawthorne <marco@icculus.org>
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

/* MONSTER_TRIPMINE SEGMENT 
 * 
 * Because not being able to place it around levels would be boring.
 * Some maps, such as subtransit and a few singleplayer chapters have this. */

class hlTripmine:ncSurfacePropEntity
{
	void hlTripmine(void);

#ifdef SERVER
	virtual void Respawn(void);
	virtual void Spawned(void);
	virtual void Ready(void);
	virtual void Pain(entity, entity, int, vector, vector, int);
	virtual void Death(entity, entity, int, vector, vector, int);
	virtual float SendEntity(entity, float);
#endif

#ifdef CLIENT
	virtual float predraw(void);
	virtual void ReceiveEntity(float, float);
#endif

private:

	vector m_vecEndPos;

#ifdef CLIENT
	int m_iActive;
#endif
};

enum
{
	TRIPMINE_IDLE1,
	TRIPMINE_IDLE2,
	TRIPMINE_FIRE1,
	TRIPMINE_FIRE2,
	TRIPMINE_FIDGET,
	TRIPMINE_HOLSTER,
	TRIPMINE_DRAW,
	TRIPMINE_WORLD,
	TRIPMINE_GROUND,
};
