// ============================================================
//  shared/weapons/sh_wpn_opshockrifle.qc  -  Opposing Force Shock Rifle
//
//  Slot  : SLOT_PRIMARY
//  Stats : ammo_shockrifle, max 10.  There is no reload and there are no ammo
//          pickups anywhere in the corpus - the weapon regrows its own charge,
//          exactly like the hivehand it is modelled on here.
//  Fire  : +attack — a perfectly accurate shock beam.  No secondary.
//
//  27 placements across 20 gearbox maps.
//
//  THERE IS NO OPPOSING FORCE SDK ON THIS MACHINE, so unlike the Half-Life
//  weapons this is not a port.  The three numbers that could be sourced were:
//  the damage (sk_plr_shockrifle, already quoted at mon_grunt.qc:1261), the
//  clip size (SHOCKRIFLE_MAX_CLIP 10), and the sequence table, which was read
//  out of v_shock.mdl's own header.  Everything else is this mod's convention,
//  and is called out where it is.
//
//  WHAT IS DELIBERATELY NOT REPRODUCED: in Opposing Force the shock rifle IS A
//  LIVING CREATURE.  It is a shock roach - it dies when you run it dry, and the
//  thing a shocktrooper drops is the animal, not a gun.  models/w_shock_rifle.mdl
//  is that creature and carries thirteen locomotion sequences to prove it; the
//  inert prop this weapon leaves on the floor is w_shock.mdl.  mon_grunt.qc:1301
//  already made the same call for the shocktrooper's death drop and said so.
//
//  This file is compiled by BOTH sv_progs and cl_progs.
// ============================================================

.float shock_recharge_time;   // when the next charge grows back

// --- Sequence indices, read out of v_shock.mdl (5 sequences) -------------
const float SHOCK_SEQ_IDLE1    = 0;   // idle1,   3.333 s, looping
const float SHOCK_SEQ_FIRE     = 1;   // fire,    0.333 s
const float SHOCK_SEQ_DRAW     = 2;   // draw,    1.000 s
const float SHOCK_SEQ_HOLSTER  = 3;   // holster, 0.833 s
const float SHOCK_SEQ_IDLE3    = 4;   // idle3,   3.333 s, looping

const float SHOCK_FRAME_INTERVAL = 0.05;
const float SHOCK_DRAW_DURATION  = 1.0;
const float SHOCK_FIRE_DURATION  = 0.333;

const float MAX_AMMO_SHOCKRIFLE  = 10;    // SHOCKRIFLE_MAX_CLIP

// --- Balance -------------------------------------------------------------
const float SHOCK_DAMAGE         = 15;    // sk_plr_shockrifle
const float SHOCK_PRIMARY_DELAY  = 0.1;

// A TRAVELLING BOLT, not a hitscan trace.
//
// Opposing Force's shock rifle fires a CShock projectile; this port had it as an
// instant trace with a beam drawn along it, which is why "are the projectiles
// fired at the correct speed?" had no answer -- there were no projectiles, and
// nothing for a dynamic light to follow.  Speed is OpFor's own 2000.
// The bolt's art.
//
// This was models/shock_effect.mdl, OpFor's own bolt mesh, and it could not be
// seen.  Read the file and the reason is structural, not a QC bug: its ONE
// texture is blueChrome.bmp flagged 0x0003 = FLATSHADE|CHROME, which FTE draws
// `tcgen environment` + `rgbgen lightingdiffuse` -- a mesh lit by the room,
// which in a dark corridor is a dark sliver.  OpFor itself never draws it that
// way; it sets kRenderTransAdd, and FTE has no STUDIO_NF_ADDITIVE at all
// (gl_hlmdl.c:543-580), so the additive intent cannot be recovered.  Its header
// also declares a ZERO-size bounding box (mins == maxs == origin), which is not
// something a renderer is obliged to treat kindly.
//
// sprites/muzzle_shock.spr is the shock rifle's OWN effect art out of the same
// gearbox tree -- 32x32, texFormat 1 = SPR_ADDITIVE, 3 frames -- so it is a
// self-lit, view-facing, animated ball of electricity that cannot be dimmed by
// room lighting or squashed to an edge-on sliver.  Same weapon, same artist,
// and it renders.
const string SHOCK_BOLT_MODEL    = "sprites/muzzle_shock.spr";
const float  SHOCK_BOLT_SPEED    = 2000;
const float  SHOCK_BOLT_LIFE     = 5;
// The bolt's own colour, and therefore the colour of every light it casts.
// Matched to the beam recipe in particles/beams.cfg (rgb 30 240 250), so the
// muzzle flash, the bolt's escort light and the impact all read as one weapon.
const vector SHOCK_LIGHT_COLOUR  = '0.12 0.94 0.98';

const string SHOCK_VIEWMODEL     = "models/v_shock.mdl";
const string SHOCK_WORLDMODEL    = "models/w_shock.mdl";
const string SHOCK_DISPLAY_NAME  = "SHOCK RIFLE";
const string SHOCK_DEPLOY_SOUND  = "weapons/shock_draw.wav";

// Same multiplayer/single-player split as the hivehand's regrow, and for the
// same reason: this mod runs Half-Life's and Opposing Force's SINGLE PLAYER
// campaign maps on a multiplayer engine, so taking the faster multiplayer rate
// unconditionally would quietly rebalance every campaign map at once.
float() Shock_RechargeTime =
{
#ifdef CSQC
    if (maxclients > 1) return 0.3;
#else
    if (cvar("maxclients") > 1) return 0.3;
#endif
    return 0.5;
};

// ============================================================
//  SHARED — state machine
// ============================================================

float(float now) SH_ShockTickState =
{
    float elapsed;

    if (self.weaponstate == WS_IDLE)
        return 0;

    elapsed = (self.wep_anim_start > 0) ? (now - self.wep_anim_start) : 0;

    if (self.weaponstate == WS_DRAW)
    {
        if (elapsed >= SHOCK_DRAW_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    if (self.weaponstate == WS_FIRE)
    {
        if (elapsed >= SHOCK_FIRE_DURATION)
        { SH_WeaponEnterIdle(); return 1; }
        return 0;
    }

    return 0;
};

// The regrow.  Three properties here are load-bearing and all three are lifted
// from SH_HGunRegrow, which had to learn them the hard way:
//
//   * a WHILE, not an if - so a stalled frame catches up several charges
//     instead of dropping the ones it missed;
//   * called from the try-fire AND the weapon frame AND the CSQC predict, so
//     the counter climbs whether or not the trigger is being touched, and
//     climbs on the client at the same moment rather than a ping later;
//   * running dry costs one extra recharge period before the trigger re-arms.
void(float now) SH_ShockRegrow =
{
    if (self.ammo_shockrifle >= MAX_AMMO_SHOCKRIFLE)
        return;
    if (self.shock_recharge_time <= 0)
    { self.shock_recharge_time = now + Shock_RechargeTime(); return; }

    while (self.ammo_shockrifle < MAX_AMMO_SHOCKRIFLE && self.shock_recharge_time < now)
    {
        self.ammo_shockrifle    += 1;
        self.shock_recharge_time += Shock_RechargeTime();
    }
};

float(float now) SH_ShockTryFire =
{
    if (Weapon_SprintBlocksFire()) return 0;
    if (Weapon_LowerBlocksFire()) return 0;
    if (self.weaponstate != WS_IDLE && self.weaponstate != WS_FIRE) return 0;
    if (now < self.attack_finished) return 0;

    SH_ShockRegrow(now);
    if (self.ammo_shockrifle <= 0) return 0;

    self.ammo_shockrifle -= 1;
    self.weaponstate      = WS_FIRE;
    self.wep_action_id   += 1;
    self.wep_anim_start   = now;
    self.attack_finished  = now + SHOCK_PRIMARY_DELAY;
    if (self.ammo_shockrifle <= 0)
        self.attack_finished += Shock_RechargeTime();
    self.shock_recharge_time = now + Shock_RechargeTime();
    return 1;
};

// Both sides fire from the same offset, so it lives in shared code - a client
// drawing its predicted beam from a different muzzle than the server sends is
// the sort of mismatch that only shows up as a faint double image.
vector() Shock_MuzzleOrigin =
{
    return self.origin + self.view_ofs + v_right * 8 + v_up * -12;
};

// ============================================================
//  SERVER ONLY
// ============================================================

#ifdef SSQC

// Always picked up full: there is no ammo for this weapon anywhere in the
// corpus, so a half-empty one found on the floor could never be topped up.
void(entity player) W_ShockPickupCopy =
{ if (self.ammo_shockrifle > player.ammo_shockrifle) player.ammo_shockrifle = self.ammo_shockrifle; };

void() W_ShockBoltExpire = { remove(self); };

void() W_ShockBoltTouch =
{
    if (other == self.owner)
        return;

    // The beam is now the bolt's IMPACT flash rather than the shot itself:
    // HL_BEAM_SHOCK's recipe and its cyan dlight were built for
    // monster_shocktrooper (mon_grunt.qc) and are reused here, drawn as a short
    // arc from where the bolt was a moment ago to where it landed.
    vector from = self.origin - normalize(self.velocity) * 48;
    // owner = world, NOT the shooter.  HLBeam_Multicast's owner field doubles as
    // the client's "this is my own predicted effect, skip it" test, and the
    // shooter no longer predicts anything here -- the impact happens where the
    // bolt lands, which the client cannot know in advance.  Passing the shooter
    // would hide the flash from the one player most entitled to see it.
    HLBeam_Multicast(HL_BEAM_SHOCK, world, from, self.origin);

    if (W_CanDamageTarget(other))
        W_ApplyDamage(self.owner, other, self.proj_damage);
    else
        W_ImpactEffect(self.origin);

    remove(self);
};

void() W_ShockFire =
{
    if (!SH_ShockTryFire(time)) return;

    self.weaponframe   = SHOCK_SEQ_FIRE;
    // MUST schedule, not clear -- sv_weapons.qc only calls wepframe while
    // wep_nextframe > 0, so a 0 here retires the frame function permanently and
    // weaponstate never leaves WS_FIRE (this weapon's try-fire accepts WS_FIRE, so
    // it kept shooting and the freeze went unnoticed -- but the idle animation and
    // every per-tick behaviour behind the frame function stopped).  Clear it only
    // on the idle-retire, the way the *Frame functions below do.
    self.wep_nextframe = time + SHOCK_FRAME_INTERVAL;

    makevectors(self.v_angle);
    vector muzzle = Shock_MuzzleOrigin();

    entity bolt = spawn();
    bolt.owner     = self;
    bolt.classname = "proj_shock_bolt";
    bolt.movetype  = MOVETYPE_FLYMISSILE;
    bolt.solid     = SOLID_BBOX;
    setmodel(bolt, SHOCK_BOLT_MODEL);
    setsize(bolt, '-2 -2 -2', '2 2 2');
    setorigin(bolt, muzzle);
    bolt.velocity  = v_forward * SHOCK_BOLT_SPEED;
    bolt.angles    = W_ModelAngles(bolt.velocity, TRUE);   // IDST — pitch negated
    bolt.touch     = W_ShockBoltTouch;
    // Matches the CSQC copies; see the note on the fake below.  Rendering comes
    // from the CSQC twin (this is a SendEntity projectile), so this only keeps
    // the server entity's own description of itself correct.
    bolt.effects   = bolt.effects | EF_FULLBRIGHT | EF_ADDITIVE;
    bolt.proj_damage = SHOCK_DAMAGE;
    bolt.proj_type   = PROJ_TYPE_SHOCK_BOLT;
    bolt.SendEntity  = projectile_SendEntity;
    bolt.SendFlags   = 1;
    // A fuse, so a bolt fired into open sky does not live out the map.
    bolt.think     = W_ShockBoltExpire;
    bolt.nextthink = time + SHOCK_BOLT_LIFE;

    sound(self, CHAN_WEAPON, "weapons/shock_fire.wav", 1, ATTN_NORM);
};

void() W_ShockFrame =
{
    SH_ShockRegrow(time);

    float result = SH_ShockTickState(time);
    if (result & 1)
        self.weaponframe = SHOCK_SEQ_IDLE1;

    // KEEP THE FRAME FUNCTION ALIVE WHILE THE CHARGE IS STILL GROWING.
    //
    // sv_weapons.qc:4672 only calls wepframe while wep_nextframe > 0, so the
    // old unconditional `wep_nextframe = 0` on the idle transition retired the
    // ONLY per-tick caller of SH_ShockRegrow — the other caller is
    // SH_ShockTryFire, which needs the trigger.  The charge therefore advanced
    // for exactly the 0.333 s the fire animation lasts (one 0.3 s recharge
    // period at the multiplayer rate) and then froze, which is the reported
    // "sticks at 1".  It was a SERVER stall, not a HUD stall: the client just
    // renders slot_primary_ammo, which faithfully mirrored the frozen value.
    //
    // Retire only when there is genuinely nothing left to do — idle AND full.
    // Nothing leaks: W_ShockFire re-arms it, and W_ClearWeaponBindings
    // (sv_weapons.qc:3658) clears wepframe and wep_nextframe on every switch.
    //
    // Order matters: this test runs AFTER SH_ShockTickState, which is what
    // flips the state to WS_IDLE, so on the transition tick a below-max charge
    // re-arms immediately and the regrow continues without a gap.
    if (self.weaponstate != WS_IDLE
        || self.ammo_shockrifle < MAX_AMMO_SHOCKRIFLE)
        self.wep_nextframe = time + SHOCK_FRAME_INTERVAL;
    else
        self.wep_nextframe = 0;
};

void() W_ShockEquip =
{
    W_StandardEquipSetup(SHOCK_VIEWMODEL, SHOCK_DISPLAY_NAME, SHOCK_SEQ_DRAW,
        SHOCK_FRAME_INTERVAL, PLAYER_ATTACKANIM_SHOT);
    self.fire     = W_ShockFire;
    self.altfire  = __NULL__;
    self.reload   = __NULL__;
    self.wepframe = W_ShockFrame;
    self.weapon_uses_sequences = TRUE;
    self.wep_nextframe = time + 0.05;
    // Same courtesy the hivehand extends: a weapon that can never be refilled
    // from the world must not be handed over completely dead.
    if (self.ammo_shockrifle <= 0)
        self.ammo_shockrifle = 1;
    W_SetCrosshairProfile(0, 0, 320, 1.2, TRUE);
};

void() W_ShockDrop =
{
    entity tgt = weapon_drop_target;

    tgt.ammo_shockrifle = self.ammo_shockrifle;
    self.ammo_shockrifle = 0;

    setmodel(tgt, SHOCK_WORLDMODEL);
    setsize(tgt, '-12 -12 0', '12 12 32');
    tgt.classname    = "weapon_shockrifle";
    tgt.solid        = SOLID_NOT;
    tgt.movetype     = MOVETYPE_TOSS;
    tgt.weapon       = WEP_SHOCKRIFLE;
    tgt.weapon_slot  = SLOT_PRIMARY;
    tgt.weap_draw    = W_ShockEquip;
    tgt.weap_drop_func = W_ShockDrop;
    tgt.pickupcopy   = W_ShockPickupCopy;
    tgt.touch        = weapon_touch;
    tgt.think        = weapon_become_solid;
    tgt.nextthink    = time + 0.7;
    tgt.effects      = tgt.effects | EF_DIMLIGHT;   // it glows in OpFor, lying there
};

void() weapon_shockrifle =
{
    precache_model(SHOCK_WORLDMODEL);
    precache_model(SHOCK_VIEWMODEL);
    precache_sound("weapons/shock_fire.wav");
    precache_sound("weapons/shock_draw.wav");
    precache_sound("weapons/shock_recharge.wav");

    setmodel(self, SHOCK_WORLDMODEL);
    setsize(self, '-12 -12 0', '12 12 32');
    self.classname     = "weapon_shockrifle";
    self.solid         = SOLID_TRIGGER;
    self.movetype      = MOVETYPE_TOSS;
    self.weapon        = WEP_SHOCKRIFLE;
    self.weapon_slot   = SLOT_PRIMARY;
    self.weap_draw     = W_ShockEquip;
    self.weap_drop_func = W_ShockDrop;
    self.pickupcopy    = W_ShockPickupCopy;
    self.touch         = weapon_touch;
    self.ammo_shockrifle = MAX_AMMO_SHOCKRIFLE;
    self.effects       = self.effects | EF_DIMLIGHT;
    W_RegisterMapWeapon(weapon_shockrifle);
};

#endif // SSQC

// ============================================================
//  CLIENT ONLY
// ============================================================

#ifdef CSQC

void() CSQC_PredictShockCommand =
{
    // Regrow first and unconditionally — see SH_ShockRegrow's note.
    SH_ShockRegrow(csqc_pred_time);

    if (input_buttons & 1)
    {
        if (SH_ShockTryFire(csqc_pred_time))
        {
            CSQC_MarkPendingWeaponAck();

            if (!pm_suppress_sounds)
            {
                sound(self, CHAN_WEAPON, "weapons/shock_fire.wav", 1, ATTN_NORM);
                CSQC_RecordPredictedWeaponSound();
                // Cyan, matching the bolt and the beam, instead of the generic
                // powder orange every other weapon wants.
                CSQC_MuzzleFlash(SHOCK_LIGHT_COLOUR);

                // The shooter's own bolt.  projectile_SendEntity hides the real
                // one from its owner, so without this the person firing would be
                // the only player who never sees the shot leave the gun.
                makevectors(input_angles);
                entity fake = spawn();
                setmodel(fake, SHOCK_BOLT_MODEL);
                setsize(fake, '0 0 0', '0 0 0');
                setorigin(fake, Shock_MuzzleOrigin());
                fake.velocity = v_forward * SHOCK_BOLT_SPEED;
                // FALSE now, matching Projectile_TypeIsHLModel: the bolt is a
                // view-facing sprite, not an IDST mesh, so there is no pitch to
                // negate (and nothing that reads these angles either).
                fake.angles   = W_ModelAngles(fake.velocity, FALSE);
                fake.movetype = MOVETYPE_NOCLIP;
                fake.solid    = SOLID_NOT;
                fake.drawmask = MASK_ENGINE;
                // shock_effect.mdl's only texture is blueChrome.bmp, flagged
                // FLATSHADE|CHROME, which FTE draws with rgbgen lightingdiffuse
                // -- a LIT chrome sliver in whatever light the room happens to
                // have, which at 2000 u/s reads as nothing at all.  OpFor draws
                // it kRenderTransAdd; FTE has no STUDIO_NF_ADDITIVE, so the
                // blend has to be forced from QC.  See Projectile_TypeIsAdditive.
                fake.effects  = fake.effects | EF_FULLBRIGHT | EF_ADDITIVE;
                // The escort light is hung by CSQC_Projectile_DrawLights
                // (cl_projectiles.qc), which walks entities by .model so it
                // catches this fake and the networked twin alike --
                // dynamiclight_add lasts one frame, so a light that FOLLOWS
                // anything has to be re-emitted per frame.
                //
                // classname is the trail walker's find() key; proj type + born
                // drive the sprite's 3-frame crackle through the predraw.
                fake.classname            = "csqc_fake_projectile";
                fake.csqc_projectile_type = PROJ_TYPE_SHOCK_BOLT;
                fake.proj_born            = cltime;
                fake.predraw              = CSQC_FakeSpriteProj_Predraw;
                fake.think    = CSQC_FakeProjectileExpire;

                // Retire on arrival so the local bolt disappears as the real one
                // detonates, rather than sailing on through the wall.
                vector s_src = self.origin + self.view_ofs;
                CSQC_WeaponTraceLine(s_src, s_src + v_forward * 8192,
                                     MOVE_NORMAL, self);
                if (trace_fraction < 1.0)
                    fake.nextthink = time + vlen(trace_endpos - fake.origin) / SHOCK_BOLT_SPEED;
                else
                    fake.nextthink = time + SHOCK_BOLT_LIFE;
                if (trace_fraction < 1.0)
                    CSQC_BulletImpact(trace_endpos, trace_plane_normal, SHOCK_DAMAGE, 0);
            }
        }
    }

    SH_ShockTickState(csqc_pred_time);
};

float(float elapsed) CSQC_ShockDisplayFrame =
{
    if (predicted_player.weaponstate == WS_DRAW)
        return SHOCK_SEQ_DRAW;
    if (predicted_player.weaponstate == WS_FIRE)
        return SHOCK_SEQ_FIRE;
    return SHOCK_SEQ_IDLE1;
};

void() CSQC_ShockDropClear =
{ self.ammo_shockrifle = 0; };

void() CSQC_ShockEquip =
{
    self.weapon_name         = SHOCK_DISPLAY_NAME;
    self.weapon_viewmodel    = SHOCK_VIEWMODEL;
    self.weapon_worldmodel   = SHOCK_WORLDMODEL;
    self.weapon_deploy_sound = SHOCK_DEPLOY_SOUND;
    self.csqc_predict_cmd    = CSQC_PredictShockCommand;
    self.csqc_predict_reload = __NULL__;
    self.csqc_display_frame  = CSQC_ShockDisplayFrame;
    self.csqc_drop_clear     = CSQC_ShockDropClear;
    self.weapon_uses_sequences = TRUE;
};

#endif // CSQC
