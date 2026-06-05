// ============================================================================
//  server/sv_grapple.qc  —  grappling hook (sv_grappling)
//
//  Press WEAPON_IMPULSE_GRAPPLE to fire a gravity-affected hook
//  projectile.  On world contact the hook anchors, plays hook.wav, and
//  after sv_grappling_pull_delay seconds begins reeling the player
//  toward the anchor via an additive force (gravity still applies so
//  the player swings under it).  Re-press releases the hook; getting
//  within sv_grappling_release_dist of the anchor also releases.
//
//  Per-player state declared in sv_customdefs.qc:
//      .entity grapple_hook;
//      .float  grapple_attached;
//      .float  grapple_pull_sound_at;
//      .float  grapple_next_loop;
//
//  Hook entity classname "grapple_hook" + a precached visible model so
//  the standard SSQC→CSQC entity broadcast carries position to clients
//  for the rope visual.  Owner linkage is via the standard .owner
//  field plus an owner_entnum scalar that CSQC reads to look up the
//  rope's player-side endpoint.
// ============================================================================

// Tiny placeholder model so the engine assigns a real modelindex and
// broadcasts the entity to clients (without a valid modelindex, the
// entity never reaches CSQC and the rope can't be drawn).  Visibility
// of the bubble itself is suppressed via EF_NODRAW below — clients see
// only the rope.  progs/s_null.spr was tried first but isn't shipped
// with the gamedir; s_bubble.spr is confirmed-present.
const string GRAPPLE_HOOK_MODEL = "progs/s_bubble.spr";

// CSQC reads this to identify rope-owner pairs without needing access
// to .owner (which doesn't replicate).
.float owner_entnum;

void(entity player) W_GrappleRelease;
void()             W_GrappleHookTimeout;
void()             W_GrappleHookTouch;
void()             W_GrappleEngage;

// ----------------------------------------------------------------
//  Release path — used by re-press, attach-distance, miss-timeout,
//  player death / disconnect.
// ----------------------------------------------------------------
void(entity player) W_GrappleRelease =
{
    // Snapshot whether there was actually anything to release BEFORE
    // we tear it all down — used to gate the disconnect sound so
    // PlayerSpawn's defensive release-on-respawn doesn't play it on
    // every fresh life.
    float had_rope = (player.grapple_hook != world)
                  || player.grapple_rope_active
                  || player.grapple_attached;

    if (player.grapple_hook)
    {
        remove(player.grapple_hook);
        player.grapple_hook = world;
    }
    player.grapple_attached    = 0;
    player.grapple_pull_sound_at = 0;
    player.grapple_next_loop   = 0;
    // Clear the rope-render flag so CSQC stops drawing.  Anchor stays
    // at its last value — irrelevant once the flag is 0.
    player.grapple_rope_active = 0;
    if (had_rope)
    {
        // Announce the disconnect on a separate channel so it isn't
        // clobbered by the CHAN_BODY clear right below — CHAN_BODY is
        // the looping pull-sound channel, so silencing it cuts the
        // loop without cutting this one.
        sound(player, CHAN_AUTO,
            "sounds/player/grappledisconnect.wav", 1, ATTN_NORM);
    }
    // Cut any in-flight loop on CHAN_BODY.
    sound(player, CHAN_BODY, "", 0, ATTN_NORM);
};

// ----------------------------------------------------------------
//  Hook entity touch — invoked by the engine when the projectile
//  collides.  Self is the hook entity.
// ----------------------------------------------------------------
void() W_GrappleHookTouch =
{
    // Only attach to static brushwork.  Bouncing off players / other
    // projectiles would let opponents grief the rope so we just ignore.
    if (other.classname == "player")
        return;
    if (other.solid == SOLID_TRIGGER)
        return;

    self.movetype = MOVETYPE_NONE;
    self.velocity = '0 0 0';
    self.avelocity = '0 0 0';
    self.touch    = __NULL__;
    self.nextthink = 0;             // cancel miss-timeout

    if (self.owner && self.owner.grapple_hook == self)
    {
        self.owner.grapple_attached    = 1;
        self.owner.grapple_pull_sound_at = time + cvar("sv_grappling_pull_delay");
        self.owner.grapple_next_loop   = 0;
        sound(self, CHAN_AUTO, "sounds/player/hook.wav", 1, ATTN_NORM);

        // Ground-stick breaker: if the player is standing on the
        // floor when the hook lands, the per-tick pull's ~23 u/s
        // vertical component never exceeds PM_CategorizePosition's
        // `velocity_z > 180` cut-off, so the ground-snap trace
        // pins them every tick.  A one-shot jump-strength impulse
        // gets them airborne so the pull can take over.
        if (self.owner.flags & FL_ONGROUND)
        {
            float lift = cvar("sv_grappling_attach_lift");
            if (lift <= 0) lift = 270;
            self.owner.velocity_z = self.owner.velocity_z + lift;
            self.owner.flags = self.owner.flags & ~FL_ONGROUND;
        }
    }
};

// ----------------------------------------------------------------
//  Hook entity miss-timeout.  Self is the hook entity.
// ----------------------------------------------------------------
void() W_GrappleHookTimeout =
{
    if (self.owner && self.owner.grapple_hook == self)
        W_GrappleRelease(self.owner);
    else
        remove(self);
};

// ----------------------------------------------------------------
//  Engage — spawns the hook projectile + arms rope state.  Shared
//  body for the legacy `impulse 9` toggle (W_GrappleImpulse) and the
//  new press-and-hold rising-edge path (W_GrappleHeldTick).
// ----------------------------------------------------------------
void() W_GrappleEngage =
{
    entity h = spawn();
    h.classname  = "grapple_hook";
    h.owner      = self;
    h.owner_entnum = num_for_edict(self);
    h.movetype   = MOVETYPE_TOSS;       // gravity
    h.solid      = SOLID_BBOX;
    setmodel(h, GRAPPLE_HOOK_MODEL);
    setsize(h, '-2 -2 -2', '2 2 2');
    // Suppress the placeholder bubble visually — the entity still
    // broadcasts (CSQC needs to find it via modelindex to draw the
    // rope), but the sprite itself stays invisible.
    h.effects = h.effects | EF_NODRAW;
    makevectors(self.v_angle);
    // Spawn at waist, slightly forward so it doesn't immediately touch
    // the player's own bbox.
    setorigin(h, self.origin + self.view_ofs + '0 0 -16' + v_forward * 12);
    h.velocity   = self.velocity
                 + v_forward * cvar("sv_grappling_launch_speed");
    h.touch      = W_GrappleHookTouch;
    h.think      = W_GrappleHookTimeout;
    float life = cvar("sv_grappling_max_life");
    if (life <= 0) life = 5;
    h.nextthink  = time + life;

    self.grapple_hook = h;
    self.grapple_attached = 0;
    self.grapple_pull_sound_at = 0;
    self.grapple_next_loop = 0;
    // Set the CSQC-facing rope-active flag IMMEDIATELY on this tick so
    // Weapon_LowerBlocksFire sees rope_active=1 inside the same-tick
    // W_WeaponFrame (which runs in PlayerPreThink, AFTER CheckImpulses
    // dispatches us, but BEFORE W_GrapplePullTick would otherwise write
    // the flag on the next tick).  Anchor is set on the next PullTick
    // — the lower envelope only reads rope_active, so the anchor lag
    // doesn't affect the fire gate.
    self.grapple_rope_active = 1;

    sound(self, CHAN_WEAPON, "sounds/player/grappling.wav", 1, ATTN_NORM);
};

// ----------------------------------------------------------------
//  Impulse dispatch (legacy toggle) — called from W_CheckImpulses
//  with self = player.  Kept so existing `bind <key> "impulse 9"`
//  user binds keep working as the original press-to-fire /
//  press-to-release toggle.  The new press-and-hold path is
//  W_GrappleHeldTick below.
// ----------------------------------------------------------------
void() W_GrappleImpulse =
{
    if (!cvar("sv_grappling"))
        return;
    if (self.is_dead || self.health <= 0)
        return;

    // Re-press while a hook is alive — release and bail.  Matches the
    // legacy "press to fire, press to release" toggle behaviour.
    if (self.grapple_hook)
    {
        W_GrappleRelease(self);
        return;
    }

    W_GrappleEngage();
};

// ----------------------------------------------------------------
//  Press-and-hold edge tick — called from PlayerPreThink BEFORE
//  W_GrapplePullTick so a falling-edge release on the same tick
//  clears self.grapple_hook before PullTick re-asserts
//  grapple_rope_active = 1.
//
//  Rising edge (held, !was_held, no live hook): engage.
//  Falling edge (!held, was_held, hook alive): release.
//
//  Auto-release reasons (timeout, distance, respawn) still fire
//  independently — held_last latches the BUTTON state, so if the
//  hook auto-released while the player is still holding the bind,
//  pm_grapple_held_last stays 1 → no spurious re-engage every tick.
//  A new engage requires letting go and re-pressing.
// ----------------------------------------------------------------
void() W_GrappleHeldTick =
{
    if (!cvar("sv_grappling"))
    {
        // sv_grappling disabled mid-game: clear the latch so when it
        // re-enables, the next press registers as a fresh rising edge
        // instead of being eaten by stale was_held.
        self.pm_grapple_held_last = 0;
        return;
    }
    if (self.is_dead || self.health <= 0)
    {
        self.pm_grapple_held_last = 0;
        return;
    }

    float held     = (input_buttons & PM_BTN_GRAPPLE) ? 1 : 0;
    float was_held = self.pm_grapple_held_last;

    if (held && !was_held && !self.grapple_hook)
    {
        // Rising edge → spawn the hook.
        W_GrappleEngage();
    }
    else if (!held && was_held && self.grapple_hook)
    {
        // Falling edge → release the hook.  Mirrors what re-pressing
        // impulse 9 does under the legacy toggle path.
        W_GrappleRelease(self);
    }

    self.pm_grapple_held_last = held;
};

// ----------------------------------------------------------------
//  Per-tick pull — called from PlayerPreThink for every alive player.
//  Reads time-since-last-tick from `frametime` to keep the additive
//  acceleration framerate-independent.
// ----------------------------------------------------------------
void() W_GrapplePullTick =
{
    // ---- Rope-render state for CSQC ----
    // Maintain the synced (grapple_rope_active, grapple_anchor) pair
    // on EVERY tick the hook exists — during flight (gravity-affected
    // projectile) and attached.  CSQC reads these via the prediction
    // proxy to draw the rope without needing access to the server-only
    // hook entity.
    if (self.grapple_hook)
    {
        self.grapple_anchor      = self.grapple_hook.origin;
        self.grapple_rope_active = 1;
    }
    else
    {
        self.grapple_rope_active = 0;
    }

    if (!self.grapple_attached)
        return;
    if (!self.grapple_hook)
    {
        W_GrappleRelease(self);
        return;
    }

    vector to_anchor = self.grapple_hook.origin - self.origin;
    float  dist      = vlen(to_anchor);
    float  release   = cvar("sv_grappling_release_dist");
    if (release <= 0) release = 48;

    if (dist <= release)
    {
        W_GrappleRelease(self);
        return;
    }

    vector pull_dir = to_anchor * (1 / dist);

    // Add velocity along the rope, capped at sv_grappling_pull_max_speed
    // projected onto pull_dir.  Velocity perpendicular to the rope is
    // untouched, so gravity-driven fall and lateral swing are preserved.
    float v_along = self.velocity * pull_dir;
    float cap     = cvar("sv_grappling_pull_max_speed");
    if (cap <= 0) cap = 900;
    if (v_along < cap)
    {
        float add = cvar("sv_grappling_pull_force") * frametime;
        if (v_along + add > cap)
            add = cap - v_along;
        if (add > 0)
            self.velocity = self.velocity + pull_dir * add;
    }

    // Note: the per-tick FL_ONGROUND strip that previously sat here
    // was removed by user request.  It kept the player airborne for
    // the entire pull but as a side effect prevented PM_CheckJump
    // from firing on ground (pm_onground was always FALSE entering
    // pmove).  Now the one-shot lift impulse in W_GrappleHookTouch
    // gets the player airborne at attach time, and the categorize
    // ground-snap suppress in shared/sh_pmove.qc keeps them airborne
    // while pulling — unless they press jump, in which case the
    // suppress yields so the jump impulse + the post-jump grace
    // window takes over.  Net effect: a player who lands back on
    // ground mid-pull can jump again.

    // Looped pull sound: first emission delayed by
    // sv_grappling_pull_delay (so hook.wav is audible standalone), then
    // re-emit every sv_grappling_loop_interval seconds on CHAN_BODY.
    // Re-emitting on the same channel cleanly replaces the prior
    // instance — set the interval to your wav's exact length for a
    // seamless loop, or just under it for a slight crossfade.
    if (time >= self.grapple_pull_sound_at
     && time >= self.grapple_next_loop)
    {
        sound(self, CHAN_BODY, "sounds/player/grapplingpull.wav",
            1, ATTN_NORM);
        float loop_iv = cvar("sv_grappling_loop_interval");
        if (loop_iv < 0.05) loop_iv = 0.70;
        self.grapple_next_loop = time + loop_iv;
    }
};
