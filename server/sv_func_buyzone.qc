// ============================================================
//  server/sv_func_buyzone.qc
//  Counter-Strike func_buyzone — a brush volume where players may use
//  the buy menu.  Modelled on trigger_multiple (SOLID_TRIGGER brush +
//  per-tick AABB scan so stationary players keep registering).
//
//  Map key "team" (auto-parsed into .team via sv_defs.qc .float team):
//    -1  no one        0  everyone
//     1  Terrorists -> TEAM_RED      2  Counter-Terrorists -> TEAM_BLUE
//    (the mod's RED plants / BLUE defuses, matching CS T/CT.)
//
//  Gating (Player_CanBuy): mp_buyanywhere overrides everything; if the map
//  has NO func_buyzone the player can buy anywhere (CS "near spawn" fallback);
//  otherwise the player must have overlapped an allowed zone this frame.
// ============================================================

// Window after the last buyzone overlap during which a buy still counts as
// "in zone" — comfortably longer than the 0.1s think so it never flickers.
const float BUYZONE_GRACE = 0.3;

float(entity zone, entity player) BuyZone_AllowsTeam =
{
    if (zone.team == 0) return TRUE;                              // everyone
    if (zone.team == 1) return (player.player_team == TEAM_RED);  // Terrorists
    if (zone.team == 2) return (player.player_team == TEAM_BLUE); // Counter-Terrorists
    return FALSE;                                                 // -1 / other: no one
};

// TRUE if `player` may buy right now (also drives the HUD money colour).
float(entity player) Player_CanBuy =
{
    if (cvar("mp_buyanywhere"))
        return TRUE;
    if (buyzone_count <= 0)
        return TRUE;   // no zones on this map -> unrestricted
    return (time - player.buyzone_time < BUYZONE_GRACE);
};

void() buyzone_touch =
{
    if (other.classname != "player")
        return;
    if (other.health <= 0)
        return;
    if (!BuyZone_AllowsTeam(self, other))
        return;
    other.buyzone_time = time;
};

// Per-tick AABB rescan — the engine only fires .touch on bbox overlap CHANGE,
// so a player standing still inside the zone would stop registering without
// this (same reason trigger_multiple runs a scan).
void() buyzone_think =
{
    self.nextthink = time + 0.1;
    Trigger_FireOnOverlap(self, '1 1 1');
};

/*QUAKED func_buyzone (.3 .9 .3) ?
Counter-Strike buy zone.  Players standing inside (on the allowed team) may
use the buy menu.  Maps with NO func_buyzone let everyone buy anywhere;
mp_buyanywhere 1 also overrides zones.

"team"  -1 no one / 0 everyone / 1 Terrorists(RED) / 2 Counter-Terrorists(BLUE)
*/
void() func_buyzone =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    self.effects  |= EF_NODRAW;      // hide the placeholder brush texture
    self.movetype  = MOVETYPE_NONE;
    self.solid     = SOLID_TRIGGER;
    self.touch     = buyzone_touch;
    self.think     = buyzone_think;
    self.nextthink = time + 0.2;
    buyzone_count  = buyzone_count + 1;
};
