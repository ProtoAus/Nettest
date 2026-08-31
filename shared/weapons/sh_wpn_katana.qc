// ============================================================
//  shared/weapons/sh_wpn_katana.qc  -  Katana sword (melee)
//
//  Slot  : SLOT_MELEE
//  Fire  : random slash (slash1 / slash2 / slash3) — primary
//          cooldown 650 ms; trace + single sound at 100 ms.
//  Alt   : block flourish (no damage)              — alt-fire
//          cooldown 650 ms.
//
//  Sound rule (single sound per swing, at trace moment):
//      slash + body (player)   → hitbody1.wav
//      slash + wall/prop       → hitwall1.wav or hitwall2.wav (random)
//      slash + air             → miss1.wav    or miss2.wav    (random)
//
//  Impact effects:
//      NO bullethole decals
//      NO sparks / particle dust
//      Small smoke puff (MS_SpawnOnePuff) at the contact point
//
//  Client-instant rule: same as fists — CSQC predicts the trace +
//  sound + smoke 100 ms after the input click; server's broadcast
//  is dimension-masked to exclude the attacker.
//
//  Sequence indices (matches user-provided $sequence list):
//      0  idle
//      1  draw
//      2  slash1
//      3  slash2
//      4  slash3
//      5  block
// ============================================================

const float KATANA_SLASH_RANGE  = 96;
const float KATANA_SLASH_DAMAGE = 40;
const float KATANA_COOLDOWN     = 0.65;   // 650 ms between swings
const float KATANA_HIT_TIME     = 0.10;   // 100 ms after fire → trace + sound

const float KATANA_SEQ_IDLE   = 0;
const float KATANA_SEQ_DRAW   = 1;
const float KATANA_SEQ_SLASH1 = 2;
const float KATANA_SEQ_SLASH2 = 3;
const float KATANA_SEQ_SLASH3 = 4;
const float KATANA_SEQ_BLOCK  = 5;

const float KATANA_FRAME_INTERVAL = 0.05;

const string KATANA_VIEWMODEL    = "models/weapons/wpn_katana/v_katana.mdl";
const string KATANA_WORLDMODEL   = "models/weapons/wpn_katana/w_katana.mdl";
const string KATANA_DEPLOY_SOUND = "";
const string KATANA_DISPLAY_NAME = "KATANA";

const string KATANA_SND_HITBODY  = "sounds/weapons/wpn_katana/hitbody1.wav";
const string KATANA_SND_HITWALL1 = "sounds/weapons/wpn_katana/hitwall1.wav";
const string KATANA_SND_HITWALL2 = "sounds/weapons/wpn_katana/hitwall2.wav";
const string KATANA_SND_MISS1    = "sounds/weapons/wpn_katana/miss1.wav";
const string KATANA_SND_MISS2    = "sounds/weapons/wpn_katana/miss2.wav";

.float katana_snd_stage;

// Impact visuals — see sh_wpn_melee.qc for branching rationale.
#ifdef CSQC
void(vector pos, vector normal) Impact_SpawnSmokeOnly;
void(vector pos, vector normal, float mat) Impact_SpawnParticles;
float() Impact_ParticleOffset;
#endif

// ============================================================
//  SHARED — sequence picks + state
// ============================================================

float() SH_KatanaPickSlashSeq =
{
    float h = SH_SpreadHash(self.wep_action_id);
    if (h < 0.333) return KATANA_SEQ_SLASH1;
    if (h < 0.666) return KATANA_SEQ_SLASH2;
    return KATANA_SEQ_SLASH3;
};

// Use action_id hash for the random wall/miss sound pick too so
// server and CSQC agree on which variant to play (relevant for
// other players who hear the server's broadcast).
float() SH_KatanaPickHitwallSeq =
{
    return (SH_SpreadHash(self.wep_action_id + 7919) < 0.5) ? 0 : 1;
};
float() SH_KatanaPickMissSeq =
{
    return (SH_SpreadHash(self.wep_action_id + 6151) < 0.5) ? 0 : 1;
};

float(float now) SH_KatanaTickState =
{
    return SH_SeqDrivenTickState(now, KATANA_VIEWMODEL);
};

float(float now) SH_KatanaTrySlash =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
#ifdef CSQC
    if (now < self.csqc_fire_guard) return 0;
#endif
    if (self.weaponstate == WS_DRAW) return 0;
    if (now < self.attack_finished) return 0;

    self.wep_action_id += 1;
    float seq = SH_KatanaPickSlashSeq();

    self.weaponstate     = WS_FIRE;
    self.weaponframe     = seq;
    self.wep_anim_start  = now;
    self.attack_finished = now + KATANA_COOLDOWN;
#ifdef CSQC
    self.csqc_fire_guard = now + KATANA_COOLDOWN;
#endif
    return 1;
};

float(float now) SH_KatanaTryBlock =
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
    self.weaponframe     = KATANA_SEQ_BLOCK;
    self.wep_anim_start  = now;
    self.attack_finished = now + KATANA_COOLDOWN;
#ifdef CSQC
    self.csqc_fire_guard = now + KATANA_COOLDOWN;
#endif
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

void() weapon_touch;
void() PlayerModelPlayPrimaryAttack;

void() W_KatanaEnterIdle;
void() W_KatanaStrike;
void() W_KatanaFire;
void() W_KatanaAltFire;
void() W_KatanaFrame;
void() W_KatanaEquip;

void(entity receiver) W_KatanaPickupCopy =
{
};

void() W_KatanaDrop =
{
    entity tgt = weapon_drop_target;

    entity oldself = self;
    self = tgt;
    SH_GoldSrcSetupWorld(KATANA_WORLDMODEL, '-16 -16 0', '16 16 48');
    self = oldself;

    tgt.classname    = "weapon_katana";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_KATANA;
    tgt.weapon_slot  = SLOT_MELEE;
    tgt.weap_draw    = W_KatanaEquip;
    tgt.weap_drop_func = W_KatanaDrop;
    tgt.pickupcopy   = W_KatanaPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() W_KatanaEnterIdle =
{
    self.weaponframe    = KATANA_SEQ_IDLE;
    self.weaponstate    = WS_IDLE;
    self.wep_anim_start = 0;
    self.wep_nextframe  = 0;
    self.katana_snd_stage = 0;
};

void() W_KatanaEquip =
{
    self.weaponmodel               = KATANA_VIEWMODEL;
    self.weapon_name               = KATANA_DISPLAY_NAME;
    self.weapon_draw_start_frame   = KATANA_SEQ_DRAW;
    self.weapon_player_attack_anim = PLAYER_ATTACKANIM_MELEE;
    self.altfire                   = W_KatanaAltFire;
    self.altrelease                = __NULL__;
    self.shoot                     = W_KatanaStrike;
    self.fire                      = W_KatanaFire;
    self.reload                    = __NULL__;
    self.special                   = __NULL__;
    self.wepframe                  = W_KatanaFrame;
    self.weaponstate               = WS_DRAW;
    self.wep_action_id            += 1;
    self.wep_anim_start            = time;
    self.weaponframe               = KATANA_SEQ_DRAW;
    self.wep_nextframe             = time + KATANA_FRAME_INTERVAL;
    self.katana_snd_stage          = 0;
    W_SetCrosshairProfile(0, 0, 0, 0, FALSE);
};

// Authoritative trace.  Sound chosen by hit type: body / wall / air.
// Damage applied for player hits.  No bullethole multicast (the
// other-side W_ImpactEffect would spawn one; we deliberately skip).
void() W_KatanaStrike =
{
    vector src;
    vector end;
    makevectors(self.v_angle);
    src = self.origin + self.view_ofs;
    end = src + (v_forward * KATANA_SLASH_RANGE);
    W_MeleeTrace(src, end);     // line, then HL's head-hull fallback

    float saved_dim = dimension_send;
    dimension_send  = dimension_send & ~self.dimension_seen;

    if (trace_fraction >= 1.0)
    {
        // Pure miss — random air-whoosh.
        string miss = SH_KatanaPickMissSeq() ? KATANA_SND_MISS2 : KATANA_SND_MISS1;
        sound(self, CHAN_AUTO, miss, 1.0, ATTN_NORM);
        dimension_send = saved_dim;
        return;
    }

    if (W_CanDamageTarget(trace_ent))
    {
        // Body hit — hitbody1.
        sound(self, CHAN_AUTO, KATANA_SND_HITBODY, 1.0, ATTN_NORM);
        dimension_send = saved_dim;
        W_DebugImpact(trace_endpos, KATANA_SLASH_DAMAGE, W_BoneToHitgroup(trace_bone_id));
        // Defer player damage to the attacker's hitclaim when they
        // predict hits — see sh_wpn_melee.qc for rationale.
        float defer_player = (trace_ent.classname == "player")
                             && W_ShouldDeferToClaim(self);
        if (!defer_player)
            W_ApplyDamage(self, trace_ent, KATANA_SLASH_DAMAGE);
        return;
    }

    // Wall / prop hit — random hitwall variant.
    string wall = SH_KatanaPickHitwallSeq() ? KATANA_SND_HITWALL2 : KATANA_SND_HITWALL1;
    sound(self, CHAN_AUTO, wall, 1.0, ATTN_NORM);
    dimension_send = saved_dim;

    PhysProp_TryPushFromTrace(v_forward, KATANA_SLASH_DAMAGE);
};

void() W_KatanaFire =
{
    if (!SH_KatanaTrySlash(time))
        return;
    self.wep_nextframe    = time + KATANA_FRAME_INTERVAL;
    self.katana_snd_stage = 0;
    PlayerModelPlayPrimaryAttack();
};

void() W_KatanaAltFire =
{
    if (!SH_KatanaTryBlock(time))
        return;
    self.wep_nextframe    = time + KATANA_FRAME_INTERVAL;
    self.katana_snd_stage = 0;
    // Block has no audio in the asset set.
};

void() W_KatanaFrame =
{
    float elapsed = (self.wep_anim_start > 0) ? (time - self.wep_anim_start) : 0;
    self.wep_nextframe += KATANA_FRAME_INTERVAL;

    if (self.weaponstate == WS_FIRE
        && self.katana_snd_stage < 1
        && elapsed >= KATANA_HIT_TIME)
    {
        W_KatanaStrike();
        self.katana_snd_stage = 1;
    }

    if (SH_KatanaTickState(time) & 1)
    {
        self.weaponframe      = KATANA_SEQ_IDLE;
        self.wep_nextframe    = 0;
        self.katana_snd_stage = 0;
    }
};

void() weapon_katana =
{
    SH_GoldSrcSetupWorld(KATANA_WORLDMODEL, '-16 -16 0', '16 16 48');
    self.classname   = "weapon_katana";
    self.solid       = SOLID_TRIGGER;
    self.movetype    = MOVETYPE_TOSS;
    self.weapon      = WEP_KATANA;
    self.weapon_slot = SLOT_MELEE;
    self.weap_draw   = W_KatanaEquip;
    self.weap_drop_func = W_KatanaDrop;
    self.pickupcopy  = W_KatanaPickupCopy;
    self.touch       = weapon_touch;
    W_RegisterMapWeapon(weapon_katana);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

float csqc_katana_snd_stage;
float csqc_katana_snd_action;
float csqc_katana_idle_anchor;
float csqc_katana_prev_seen_state;

void() CSQC_PredictKatanaStrike =
{
    vector src, end;
    makevectors(input_angles);
    src = self.origin + self.view_ofs;
    end = src + v_forward * KATANA_SLASH_RANGE;

    CSQC_WeaponTraceLine(src, end, MOVE_NORMAL | MOVE_HITMODEL, self);

    if (trace_fraction >= 1.0)
    {
        if (!pm_suppress_sounds)
        {
            string miss = SH_KatanaPickMissSeq() ? KATANA_SND_MISS2 : KATANA_SND_MISS1;
            localsound(miss);
            CSQC_RecordPredictedAutoSound();
        }
        return;
    }

    float is_player_hit =
        (trace_ent != world && trace_ent.entnum >= 1 && trace_ent.entnum <= maxclients)
        || (trace_ent.classname == "player_visual_proxy");

    if (is_player_hit)
        CSQC_SendHitclaim(trace_ent, KATANA_SLASH_DAMAGE, 0, HITGROUP_GENERIC);
    else
        CSQC_PredictBreakableBreak(trace_ent, KATANA_SLASH_DAMAGE);

    if (!pm_suppress_sounds)
    {
        string snd;
        if (is_player_hit)
            snd = KATANA_SND_HITBODY;
        else
            snd = SH_KatanaPickHitwallSeq() ? KATANA_SND_HITWALL2 : KATANA_SND_HITWALL1;
        localsound(snd);
        CSQC_RecordPredictedAutoSound();
    }

    // Impact effect — blood on player, smoke on wall, nothing on sky.
    if (pointcontents(trace_endpos - trace_plane_normal * 2) != CONTENT_SKY)
    {
        vector ip_pos = trace_endpos + trace_plane_normal * Impact_ParticleOffset();
        if (is_player_hit)
            Impact_SpawnParticles(ip_pos, trace_plane_normal, IMPACT_MAT_FLESH_LETHAL);
        else
            Impact_SpawnSmokeOnly(ip_pos, trace_plane_normal);
    }
};

void() CSQC_PredictKatanaCommand =
{
    float elapsed;

    if (predicted_player.wep_action_id != csqc_katana_snd_action)
    {
        csqc_katana_snd_action = predicted_player.wep_action_id;
        csqc_katana_snd_stage  = 0;
    }

    if (input_buttons & 1)
    {
        if (SH_KatanaTrySlash(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_katana_snd_stage  = 0;
            csqc_katana_snd_action = predicted_player.wep_action_id;
        }
    }
    else if (input_buttons & 4)
    {
        if (SH_KatanaTryBlock(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            csqc_katana_snd_stage  = 0;
            csqc_katana_snd_action = predicted_player.wep_action_id;
        }
    }

    if (!pm_suppress_sounds
        && self.wep_anim_start > 0
        && csqc_katana_snd_stage < 1
        && self.weaponstate == WS_FIRE)
    {
        elapsed = csqc_pred_time - self.wep_anim_start;
        if (elapsed >= KATANA_HIT_TIME)
        {
            CSQC_PredictKatanaStrike();
            csqc_katana_snd_stage = 1;
        }
    }

    SH_KatanaTickState(csqc_pred_time);
};

float(float elapsed) CSQC_KatanaDisplayFrame =
{
    float ws = predicted_player.weaponstate;

    if (ws == WS_IDLE && csqc_katana_prev_seen_state != WS_IDLE)
        csqc_katana_idle_anchor = cltime;
    csqc_katana_prev_seen_state = ws;

    if (ws == WS_DRAW)
        return KATANA_SEQ_DRAW;

    if (ws == WS_FIRE || ws == WS_SPECIAL)
        return predicted_player.weaponframe;

    csqc_viewmodel_sequence_time_override = TRUE;
    csqc_viewmodel_sequence_time = max(0, cltime - csqc_katana_idle_anchor);
    return KATANA_SEQ_IDLE;
};

void() CSQC_KatanaDropClear =
{
};

void() CSQC_KatanaEquip =
{
    self.weapon_name         = KATANA_DISPLAY_NAME;
    self.weapon_viewmodel    = KATANA_VIEWMODEL;
    self.weapon_worldmodel   = KATANA_WORLDMODEL;
    self.weapon_deploy_sound = KATANA_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictKatanaCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_KatanaDisplayFrame;
    self.csqc_drop_clear     = CSQC_KatanaDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
