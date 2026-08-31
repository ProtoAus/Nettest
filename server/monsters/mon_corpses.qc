// server/monsters/mon_corpses.qc
// ----------------------------------------------------------------------------
// The posed-body classes: monster_scientist_dead, monster_barney_dead,
// monster_hgrunt_dead, monster_hevsuit_dead, plus monster_sitting_scientist and
// monster_gman, which are alive but do not fight.
//
// 344 corpse placements across the corpus and every one of them is INVISIBLE
// today: with no spawn function they fall through to SV_OnEntityNoSpawnFunction,
// which keeps them as an inert relay with no model at all.  They are set
// dressing that maps lean on heavily - a ransacked lab reads completely
// differently with the bodies missing.
//
// These are NOT AI.  They never think, never take damage and never block.  That
// is Half-Life's behaviour too: CDeadScientist and friends are CBaseMonster
// subclasses whose Spawn() sets pev->deadflag = DEAD_DEAD, movetype NONE, and
// solid NOT.  So they route through Monster_Build like everything else, but
// stay out of the AI registry entirely.
//
// POSE.  Half-Life picks the corpse's animation by NAME from a per-class table
// indexed by the `pose` key, not by sequence number:
//
//   CDeadScientist  lying_on_back, lying_on_stomach, dead_sitting, dead_hang,
//                   dead_table1, dead_table2, dead_table3
//   CDeadBarney     lying_on_back, lying_on_side, lying_on_stomach
//   CDeadHGrunt     deadstomach, deadside, deadsitting
//   CDeadHEV        deadback, deadsitting, deadstomach, deadtable
//
// Verified against the shipped models: barney.mdl 35/36/37 and hgrunt.mdl
// 46/47/48 and player.mdl 177/178/179 resolve exactly as above.
//
// Most Sven maps write BOTH `pose` and a raw `sequence`.  HL resolves the pose
// unconditionally in Spawn(), so pose wins where it is present - matched here,
// with `sequence` as the fallback for the maps that only supply that.
// ----------------------------------------------------------------------------

.float pose;		// HL corpse pose selector, indexes the name tables below

// Resolve one name from a class's pose table.  Returning "" means "this class
// has no table entry for that index", and the caller falls back to `sequence`.
string(string cls, float p) Corpse_PoseName =
{
    if (cls == "monster_barney_dead")
    {
        if (p <= 0)	return "lying_on_back";
        if (p == 1)	return "lying_on_side";
        return "lying_on_stomach";
    }
    if (cls == "monster_hgrunt_dead")
    {
        if (p <= 0)	return "deadstomach";
        if (p == 1)	return "deadside";
        return "deadsitting";
    }
    if (cls == "monster_hevsuit_dead")
    {
        if (p <= 0)	return "deadback";
        if (p == 1)	return "deadsitting";
        if (p == 2)	return "deadstomach";
        return "deadtable";
    }
    // scientist
    if (p <= 0)	return "lying_on_back";
    if (p == 1)	return "lying_on_stomach";
    if (p == 2)	return "dead_sitting";
    if (p == 3)	return "dead_hang";		// absent from scientist.mdl; falls back
    if (p == 4)	return "dead_table1";
    if (p == 5)	return "dead_table2";
    return "dead_table3";
};

void() Corpse_Build =
{
    // Monster_Build gives us the model (from the key or the class default), the
    // hull, the render keys and the angle fold.  FALSE = not solid.
    Monster_Build(FALSE);

    // Belt and braces: a corpse must never be shootable or block a corridor,
    // whatever the map's notsolid key said.
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    self.takedamage = DAMAGE_NO;

    if (self.modelindex <= 0)
        return;				// no model resolved; nothing to pose

    // Pose by name first, exactly as HL does.
    float seq = -1;
    if (self.pose > 0 || self.sequence <= 0)
    {
        string nm = Corpse_PoseName(self.classname, self.pose);
        if (nm != "")
            seq = frameforname(self.modelindex, nm);
    }

    // Fall back to the raw sequence key.  Range-check with modelframecount,
    // never frameduration: HLMDL_FrameInfoForNum silently clamps an
    // out-of-range sequence to 0 and returns a plausible number for it.
    if (seq < 0 && self.sequence > 0)
    {
        float nseq = modelframecount(self.modelindex);
        if (self.sequence < nseq)
            seq = self.sequence;
    }

    if (seq >= 0)
    {
        self.frame = seq;
        // Pose clock, same reason as sv_monsters.qc's sequence override: this
        // writes .frame without going through AI_ApplySequence, and
        // W_MonstersExpandHitboxes reads .ai_seqstart to pose the server's
        // hitboxes.  A corpse is static, so the value only has to be sane.
        self.ai_seqstart = time;
    }

    if (cvar("sv_debug_monsters"))
        dprint(sprintf("[corpse] %s model=%s pose=%g sequence=%g -> frame=%g\n",
                       self.classname, self.model, self.pose, self.sequence, self.frame));
};

/*QUAKED monster_scientist_dead (.4 .3 .2) (-16 -16 0) (16 16 72)
Dead scientist. Set dressing — no AI, not solid, cannot be damaged.
"pose"      0 back, 1 stomach, 2 sitting, 3 hang, 4-6 table variants
"sequence"  explicit sequence index, used when no pose is given
"body"      bodygroup (head/coat variant)
*/
void() monster_scientist_dead = { Corpse_Build(); };

/*QUAKED monster_barney_dead (.4 .3 .2) (-16 -16 0) (16 16 72)
Dead Barney.  "pose" 0 back, 1 side, 2 stomach.
*/
void() monster_barney_dead   = { Corpse_Build(); };

/*QUAKED monster_hgrunt_dead (.4 .3 .2) (-16 -16 0) (16 16 72)
Dead HECU grunt.  "pose" 0 stomach, 1 side, 2 sitting.
*/
void() monster_hgrunt_dead   = { Corpse_Build(); };

/*QUAKED monster_hevsuit_dead (.4 .3 .2) (-16 -16 0) (16 16 72)
Dead HEV-suited scientist.  Uses models/player.mdl — sequences 177..180 are its
corpse poses.  "pose" 0 back, 1 sitting, 2 stomach, 3 table.
*/
void() monster_hevsuit_dead  = { Corpse_Build(); };

/*QUAKED monster_sitting_scientist (.4 .3 .2) (-16 -16 0) (16 16 72)
Seated scientist.  Alive in Half-Life and able to talk, but with no AI of its
own beyond sitting; the maps that place it use it as scenery and as a
scripted_sequence target, both of which work with a posed body.  All ten
placements in the corpus supply "sequence" "73" themselves.
*/
void() monster_sitting_scientist = { Corpse_Build(); };

/*QUAKED monster_gman (.4 .3 .2) (-16 -16 0) (16 16 72)
The G-Man.  Invulnerable, unarmed, and in Half-Life he only ever moves under
scripted_sequence control — gman.mdl carries just IDLE and WALK activities, no
attacks of any kind.  Built as a body that scripts can address; every one of the
36 placements in the corpus carries a targetname, which is the whole point.
*/
void() monster_gman =
{
    Monster_Build(FALSE);
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    self.takedamage = DAMAGE_NO;	// CGMan is explicitly invulnerable
};
