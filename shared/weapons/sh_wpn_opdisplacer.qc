// ============================================================
//  shared/weapons/sh_wpn_opdisplacer.qc  -  Opposing Force Displacer
//
//  Slot  : SLOT_PRIMARY
//  Stats : ammo_displacer, max 100, drawn from the shared CAL_URANIUM pool -
//          the same reserve the gauss and the egon feed from, which is what
//          Opposing Force does too.
//  Fire  : +attack  — a slow green orb that detonates with radius damage.
//          +attack2 — teleports the player.
//
//  33 placements across 25 gearbox maps.
//
//  THERE IS NO OPPOSING FORCE SDK ON THIS MACHINE.  The two costs (20 primary,
//  60 teleport) are OpFor's own and are what give the weapon its character - a
//  full charge buys five orbs OR one teleport and two orbs, so spending it on
//  the teleport is a real decision.  The damage, radius and orb speed are this
//  mod's, chosen to sit above the RPG without eclipsing it.
//
//  THE TELEPORT'S DESTINATION IS THE WHOLE PROBLEM, and it is handled in
//  Displacer_PickDestination.  Read the note there before changing it.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

.float disp_charge_start;    // when +attack2 was pressed, for the spin-up

// sh_pmove.qc compiles at sv_progs.src:357, long after this file, so the hull
// accessor has to be forward-declared.  Needed by the teleport half: OpFor's
// info_displacer_*_target entities put their origin at the player's FEET, the
// same GoldSrc convention trigger_teleport has to correct for.
vector() PM_CurrentMins;

// --- Sequence indices, read out of v_displacer.mdl (7 sequences) ----------
const float DISP_SEQ_IDLE1    = 0;   // idle1,    3.000 s, looping
const float DISP_SEQ_IDLE2    = 1;   // idle2,    3.000 s, looping
const float DISP_SEQ_SPINUP   = 2;   // spinup,   1.000 s, looping
const float DISP_SEQ_SPIN     = 3;   // spin,     1.000 s, looping
const float DISP_SEQ_FIRE     = 4;   // fire,     1.000 s
const float DISP_SEQ_DRAW     = 5;   // draw,     1.000 s
const float DISP_SEQ_HOLSTER  = 6;   // holster1, 1.000 s

const float DISP_FRAME_INTERVAL = 0.05;
const float DISP_DRAW_DURATION  = 1.0;
const float DISP_FIRE_DURATION  = 1.0;

const float MAX_AMMO_DISPLACER   = 100;
const float DISP_PRIMARY_COST    = 20;
const float DISP_TELEPORT_COST   = 60;

// --- Balance -------------------------------------------------------------
const float DISP_ORB_SPEED       = 500;   // slow and dodgeable on purpose
const float DISP_BLAST_RADIUS    = 150;
const float DISP_BLAST_PEAK      = 90;
const float DISP_BLAST_MIN       = 25;
const float DISP_PRIMARY_DELAY   = 1.0;
const float DISP_SPINUP_TIME     = 1.0;   // how long +attack2 must be held
const float DISP_TELEFRAG_RADIUS = 48;

const string DISP_VIEWMODEL      = "models/v_displacer.mdl";
const string DISP_WORLDMODEL     = "models/w_displacer.mdl";
const string DISP_ORB_SPRITE     = "sprites/exit1.spr";
const string DISP_DISPLAY_NAME   = "DISPLACER";
const string DISP_DEPLOY_SOUND   = "weapons/displacer_start.wav";

// When the secondary-fire wind-up completes, or 0 when none is running.  A
// player field, not a global: the same shared code runs on the server and inside
// CSQC prediction.
.float disp_spin_end;

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_DispTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= DISP_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        // A secondary-fire wind-up holds WS_FIRE for its own duration and then
        // reports completion as 2, which is the signal to actually teleport.
        // Without this the fire tail (DISP_FIRE_DURATION) would end the state
        // first and the charge would be dropped on the floor.
        if (self.disp_spin_end > 0)
        {
            if (now < self.disp_spin_end)
                return 0;
            self.disp_spin_end = 0;
            SH_WeaponEnterIdle();
            return 2;
        }
        if (elapsed >= DISP_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// Secondary fire: START the wind-up.  Shared so the client can predict the
// animation and the ammo spend while the server keeps sole authority over where
// the player ends up.
//
// Opposing Force's displacer does not teleport on the press -- it spins up
// first, audibly, and you are committed and stationary while it does.  This
// weapon had DISP_SPINUP_TIME and DISP_SEQ_SPIN declared and used by nothing:
// W_DispAltFire called W_DispTeleport on the same frame as the press, so the
// wind-up sound was cut off by the teleport and the animation never played.
float(float now) SH_DispTryAltFire =
{
    if (self.weaponstate != WS_IDLE && self.weaponstate != WS_FIRE) return 0;
    if (self.disp_spin_end > 0) return 0;          // already winding up
    if (now < self.attack_finished) return 0;
    if (self.ammo_displacer < DISP_TELEPORT_COST) return -1;

    // Charged up front: committed, no refund.  Releasing the button mid-spin
    // does not abort -- that commitment is the cost of a get-out-of-jail move.
    self.ammo_displacer -= DISP_TELEPORT_COST;
    self.weaponstate     = WS_FIRE;
    self.wep_action_id  += 1;
    self.wep_anim_start  = now;
    self.weaponframe     = DISP_SEQ_SPINUP;
    self.disp_spin_end   = now + DISP_SPINUP_TIME;
    self.attack_finished = now + DISP_SPINUP_TIME + DISP_PRIMARY_DELAY;
    return 1;
};

float(float now) SH_DispTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE && self.weaponstate != WS_FIRE) return 0;
    if (now < self.attack_finished) return 0;
    if (self.ammo_displacer < DISP_PRIMARY_COST) return 0;

    self.ammo_displacer  -= DISP_PRIMARY_COST;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + DISP_PRIMARY_DELAY;
    return 1;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Both of these live in server/sv_player.qc, which compiles at position 238 -
// long after the weapon files at 57-64 - so they are reached forward.  QC allows
// this for functions (but not for globals), which is why the teleport can use
// the mod's own spawn-point picker rather than reimplementing it here.
entity() PlayerGetSpawnPointEntity;
void(entity player) PM_SyncPredictionProxy;

void(entity player) W_DispPickupCopy =
{ if (self.ammo_displacer > player.ammo_displacer) player.ammo_displacer = self.ammo_displacer; };

void() W_DisplacerOrbTouch;
void() W_DisplacerOrbExpire = { remove(self); };

void() W_DisplacerOrbExplode =
{
    WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
    WriteByte(MSG_MULTICAST, CSQC_EVENT_GRENADE_EXPLODE);
    WriteShort(MSG_MULTICAST, 0);
    WriteCoord(MSG_MULTICAST, self.origin_x);
    WriteCoord(MSG_MULTICAST, self.origin_y);
    WriteCoord(MSG_MULTICAST, self.origin_z + 4);
    WriteByte(MSG_MULTICAST, floor(random() * 3));
    multicast(self.origin, MULTICAST_PVS);

    sound(self, CHAN_WEAPON, "weapons/displacer_impact.wav", 1, ATTN_NORM);
    W_RadiusExplode(self.origin, DISP_BLAST_RADIUS, DISP_BLAST_PEAK, DISP_BLAST_MIN,
                    300, 150, self.owner);
    remove(self);
};

void() W_DisplacerOrbTouch =
{
    if (other == self.owner)
        return;
    W_DisplacerOrbExplode();
};

void() W_DispFire =
{
    if (!SH_DispTryFire(time)) return;

    self.weaponframe   = DISP_SEQ_FIRE;
    // MUST schedule, not clear -- sv_weapons.qc only calls wepframe while
    // wep_nextframe > 0, so a 0 here retires the frame function permanently and
    // weaponstate never leaves WS_FIRE (this weapon's try-fire accepts WS_FIRE, so
    // it kept shooting and the freeze went unnoticed -- but the idle animation and
    // every per-tick behaviour behind the frame function stopped).  Clear it only
    // on the idle-retire, the way the *Frame functions below do.
    self.wep_nextframe = time + DISP_FRAME_INTERVAL;

    sound(self, CHAN_WEAPON, "weapons/displacer_fire.wav", 1, ATTN_NORM);

    makevectors(self.v_angle);
    entity orb = spawn();
    orb.owner     = self;
    orb.classname = "proj_displacer_ball";
    orb.movetype  = MOVETYPE_FLYMISSILE;
    orb.solid     = SOLID_BBOX;
    setmodel(orb, DISP_ORB_SPRITE);
    setsize(orb, '-4 -4 -4', '4 4 4');
    setorigin(orb, self.origin + self.view_ofs + v_forward * 16);
    orb.velocity   = v_forward * DISP_ORB_SPEED;
    orb.angles     = vectoangles(orb.velocity);
    orb.touch      = W_DisplacerOrbTouch;
    // EF_ADDITIVE for the same reason the CSQC copies carry it (FTE ignores
    // exit1.spr's SPR_ADDITIVE header).  It is belt-and-braces here -- this
    // entity is SendEntity, so what actually renders is built by
    // CSQC_Projectile_Update -- but it keeps the server's idea of the orb
    // honest if the projectile is ever demoted to plain delta replication.
    orb.effects    = orb.effects | EF_DIMLIGHT | EF_ADDITIVE;
    orb.proj_type  = PROJ_TYPE_DISPLACER_BALL;
    orb.SendEntity = projectile_SendEntity;
    orb.SendFlags  = 1;
    // A fuse, unlike the RPG rocket: an orb fired into open sky would otherwise
    // fly forever and stay on the entity list for the rest of the map.
    orb.think      = W_DisplacerOrbExpire;
    orb.nextthink  = time + 15;
};

// Pick somewhere to put the player.
//
// THIS IS THE ONE PART OF THE WEAPON THAT CANNOT BE PORTED, because Opposing
// Force's answer does not exist in most of the maps this mod runs.  OpFor picks
// a random info_displacer_earth_target (or _xen_target on the Xen maps); those
// entities are placed by OpFor's own campaign and by nothing else.  A Half-Life
// or They Hunger map has none.
//
// So: try OpFor's entities, then fall back to the mod's own spawn-point picker,
// and if even that comes back empty REFUSE THE SHOT AND REFUND THE AMMO.
//
// The refusal is the important line.  The obvious fallback - hand off to
// PlayerPlaceAtSpawnPoint - looks safer and is much worse: that function ends in
// setorigin(self, '0 0 1') when it finds nothing (sv_player.qc:412), which in a
// Half-Life campaign map drops the player through the world with no way back and
// no way to tell what happened.  A teleport that politely declines is a mild
// disappointment; one that deletes your session is a bug report.
entity() Displacer_PickDestination =
{
    entity best = world;
    float n = 0;
    entity e;

    // Two passes rather than reservoir sampling: the entity counts here are
    // tiny and a plain "count, then walk to index" is much easier to be sure of.
    e = find(world, classname, "info_displacer_earth_target");
    while (e) { n = n + 1; e = find(e, classname, "info_displacer_earth_target"); }
    if (!n)
    {
        e = find(world, classname, "info_displacer_xen_target");
        while (e) { n = n + 1; e = find(e, classname, "info_displacer_xen_target"); }
        if (n)
        {
            float pick = floor(random() * n);
            e = find(world, classname, "info_displacer_xen_target");
            while (e && pick > 0) { pick = pick - 1; e = find(e, classname, "info_displacer_xen_target"); }
            return e;
        }
    }
    else
    {
        float pick2 = floor(random() * n);
        e = find(world, classname, "info_displacer_earth_target");
        while (e && pick2 > 0) { pick2 = pick2 - 1; e = find(e, classname, "info_displacer_earth_target"); }
        return e;
    }

    // No displacer targets: use the map's own spawn points.  This is already
    // team-aware and already walks the whole info_player_* fallback chain.
    best = PlayerGetSpawnPointEntity();
    return best;
};

void() W_DispTeleport =
{
    entity dest = Displacer_PickDestination();
    if (!dest)
    {
        // Refund, and say so - a silent no-op reads as a broken weapon.
        self.ammo_displacer += DISP_TELEPORT_COST;
        sprint(self, PRINT_HIGH, "The displacer finds nowhere to send you.\n");
        sound(self, CHAN_WEAPON, "weapons/displacer_spin2.wav", 1, ATTN_NORM);
        return;
    }

    vector from = self.origin;

    // Telefrag whatever is standing on the pad, which is what OpFor does and
    // what stops two players deadlocking on one destination.
    entity v = findradius(dest.origin, DISP_TELEFRAG_RADIUS);
    while (v)
    {
        if (v != self && (v.takedamage || v.classname == "player"))
            W_ApplyDamage(self, v, 1000);
        v = v.chain;
    }

    sound(self, CHAN_WEAPON, "weapons/displacer_teleport.wav", 1, ATTN_NORM);

    // The same feet-vs-centre correction trigger_teleport needs, and for the
    // same reason: OpFor's info_displacer_earth_target / info_displacer_xen_target
    // are point entities authored at floor level, so dropping the player's hull
    // CENTRE there buries them to the waist.  Half-Life's own line is
    // `tmp.z -= pOther->pev->mins.z; tmp.z++;` — the +1 was already here.
    vector dorg  = dest.origin + '0 0 1';
    vector dmins = PM_CurrentMins();
    if (Map_IsGoldSrcShared())
        dorg_z = dorg_z - dmins_z;

    setorigin(self, dorg);
    self.angles   = dest.angles;
    self.v_angle  = dest.angles;
    self.fixangle = TRUE;
    self.velocity = '0 0 0';

    // Without this the client keeps predicting from the origin it had and
    // rubber-bands back.  trigger_respawn_use does the same thing for the same
    // reason (sv_goldsrc_compat.qc:650-656) - there is no predicted "teleport
    // this player now", so the correction is server-authoritative and after the
    // fact.  A one-round-trip hitch at the moment of a teleport reads as
    // intentional, which is why this is acceptable here and would not be for
    // ordinary movement.
    PM_SyncPredictionProxy(self);

    sound(self, CHAN_ITEM, "weapons/displacer_teleport_player.wav", 1, ATTN_NORM);

    // A ring at both ends, so bystanders see where you went and where from.
    // Displacer green, and short-lived - this is punctuation, not an effect.
    Shockwave_Multicast(from,        96, 0.35, 18, '80 255 120', SHOCKWAVE_EXPAND);
    Shockwave_Multicast(self.origin, 96, 0.35, 18, '80 255 120', SHOCKWAVE_EXPAND);
};

void() W_DispAltFire =
{
    if (Weapon_SprintBlocksFire()) return;
    if (Weapon_LowerBlocksFire()) return;

    float r = SH_DispTryAltFire(time);
    if (r == -1)
    {
        sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
        self.attack_finished = time + 0.5;
        return;
    }
    if (r != 1)
        return;

    // MUST schedule, not clear -- sv_weapons.qc only calls wepframe while
    // wep_nextframe > 0, so a 0 here retires the frame function permanently and
    // weaponstate never leaves WS_FIRE (this weapon's try-fire accepts WS_FIRE, so
    // it kept shooting and the freeze went unnoticed -- but the idle animation and
    // every per-tick behaviour behind the frame function stopped).  Clear it only
    // on the idle-retire, the way the *Frame functions below do.
    //
    // Doubly load-bearing now: the frame function is what completes the wind-up
    // and performs the teleport, so retiring it here would strand the player
    // mid-charge, 60 ammo down, with nothing to show for it.
    self.wep_nextframe = time + DISP_FRAME_INTERVAL;

    sound(self, CHAN_WEAPON, "weapons/displacer_spin.wav", 1, ATTN_NORM);
};

void() W_DispFrame =
{
    float result = SH_DispTickState(time);

    // 2 = the wind-up finished this tick.  The teleport is server-only and
    // deliberately unpredicted -- where you land depends on entities the client
    // does not enumerate and on a telefrag only the server can arbitrate.
    if (result == 2)
        W_DispTeleport();

    // Both 1 and 2 mean SH_DispTickState just entered idle, so both retire the
    // animation.  (`result & 1` alone would miss 2 and leave the gun stuck on
    // the spin-up pose with its frame function ticking forever.)
    if (result != 0)
    {
        self.weaponframe   = DISP_SEQ_IDLE1;
        self.wep_nextframe = 0;
    }
};

void() W_DispEquip =
{
    W_StandardEquipSetup(DISP_VIEWMODEL, DISP_DISPLAY_NAME, DISP_SEQ_DRAW,
        DISP_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_DispFire;
    self.altfire  = W_DispAltFire;
    self.reload   = __NULL__;
    self.wepframe = W_DispFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    W_SetCrosshairProfile(0, 0, 320, 1.2, TRUE);
};

void() W_DispDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_displacer = self.ammo_displacer;
    self.ammo_displacer = 0;

    setmodel(tgt, DISP_WORLDMODEL);
    setsize(tgt, '-16 -16 0', '16 16 48');
    tgt.classname    = "weapon_displacer";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_DISPLACER;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_DispEquip;
    tgt.weap_drop_func = W_DispDrop;
    tgt.pickupcopy   = W_DispPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
};

void() weapon_displacer =
{
    precache_model(DISP_WORLDMODEL);
    precache_model(DISP_VIEWMODEL);
    precache_model(DISP_ORB_SPRITE);

    setmodel(self, DISP_WORLDMODEL);
    setsize(self, '-16 -16 0', '16 16 48');
    self.classname     = "weapon_displacer";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_DISPLACER;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_DispEquip;
    self.weap_drop_func = W_DispDrop;
    self.pickupcopy    = W_DispPickupCopy;
    self.touch         = weapon_touch;
    self.ammo_displacer = MAX_AMMO_DISPLACER;
    W_RegisterMapWeapon(weapon_displacer);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictDispCommand =
{
    // Secondary: predict the WIND-UP but not the teleport.  The spin-up is
    // deterministic (ammo check plus a fixed timer) so the animation, the sound
    // and the ammo spend can all start on the press with no round trip; where
    // the player lands is arbitrated by the server, so that half stays there.
    // Predicting the wind-up is what makes the spin animation play at all --
    // CSQC_DispDisplayFrame reads disp_spin_end, and only the client sets it
    // early enough to matter.
    if (input_buttons & 4)
    {
        float ar = SH_DispTryAltFire(csqc_pred_time);
        if (ar == 1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "weapons/displacer_spin.wav", 1, ATTN_NORM);
                CSQC_RecordPredictedWeaponSound();
            }
        }
        else if (ar == -1)
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "sounds/weapons/dryfire1.wav", 1, ATTN_NORM);
                CSQC_RecordPredictedWeaponSound();
            }
        }
    }

    // Primary.  The teleport is deliberately NOT predicted: its outcome
    // depends on entities the client does not enumerate and on a telefrag the
    // server arbitrates, so a predicted guess would be wrong more often than
    // right and would have to be visibly corrected every time.
    if (input_buttons & 1)
    {
        if (SH_DispTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();
            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "weapons/displacer_fire.wav", 1, ATTN_NORM);
                CSQC_RecordPredictedWeaponSound();
                // Displacer green, matching its teleport rings and the orb
                // it fires -- not powder orange.
                CSQC_MuzzleFlash('0.35 1.0 0.45');

                // The shooter's own orb.  projectile_SendEntity returns FALSE
                // for self.owner (sv_weapons.qc), so the networked orb is drawn
                // for EVERY player except the one who fired it -- every
                // projectile in the mod therefore needs a CSQC-local twin, and
                // this weapon never had one.  That, plus sprites/exit1.spr not
                // being precached on the give path, is why "+attack shows no
                // particle effect or projectile": there was nothing to draw and
                // no model to draw it with.
                //
                // Mirrors the crossbow's fake (sh_wpn_hlcrossbow.qc).  It only
                // has to survive the flight: the detonation is multicast to the
                // whole PVS including the shooter (W_DisplacerOrbExplode), so
                // drawing an explosion here as well would double it.
                // input_angles, not self.v_angle: .v_angle is a server-side
                // player field and does not exist in CSQC.  This is the same
                // source the crossbow's fake uses.
                makevectors(input_angles);

                entity orb = spawn();
                setmodel(orb, DISP_ORB_SPRITE);
                setsize(orb, '0 0 0', '0 0 0');
                setorigin(orb, self.origin + self.view_ofs + v_forward * 16);
                orb.velocity = v_forward * DISP_ORB_SPEED;
                orb.angles   = vectoangles(orb.velocity);
                orb.movetype = MOVETYPE_NOCLIP;
                orb.solid    = SOLID_NOT;
                orb.drawmask = MASK_ENGINE;
                // EF_ADDITIVE is what turns exit1.spr from an opaque black
                // square into a ball of light -- FTE ignores the sprite's own
                // SPR_ADDITIVE header field.  See Projectile_TypeIsAdditive.
                orb.effects  = orb.effects | EF_FULLBRIGHT | EF_ADDITIVE;
                // ...and the sprite is a 25-frame animation, walked by the
                // predraw below from proj_born, exactly as the networked twin is.
                orb.csqc_projectile_type = PROJ_TYPE_DISPLACER_BALL;
                orb.proj_born = cltime;
                orb.predraw   = CSQC_FakeSpriteProj_Predraw;
                orb.think    = CSQC_FakeProjectileExpire;

                // Retire on arrival rather than on a fixed timer, so the local
                // orb vanishes as the real one detonates instead of flying on
                // through the wall for a moment.
                CSQC_WeaponTraceLine(orb.origin, orb.origin + v_forward * 8192,
                                     MOVE_NORMAL, self);
                if (trace_fraction < 1.0)
                    orb.nextthink = time + vlen(trace_endpos - orb.origin) / DISP_ORB_SPEED;
                else
                    orb.nextthink = time + 3;
            }
        }
    }

    SH_DispTickState(csqc_pred_time);
};

float(float elapsed) CSQC_DispDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return DISP_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
    {
        // Both buttons set WS_FIRE, so without this the secondary fire played
        // the PRIMARY fire animation -- the reported "the +attack2 weapon
        // animation doesn't play".  The server had it right (it sets
        // DISP_SEQ_SPINUP) and this function was overriding it every frame.
        if (predicted_player.disp_spin_end > 0)
            return DISP_SEQ_SPINUP;
        return DISP_SEQ_FIRE;
    }
    return DISP_SEQ_IDLE1;
};

void() CSQC_DispDropClear =
{ self.ammo_displacer = 0; };

void() CSQC_DispEquip =
{
    self.weapon_name         = DISP_DISPLAY_NAME;
    self.weapon_viewmodel    = DISP_VIEWMODEL;
    self.weapon_worldmodel   = DISP_WORLDMODEL;
    self.weapon_deploy_sound = DISP_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictDispCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_DispDisplayFrame;
    self.csqc_drop_clear     = CSQC_DispDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
