// ============================================================
//  shared/weapons/sh_wpn_melee.qc  -  Fists (unarmed melee)
//
//  Slot  : SLOT_MELEE — INTRINSIC.  Always present when no other
//          melee is equipped; not droppable; not in menus.
//  Fire  : random punch       — primary  (+attack)
//          pool: punch_left, punch_right, punch_right2, uppercut
//          cooldown 300 ms; trace + single sound at 50 ms.
//  Alt   : random kick        — alt-fire (+attack2)
//          pool: kick, sidekick, spinkick (backkick intentionally out)
//          cooldown 500 ms; trace + single sound at 50 ms.
//  Spec  : block_low flourish — impulse 7 (no damage, just visual)
//
//  Sound rule (single sound per swing, at trace moment):
//      punch + air      → miss1.wav
//      punch + anything → punchhit1.wav   (same sound for player and wall)
//      kick  + air      → miss1.wav
//      kick  + anything → kickhit1.wav
//      block special    → block1.wav at fire time
//
//  Impact effects:
//      NO bullethole decals
//      NO sparks / particle dust
//      Small smoke puff (MS_SpawnOnePuff) at the contact point
//
//  Client-instant rule:
//      CSQC predicts the trace + sound + smoke locally at csqc_pred_time
//      + 50 ms.  Server runs the authoritative trace 50 ms after its
//      own input tick and broadcasts the sound with dimension_send
//      masked to exclude the attacker (so they don't hear a ping-
//      delayed echo).  At 300 ms ping the local hit feedback fires
//      ~50 ms after the click; the server's broadcast never reaches
//      the attacker.
//
//  Sequence indices (matches the user-provided $sequence list):
//      0  idle
//      1  draw
//      2  punch_left
//      3  punch_right
//      4  block_low
//      5  kick
//      6  sidekick
//      7  uppercut
//      8  spinkick
//      9  backkick      (unused — explicitly excluded from kick pool)
//     10  punch_right2
// ============================================================

const float MELEE_PUNCH_RANGE   = 64;
const float MELEE_PUNCH_DAMAGE  = 12;
const float MELEE_KICK_RANGE    = 80;
const float MELEE_KICK_DAMAGE   = 22;

// Cooldowns — fixed timings, not tied to anim length.  Player can
// re-fire mid-anim and the new sequence replaces the old; the visual
// is short enough that interrupting feels right for a combo.
const float MELEE_PUNCH_COOLDOWN = 0.30;
const float MELEE_KICK_COOLDOWN  = 0.50;
const float MELEE_BLOCK_COOLDOWN = 0.50;

// Trace fires at exactly this elapsed time after the input — sound,
// hit registration, and smoke puff all happen at this single moment.
const float MELEE_HIT_TIME       = 0.05;

// --- Sequence indices ---
const float MELEE_SEQ_IDLE          = 0;
const float MELEE_SEQ_DRAW          = 1;
const float MELEE_SEQ_PUNCH_LEFT    = 2;
const float MELEE_SEQ_PUNCH_RIGHT   = 3;
const float MELEE_SEQ_BLOCK_LOW     = 4;
const float MELEE_SEQ_KICK          = 5;
const float MELEE_SEQ_SIDEKICK      = 6;
const float MELEE_SEQ_UPPERCUT      = 7;
const float MELEE_SEQ_SPINKICK      = 8;
const float MELEE_SEQ_BACKKICK      = 9;
const float MELEE_SEQ_PUNCH_RIGHT2  = 10;

const float MELEE_FRAME_INTERVAL = 0.05;

const string MELEE_VIEWMODEL    = "models/weapons/wpn_melee/v_melee.mdl";
const string MELEE_DEPLOY_SOUND = "";
const string MELEE_DISPLAY_NAME = "FISTS";

const string MELEE_SND_MISS      = "sounds/weapons/wpn_melee/miss1.wav";
const string MELEE_SND_PUNCH_HIT = "sounds/weapons/wpn_melee/punchhit1.wav";
const string MELEE_SND_KICK_HIT  = "sounds/weapons/wpn_melee/kickhit1.wav";
const string MELEE_SND_BLOCK     = "sounds/weapons/wpn_melee/block1.wav";

// Per-entity stage tracker — fires the hit event exactly once per
// action.  Bumped to 1 after the trace so a reconcile replay can't
// double-fire.
.float melee_snd_stage;

// Impact visuals (client-side prediction):
//   player hit  → Impact_SpawnParticles with IMPACT_MAT_FLESH_LETHAL
//                 (blood spray, no smoke)
//   wall hit    → Impact_SpawnSmokeOnly (smoke puff only, no sparks)
//   air         → nothing visual
#ifdef CSQC
void(vector pos, vector normal) Impact_SpawnSmokeOnly;
void(vector pos, vector normal, float mat) Impact_SpawnParticles;
float() Impact_ParticleOffset;
#endif

// ============================================================
//  SHARED — sequence picks
// ============================================================

// Punches: 4 variants, even split.  uppercut is in here per the
// user's listing (it's a punch motion, not a kick).
float() SH_MeleePickPunchSeq =
{
    float h = SH_SpreadHash(self.wep_action_id);
    if (h < 0.25) return MELEE_SEQ_PUNCH_LEFT;
    if (h < 0.50) return MELEE_SEQ_PUNCH_RIGHT;
    if (h < 0.75) return MELEE_SEQ_PUNCH_RIGHT2;
    return MELEE_SEQ_UPPERCUT;
};

// Kicks: 3 variants.  backkick deliberately excluded — the user
// asked for it out of the random pool.
float() SH_MeleePickKickSeq =
{
    float h = SH_SpreadHash(self.wep_action_id);
    if (h < 0.333) return MELEE_SEQ_KICK;
    if (h < 0.666) return MELEE_SEQ_SIDEKICK;
    return MELEE_SEQ_SPINKICK;
};

float(float seq) SH_MeleeSeqIsKick =
{
    return (seq == MELEE_SEQ_KICK
         || seq == MELEE_SEQ_SIDEKICK
         || seq == MELEE_SEQ_SPINKICK);
};

// ============================================================
//  SHARED — state machine + try gates
// ============================================================

float(float now) SH_MeleeTickState =
{
    return SH_SeqDrivenTickState(now, MELEE_VIEWMODEL);
};

// pick_kick = 1 → kick pool + 500 ms cooldown, 0 → punch pool + 300 ms.
// Returns 1 on action started, 0 on cooldown / draw block.
float(float now, float pick_kick) SH_MeleeTryStrike =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;

    self.wep_action_id += 1;

    float seq;
    float cooldown;
    if (pick_kick)
    {
        seq = SH_MeleePickKickSeq();
        cooldown = MELEE_KICK_COOLDOWN;
    }
    else
    {
        seq = SH_MeleePickPunchSeq();
        cooldown = MELEE_PUNCH_COOLDOWN;
    }

    self.weaponstate     = WS_FIRE;
    self.weaponframe     = seq;
    self.wep_anim_start  = now;
    self.attack_finished = now + cooldown;
#ifdef CSQC
    self.csqc_fire_guard = now + cooldown;
#endif
    return 1;
};

float(float now) SH_MeleeTryBlock =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;

    self.wep_action_id += 1;

    self.weaponstate     = WS_SPECIAL;
    self.weaponframe     = MELEE_SEQ_BLOCK_LOW;
    self.wep_anim_start  = now;
    self.attack_finished = now + MELEE_BLOCK_COOLDOWN;
#ifdef CSQC
    self.csqc_fire_guard = now + MELEE_BLOCK_COOLDOWN;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void() weapon_touch;
void() PlayerModelPlayPrimaryAttack;

void() W_MeleeEnterIdle;
void() W_MeleeStrike;
void() W_MeleeFire;
void() W_MeleeAltFire;
void() W_MeleeSpecial;
void() W_MeleeFrame;
void() W_MeleeEquip;

void(entity receiver) W_MeleePickupCopy =
{
};

// Fists are intrinsic — never dropped.  slot_melee_drop is wired to
// __NULL__ in the player slot dispatch (sv_player.qc), so impulse 8
// silently does nothing.  W_DropAllWeaponsOnDeath skips this too.
// This stub remains for any external caller that does a defensive
// drop_func(); removes any spuriously-targeted entity.
void() W_MeleeDrop =
{
    entity tgt = weapon_drop_target;
    if (tgt && tgt != self)
        remove(tgt);
};

void() W_MeleeEnterIdle =
{
    self.weaponframe    = MELEE_SEQ_IDLE;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe  = 0;
    self.melee_snd_stage = 0;
};

void() W_MeleeEquip =
{
    self.weaponmodel               = MELEE_VIEWMODEL;
    self.weapon_name               = MELEE_DISPLAY_NAME;
    self.weapon_draw_start_frame   = MELEE_SEQ_DRAW;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_MELEE;
    self.altfire                   = W_MeleeAltFire;
    self.altrelease                = __NULL__;
    self.shoot                     = W_MeleeStrike;
    self.fire                      = W_MeleeFire;
    self.reload                    = __NULL__;
    self.special                   = W_MeleeSpecial;
    self.wepframe                  = W_MeleeFrame;
    self.weaponstate               = WS_DRAW;
    self.wep_action_id            += 1;
    self.wep_anim_start            = time;
    self.weaponframe               = MELEE_SEQ_DRAW;
    self.wep_nextframe             = time + MELEE_FRAME_INTERVAL;
    self.melee_snd_stage           = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

// Authoritative trace.  Single sound choice based on (kick?, hit?).
// Damage applied for player hits.  Server does NOT spawn any visual
// impact effect (no bullethole, no light, no smoke) — the local
// player's CSQC predicts the smoke; other players don't see the
// melee impact visual.  Sound is broadcast with dimension_send
// masked to exclude the attacker (their CSQC played localsound).
void() W_MeleeStrike =
{
    float is_kick   = SH_MeleeSeqIsKick(self.weaponframe);
    float range     = is_kick ? MELEE_KICK_RANGE   : MELEE_PUNCH_RANGE;
    float dmg       = is_kick ? MELEE_KICK_DAMAGE  : MELEE_PUNCH_DAMAGE;
    string hit_snd  = is_kick ? MELEE_SND_KICK_HIT : MELEE_SND_PUNCH_HIT;

    vector src;
    vector end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + (v_forward * range);
    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    float saved_dim = dimension_send;
    dimension_send  = dimension_send & ~self.dimension_seen;

    if (trace_fraction >= 1.0)
    {
        // Pure air swing — single miss sound, no damage, no effect.
        sound(self, CHAN_AUTO, MELEE_SND_MISS, 1.0, ATTN_NORM);
        dimension_send = saved_dim;
        return;
    }

    // Hit something.  Same hit sound for player vs wall — only
    // punch-vs-kick distinguishes which sound plays.
    sound(self, CHAN_AUTO, hit_snd, 1.0, ATTN_NORM);
    dimension_send = saved_dim;

    if (W_CanDamageTarget(trace_ent))
    {
        W_DebugImpact(trace_endpos, dmg, W_BoneToHitgroup(trace_bone_id));
        // Defer player damage to the attacker's client hitclaim when
        // they're predicting hits (default).  Without this, every
        // melee swing applied damage TWICE — once here, once via
        // SV_HandleHitclaim — leaving targets with ~half the HP they
        // should.  Mirrors the bullet-weapon pattern in
        // sh_weapon_standard.qc:558.  Non-player damage (breakables
        // / props) is unconditional — the breakclaim defer is handled
        // inside W_ApplyDamage itself.
        float defer_player = (trace_ent.classname == "player")
                             && W_ShouldDeferToClaim(self);
        if (!defer_player)
            W_ApplyDamage(self, trace_ent, dmg);
        return;
    }

    // Hit wall / breakable / prop — apply a soft push (so wooden
    // boards and physics props react) but no decal multicast.
    PhysProp_TryPushFromTrace(v_forward, dmg);
};

// Fire (+attack) — random punch.  No sound at fire time — the
// single per-swing sound plays from W_MeleeFrame at MELEE_HIT_TIME.
void() W_MeleeFire =
{
    if (!SH_MeleeTryStrike(time, 0))
        return;
    self.wep_nextframe   = time + MELEE_FRAME_INTERVAL;
    self.melee_snd_stage = 0;
    PlayerModelPlayPrimaryAttack();
};

// Alt-fire (+attack2) — random kick.  Same single-sound pattern.
void() W_MeleeAltFire =
{
    if (!SH_MeleeTryStrike(time, 1))
        return;
    self.wep_nextframe   = time + MELEE_FRAME_INTERVAL;
    self.melee_snd_stage = 0;
    PlayerModelPlayPrimaryAttack();
};

// Special (impulse 7) — block_low.  Visual flourish + block sound at
// fire time.  No damage, no trace.
void() W_MeleeSpecial =
{
    if (!SH_MeleeTryBlock(time))
        return;
    self.wep_nextframe   = time + MELEE_FRAME_INTERVAL;
    self.melee_snd_stage = 0;
    sound(self, CHAN_WEAPON, MELEE_SND_BLOCK, 1.0, ATTN_NORM);
};

// Frame — fires the strike exactly once per action at MELEE_HIT_TIME
// (50 ms after action started).  After the strike, the state machine
// rolls back to idle once SH_SeqDrivenTickState reports the sequence
// finished — even though the cooldown is shorter so the player can
// re-fire mid-anim if they want.
void() W_MeleeFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;
    self.wep_nextframe += MELEE_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE
        && self.melee_snd_stage < 1
        && elapsed >= MELEE_HIT_TIME)
    {
        W_MeleeStrike();
        self.melee_snd_stage = 1;
    }

    if (SH_MeleeTickState(time) & 1)
    {
        self.weaponframe     = MELEE_SEQ_IDLE;
        self.wep_nextframe   = 0;
        self.melee_snd_stage = 0;
    }
};

// World entity — kept for completeness but the weapon is intrinsic
// so nothing in the menu / spawn flow calls this.  Returned for
// internal callers that defensively look up weapon_melee.
void() weapon_melee =
{
    SH_GoldSrcSetupWorld(MELEE_VIEWMODEL, '-8 -8 0', '8 8 16');
    self.classname   = "weapon_melee";
    self.solid       = SOLID_TRIGGER;
    self.movetype    = MOVETYPE_TOSS;
    self.weapon      = WEP_MELEE;
    self.weapon_slot = SLOT_MELEE;
    self.weap_draw   = W_MeleeEquip;
    self.weap_drop_func = W_MeleeDrop;
    self.pickupcopy  = W_MeleePickupCopy;
    self.touch       = weapon_touch;
    W_RegisterMapWeapon(weapon_melee);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY — prediction + viewmodel display
// ============================================================

#ifdef CSQC

float csqc_melee_snd_stage;
float csqc_melee_snd_action;
float csqc_melee_idle_anchor;
float csqc_melee_prev_seen_state;

// Predicted trace at MELEE_HIT_TIME after action started.  Plays
// the local sound + spawns a smoke puff at the contact point.
// Hitclaim is sent server-ward for player hits; breakable predict
// fires for non-player solids.  NO bullethole.
void() CSQC_PredictMeleeStrike =
{
    // Match hitscan entry points — start the per-shot impact-FX budget
    // fresh so a stale counter from the previous bullet can't starve
    // the smoke puff at the contact point.
    CSQC_Impact_ResetShot();

    float is_kick   = SH_MeleeSeqIsKick(self.weaponframe);
    float range     = is_kick ? MELEE_KICK_RANGE   : MELEE_PUNCH_RANGE;
    float dmg       = is_kick ? MELEE_KICK_DAMAGE  : MELEE_PUNCH_DAMAGE;
    string hit_snd  = is_kick ? MELEE_SND_KICK_HIT : MELEE_SND_PUNCH_HIT;

    vector src, end;
    makevectors(input_angles);
    src = self.origin + self.view_ofs;
    end = src + v_forward * range;

    CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);

    if (trace_fraction >= 1.0)
    {
        // Air miss — single sound only.
        if (!pm_suppress_sounds)
        {
            localsound(MELEE_SND_MISS);
            CSQC_RecordPredictedAutoSound();
        }
        return;
    }

    // Hit something.  Send hitclaim or breakable predict, play sound,
    // spawn small smoke puff at contact.  No bullethole.
    float is_player_hit =
        (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
        || (trace_ent.classname == "player_visual_proxy");

    if (is_player_hit)
        CSQC_SendHitclaim(trace_ent, dmg, 0, HITGROUP_GENERIC);
    else
        CSQC_PredictBreakableBreak(trace_ent, dmg);

    if (!pm_suppress_sounds)
    {
        localsound(hit_snd);
        CSQC_RecordPredictedAutoSound();
    }

    // Impact effect — branch on hit type.  Players: blood spray.
    // Walls / props: smoke puff (no sparks).  Sky surfaces: nothing.
    if (pointcontents(trace_endpos - trace_plane_normal * 2) != CONTENT_SKY)
    {
        vector ip_pos = trace_endpos + trace_plane_normal * Impact_ParticleOffset();
        if (is_player_hit)
            Impact_SpawnParticles(ip_pos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
        else
            Impact_SpawnSmokeOnly(ip_pos, trace_plane_normal);
    }
};

void() CSQC_PredictMeleeSpecial =
{
    if (!SH_MeleeTryBlock(csqc_pred_time))
        return;
    csqc_melee_snd_stage  = 0;
    csqc_melee_snd_action = predicted_player.wep_action_id;
    if (!pm_suppress_sounds)
    {
        localsound(MELEE_SND_BLOCK);
        CSQC_RecordPredictedWeaponSound();
    }
    CSQC_MarkPendingWeaponAck();
};

void() CSQC_PredictMeleeCommand =
{
    float elapsed;

    if (predicted_player.wep_action_id != csqc_melee_snd_action)
    {
        csqc_melee_snd_action = predicted_player.wep_action_id;
        csqc_melee_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        if (SH_MeleeTryStrike(csqc_pred_time, 0))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_melee_snd_stage  = 0;
            csqc_melee_snd_action = predicted_player.wep_action_id;
            // No sound at fire time — single sound fires from the
            // hit-time gate below at MELEE_HIT_TIME elapsed.
        }
    }
    else if (input_buttons & 4)
    {
        if (SH_MeleeTryStrike(csqc_pred_time, 1))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_melee_snd_stage  = 0;
            csqc_melee_snd_action = predicted_player.wep_action_id;
        }
    }

    // Predicted strike at MELEE_HIT_TIME — single sound + smoke +
    // hitclaim happen here.
    if (!pm_suppress_sounds
        && self.wep_anim_start > 0
        && csqc_melee_snd_stage < 1
        && self.weaponstate == WS_FIRE)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (elapsed >= MELEE_HIT_TIME)
        {
            CSQC_PredictMeleeStrike();
            csqc_melee_snd_stage = 1;
        }
    }

    SH_MeleeTickState(csqc_pred_time);
};

float(float elapsed) CSQC_MeleeDisplayFrame =
{
    float ws = predicted_player.weaponstate;

    if (ws == WS_IDLE && csqc_melee_prev_seen_state != WS_IDLE)
        csqc_melee_idle_anchor = cltime;
    csqc_melee_prev_seen_state = ws;

    if (ws == WS_DRAW)
        return MELEE_SEQ_DRAW;

    if (ws == WS_FIRE || ws == WS_SPECIAL)
        return predicted_player.weaponframe;

    csqc_viewmodel_sequence_time_override = TRUE;
    csqc_viewmodel_sequence_time = max(0, cltime - csqc_melee_idle_anchor);
    return MELEE_SEQ_IDLE;
};

void() CSQC_MeleeDropClear =
{
};

void() CSQC_MeleeEquip =
{
    self.weapon_name         = MELEE_DISPLAY_NAME;
    self.weapon_viewmodel    = MELEE_VIEWMODEL;
    self.weapon_worldmodel   = "";
    self.weapon_deploy_sound = MELEE_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictMeleeCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_MeleeDisplayFrame;
    self.csqc_drop_clear     = CSQC_MeleeDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
