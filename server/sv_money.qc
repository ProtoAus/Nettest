// ============================================================
//  server/sv_money.qc
//  CS-style economy: cash award helpers, round-end payout, Kevlar armor
//  absorption, and the Equipment buy-item handlers (Kevlar / helmet /
//  defuse kit).  Included early (before sv_weapons.qc) so PlayerKilled,
//  W_ApplyDamage, sv_main.qc and sv_player.qc can all call these.
//
//  Fields (.money/.armor/.has_helmet/.has_defusekit/.money_started) and
//  the round globals live in sv_customdefs.qc; stat ids + TEAM_/ROUND_PHASE_
//  constants in sh_customdefs.qc; BUYITEM_* in sh_weapon_manifest.qc.
// ============================================================

const float ARMOR_FULL   = 100;
const float ARMOR_ABSORB = 0.5;   // fraction of bullet damage Kevlar soaks

// --- Cash ----------------------------------------------------

// Clamp-add cash (negative = a purchase deduction).  Bounded [0, mp_cashmax].
void(entity player, float amount) AddMoney =
{
    float mx = cvar("mp_cashmax");
    if (mx <= 0) mx = 16000;
    player.money = bound(0, player.money + amount, mx);
};

// Grant starting cash once, on the player's first real team join.
void(entity player) Money_EnsureStart =
{
    if (player.money_started)
        return;
    player.money_started = 1;
    player.money = bound(0, cvar("mp_cashstart"), cvar("mp_cashmax"));
};

// Reset everyone to starting cash (call at MATCH start, NOT per round).
void() Money_ResetMatch =
{
    entity e;
    for (e = world; (e = find(e, classname, "player")); )
    {
        e.money_started = 1;
        e.money = bound(0, cvar("mp_cashstart"), cvar("mp_cashmax"));
    }
};

// Round-end payout: winners +mp_cashwin, losers +mp_cashlose.  A draw
// (round_winning_team neither BLUE nor RED) pays nobody.
void() Money_AwardRoundEnd =
{
    entity e;
    if (round_winning_team != TEAM_BLUE && round_winning_team != TEAM_RED)
        return;
    for (e = world; (e = find(e, classname, "player")); )
    {
        if (e.player_team != TEAM_BLUE && e.player_team != TEAM_RED)
            continue;
        float won    = (e.player_team == round_winning_team) ? 1 : 0;
        float amount = won ? cvar("mp_cashwin") : cvar("mp_cashlose");
        AddMoney(e, amount);

        // Dopamine round-cash popup — unicast; CSQC shows "+$amount"
        // under the win/lose banner + plays cashregister.
        msg_entity = e;
        WriteByte(MSG_ONE, SVC_CGAMEPACKET);
        WriteByte(MSG_ONE, CSQC_EVENT_ROUND_REWARD);
        WriteShort(MSG_ONE, amount);
        WriteByte(MSG_ONE, won);
    }
};

// Fire the round-end payout exactly once on the edge into ROUND_END.
// Called every frame from SV_StartFrame; latch lives in sv_customdefs.qc.
void() Money_CheckRoundAward =
{
    if (round_phase == ROUND_PHASE_ROUND_END
        && money_last_round_phase != ROUND_PHASE_ROUND_END)
        Money_AwardRoundEnd();
    money_last_round_phase = round_phase;
};

// --- Armor ---------------------------------------------------

// Returns the damage that should reach health after Kevlar absorption,
// depleting target.armor.  CS-style: ~half to health, ~half to armor; once
// armor is gone the remainder hits health.  A helmet halves an incoming
// HEADSHOT first (the 4x head multiplier is already baked into `dmg`).
float(entity target, float dmg, float isHeadshot) Armor_Absorb =
{
    float to_armor;
    float to_health;

    if (isHeadshot && target.has_helmet)
        dmg = dmg * 0.5;

    if (target.armor <= 0)
        return dmg;

    to_armor  = dmg * ARMOR_ABSORB;
    to_health = dmg - to_armor;
    if (to_armor > target.armor)
    {
        to_health = to_health + (to_armor - target.armor);
        to_armor  = target.armor;
    }
    target.armor = target.armor - to_armor;
    return to_health;
};

// --- Equipment buy items (armor / defuse kit) ----------------

// Apply a non-weapon Equipment item (cost already deducted by the caller).
// Returns TRUE if applied.
float(entity player, float item) BuyItem_Apply =
{
    switch (item)
    {
    case BUYITEM_KEVLAR:
        player.armor = ARMOR_FULL;
        player.has_helmet = 0;
        return TRUE;
    case BUYITEM_KEVLARHELM:
        player.armor = ARMOR_FULL;
        player.has_helmet = 1;
        return TRUE;
    case BUYITEM_DEFUSEKIT:
        player.has_defusekit = 1;
        return TRUE;
    }
    return FALSE;
};
