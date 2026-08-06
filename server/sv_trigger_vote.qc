//
//  sv_trigger_vote.qc  —  Sven Co-op trigger_vote
//
//  Throws a yes/no question at the players, waits `frags` seconds, then fires
//  one of three target chains depending on the outcome.
//
//  Tallying is server-side over player_chain_head and bot-filtered.  The
//  obvious client-side alternative — count `maxclients` — is wrong: that range
//  includes disconnected slot gaps and bots, so the percentage would be
//  computed against a denominator nobody can actually vote with.
//
//  Non-voters are IGNORED, not counted as "no".  That is Sven's rule and it
//  matters: with 6 players and 2 voting yes, 1 no, the result is 66% (pass at
//  the usual 80%? no) rather than 33%.  Getting this backwards makes every
//  vote on a populated server fail.
//

void(entity caller, entity who, float useType) SUB_UseTargets;    // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;          // sv_triggers.qc

// Keys.  Sven overloads some odd fields for this entity — `frags` is the
// duration and `health` is the pass percentage — so they are aliased here
// rather than renamed, because the map is what it is.
.string m_iszyesstring;
.string m_isznostring;
// .message (question), .frags (seconds), .health (pass %), .target (yes),
// .netname (no), .noise (nobody voted) are all already declared elsewhere.

// Per-player answer: 0 = hasn't voted, 1 = yes, 2 = no.  Stamped with the
// vote serial so a stale answer from the previous vote can't leak into this
// one (a player who answers as the timer expires would otherwise arrive after
// the reset).
.float vote_answer;
.float vote_answer_serial;

entity vote_active;             // the trigger_vote currently running, if any
float  vote_serial;
float  vote_end_time;

void() Vote_ResetState =
{
    vote_active   = world;
    vote_end_time = 0;
    // vote_serial deliberately NOT reset — it only ever has to be unique
    // within a session, and bumping across a map change is free insurance
    // against a late answer from the previous map.
};

// Count real, connected, alive-or-dead players.  Bots can't answer a prompt,
// so including them would make any vote unwinnable on a bot-filled server.
float() Vote_EligibleCount =
{
    float n = 0;
    entity p = player_chain_head;
    while (p)
    {
        if (p.classname == "player" && clienttype(p) == CLIENTTYPE_REAL)
            n = n + 1;
        p = p.player_chain_next;
    }
    return n;
};

void(float yes, float no, float eligible) Vote_BroadcastTally =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_VOTE_UPDATE);
    WriteByte(MSG_MULTICAST, bound(0, yes, 255));
    WriteByte(MSG_MULTICAST, bound(0, no, 255));
    WriteByte(MSG_MULTICAST, bound(0, eligible, 255));
    multicast('0 0 0', MULTICAST_ALL_R);
};

void() Vote_Tally =
{
    float yes = 0, no = 0;
    entity p = player_chain_head;
    while (p)
    {
        if (p.classname == "player" && p.vote_answer_serial == vote_serial)
        {
            if (p.vote_answer == 1) yes = yes + 1;
            else if (p.vote_answer == 2) no = no + 1;
        }
        p = p.player_chain_next;
    }
    Vote_BroadcastTally(yes, no, Vote_EligibleCount());
};

void(float outcome) Vote_BroadcastEnd =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_VOTE_END);
    WriteByte(MSG_MULTICAST, outcome);
    multicast('0 0 0', MULTICAST_ALL_R);
};

void() Vote_Finish =
{
    entity v = vote_active;
    if (!v)
        return;

    float yes = 0, no = 0;
    entity p = player_chain_head;
    while (p)
    {
        if (p.classname == "player" && p.vote_answer_serial == vote_serial)
        {
            if (p.vote_answer == 1) yes = yes + 1;
            else if (p.vote_answer == 2) no = no + 1;
        }
        p = p.player_chain_next;
    }

    float voted = yes + no;
    float need  = v.health;
    if (need <= 0) need = 50;

    string chain;
    float outcome;

    if (voted <= 0)
    {
        // Nobody answered — its own outcome with its own target, distinct
        // from a failed vote.  Sven calls it "No vote target".
        outcome = 2;
        chain   = v.noise;
    }
    else
    {
        float pct = (yes * 100) / voted;
        if (pct >= need)
        {
            outcome = 1;
            chain   = v.target;
        }
        else
        {
            outcome = 0;
            chain   = v.netname;
        }
    }

    bprint(PRINT_HIGH, sprintf("Vote result: %g yes / %g no — %s\n",
                               yes, no,
                               outcome == 1 ? "passed" :
                               (outcome == 2 ? "nobody voted" : "failed")));

    Vote_BroadcastEnd(outcome);
    vote_active   = world;
    vote_end_time = 0;

    if (chain != "" && chain != __NULL__)
    {
        entity relay = spawn();
        relay.classname = "vote_fire";
        relay.target    = chain;
        // "Unlike other entities, trigger_vote sends 'On' output instead of
        // 'Toggle'" — a toggle here would close a door the yes-branch was
        // supposed to open, on a map that fires the same target twice.
        SUB_UseTargets(relay, world, USE_ON);
        remove(relay);
    }
};

// Driven from StartFrame (sv_main.qc) rather than a think on the entity, so a
// vote survives its trigger_vote being killtargeted mid-vote.
void() Vote_Frame =
{
    if (!vote_active)
        return;
    if (time >= vote_end_time)
        Vote_Finish();
};

void() trigger_vote_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    // One at a time.  Rejecting rather than queueing matches how the maps
    // actually use this — pizza_ya_san1 chains its two votes, firing the
    // second only from the first's result.
    if (vote_active)
        return;

    string q = self.message;
    if (q == "" || q == __NULL__)
        q = "Vote?";

    float dur = self.frags;
    if (dur <= 0)  dur = 20;
    if (dur > 255) dur = 255;       // the wire byte, and nobody wants a 5-min vote

    float need = self.health;
    if (need <= 0)  need = 50;
    if (need > 100) need = 100;

    vote_serial   = vote_serial + 1;
    vote_active   = self;
    vote_end_time = time + dur;

    string yeslabel = self.m_iszyesstring;
    string nolabel  = self.m_isznostring;
    if (yeslabel == "" || yeslabel == __NULL__) yeslabel = "Yes";
    if (nolabel  == "" || nolabel  == __NULL__) nolabel  = "No";

    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_VOTE_START);
    WriteString(MSG_MULTICAST, q);
    WriteString(MSG_MULTICAST, yeslabel);
    WriteString(MSG_MULTICAST, nolabel);
    WriteByte(MSG_MULTICAST, dur);
    WriteByte(MSG_MULTICAST, need);
    // Reliable: a client that misses the start packet shows no prompt and can
    // never answer, which silently skews the result against whatever they
    // would have picked.
    multicast('0 0 0', MULTICAST_ALL_R);

    Vote_Tally();       // publish the zeroed tally + eligible count immediately

    bprint(PRINT_HIGH, sprintf("Vote started: %s (%g seconds, %g%% to pass)\n",
                               q, dur, need));
};

/*QUAKED trigger_vote (.2 .7 .3) (-8 -8 -8) (8 8 8)
Sven Co-op player vote.  Shows a yes/no prompt for `frags` seconds, then fires
one of three chains.  Answered with F1 / F2 (or `vote yes` / `vote no`), which
do NOT take the mouse cursor — players can keep moving and shooting.

"message"        the question
"frags"          seconds to vote
"health"         percentage of those who VOTED that must say yes
"target"         fired when the vote passes  (sent as USE_ON, not toggle)
"netname"        fired when the vote fails
"noise"          fired when nobody voted at all
"m_iszYesString" / "m_iszNoString"   override the button labels
*/
void() trigger_vote =
{
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    self.modelindex = 0;
    self.use        = trigger_vote_use;
};

// ---------------------------------------------------------------------------
//  CSQC -> server answer.  `self` is the answering player (engine-set).
// ---------------------------------------------------------------------------
void(float choice) CSEv_vote_f =
{
    if (self.classname != "player")
        return;
    if (!vote_active)
        return;
    if (choice != 1 && choice != 2)
        return;

    // Re-answering is allowed (you can change your mind while the clock runs)
    // but must not double-count, hence storing the answer rather than a tally.
    self.vote_answer        = choice;
    self.vote_answer_serial = vote_serial;

    Vote_Tally();
};
