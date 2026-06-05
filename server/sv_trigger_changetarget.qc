//
// sv_trigger_changetarget.qc — HL/GoldSrc trigger_changetarget point entity
//
// When triggered, rewrites the .target field of every entity matching
// self.target.  Used to switch what an env_beam / env_laser /
// trigger_camera / func_train points at without rebuilding the BSP.
//
// Keys:
//   target          — targetname of the entity whose .target field
//                     will be rewritten.
//   m_iszNewTarget  — the new value to write into that entity's
//                     .target field.
//
// Behavioural divergence from HL (the user explicitly preferred better
// over bug-compat):
//   - HL rewrites only the FIRST matching entity.  We rewrite ALL of
//     them — useful when the mapper has duplicated names intentionally
//     (e.g. all path_corner branches at a junction).
//   - HL's "Delay before trigger" and "KillTarget" keys are documented
//     as having no effect in HL.  We don't read them.
//

.string m_iszNewTarget;

void() trigger_changetarget_use =
{
    if (self.target == "")
        return;

    // Walk every matching entity via findchain so the loop body can
    // call back into find() without disturbing iteration state.
    entity e = findchain(targetname, self.target);
    while (e)
    {
        e.target = self.m_iszNewTarget;
        e = e.chain;
    }
};

/*QUAKED trigger_changetarget (1 .5 .2) (-8 -8 -8) (8 8 8)
Changes the .target field of every entity matching `target` to the
value in `m_iszNewTarget`.

"target"         Targetname of the entity (or entities) to retarget.
"m_iszNewTarget" New target value to write.
*/
void() trigger_changetarget =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    self.use      = trigger_changetarget_use;
};
