//
//  sv_player_weaponstrip.qc  –  player_weaponstrip  (HL/GoldSrc point entity)
//
//  Triggered via Trigger_UseTargets / direct +use.  Flips a global
//  flag that tells PlayerSpawn to drop the player's loadout instead
//  of equipping the configured slot_primary/secondary/melee/utility.
//  Persists for the rest of the map — every subsequent PlayerSpawn
//  (round restart, mid-round respawn, gamemode switch) spawns the
//  player weaponless.  If the activator is a player, also strips
//  them on the spot so the trigger has an immediate effect.
//
//  Reset point: pws_active is a server-VM global, so map change
//  re-initialises it to zero — a fresh map starts with the loadout
//  back at default.
//
//  Keys: targetname only.  Flags: none.  Matches the FGD spec.
//

// Forward decl — defined in sv_player.qc, compiles after this file
// in sv_progs.src.  Used here from .use to strip the activator now,
// and read at PlayerSpawn time to strip the new spawn.
void() W_GiveStartingAmmo;

// Global activation flag — TRUE once any player_weaponstrip has been
// triggered.  Read by PlayerSpawn (sv_player.qc) to short-circuit
// the loadout-give path.
float pws_active;

// Apply the strip to a single player.  Caller should have `p` as a
// live player entity.  Switches `self` for the W_GiveStartingAmmo
// call which reads `self.slot_*` to decide which mags / reserves to
// fill — with all slots zeroed it just clears every ammo field.
void(entity p) PlayerWeaponStrip_Apply =
{
    if (!p) return;
    p.slot_primary   = WEP_NONE;
    p.slot_secondary = WEP_NONE;
    p.slot_melee     = WEP_NONE;
    p.slot_utility   = WEP_NONE;
    p.weapon         = WEP_NONE;
    // The cursors above are only half the inventory now.  Leaving the carry lists
    // populated would leave W_CarryHas approving weapons the strip just removed.
    W_CarryClearAll(p);

    entity saved = self;
    self = p;
    W_GiveStartingAmmo();
    self = saved;
};

void() player_weaponstrip_use =
{
    pws_active = 1;
    if (activator && activator.classname == "player")
        PlayerWeaponStrip_Apply(activator);
};

/*QUAKED player_weaponstrip (.5 .5 0) (-8 -8 -8) (8 8 8)
HL/GoldSrc-style weapon-strip flag.  Presence in the map is enough
to activate it — every PlayerSpawn from map-load onward spawns the
player weaponless (overrides the sv_default_* loadout, the per-mode
defaults, and the survived_round kept-weapons path).  Mappers can
still chain a trigger to it via targetname; the .use callback strips
the activator immediately on top of the global flag (already set at
spawn).

"targetname"  identifier for trigger chains (optional).

Flags: none.
*/
void() player_weaponstrip =
{
    // Activate on spawn.  Without this, mappers had to wire a
    // trigger_auto → player_weaponstrip target chain to flip the
    // global flag, and "drop the entity in the map" did nothing.
    // The user expectation is presence-in-map = active, matching
    // how info_map_parameters and env_fog already behave.
    pws_active    = 1;
    self.use      = player_weaponstrip_use;
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
};
