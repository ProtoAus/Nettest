# Proto's Quake

**A competitive multiplayer FPS mod built on the FTE Quake engine featuring client-side prediction, server reconciliation, GoldSrc-style movement, and 22 weapons from Counter-Strike 1.6, Half-Life 1, and Day of Defeat.**

![QuakeC](https://img.shields.io/badge/Language-QuakeC-orange)
![Engine](https://img.shields.io/badge/Engine-FTEQW-blue)
![Weapons](https://img.shields.io/badge/Weapons-22-green)
![Prediction](https://img.shields.io/badge/Client--Side_Prediction-Full-brightgreen)
![Lag Comp](https://img.shields.io/badge/Lag_Compensation-Server--Side-yellow)

---

## Key Features

| Networking | Gameplay | Weapons |
|:---|:---|:---|
| Client-side prediction with 128-command replay buffer | GoldSrc-style movement (bunnyhop, air strafe, ducking) | 22 weapons across 3 slots |
| Owner-only proxy snapshots for low-bandwidth sync | CS 1.6 stamina / landing fatigue system | Silencer toggle, burst fire, charge mechanics |
| Lag-compensated hitscan (`MOVE_LAGGED` traces) | Sprint, walk, crouch accuracy modifiers | Shell-by-shell reload, 2-stage scopes |
| Predicted doors, buttons, teleporters, ladders | Competitive round system with freeze time | Deterministic spread synced client/server |
| Smart reconciliation (prevents animation rollback) | Team Deathmatch & Elimination modes | Linear damage falloff per weapon |
| Predicted weapon fire, reload, sounds, shell casings | Death cam, spectator with 3 view modes | Physics-based shell casings & magazine drops |

---

## Networking Architecture

```
                         PREDICTION LOOP
    
    CLIENT                                          SERVER
    +---------------------+                +---------------------+
    |                     |   UDP Input    |                     |
    | 1. Capture Input    |--------------->| 4. Receive Command  |
    |    (WASD, mouse,    |                |    Apply to player  |
    |     buttons)        |                |                     |
    |                     |                | 5. PM_PlayerMove()  |
    | 2. Buffer Command   |                |    (authoritative)  |
    |    (128-slot ring)  |                |                     |
    |                     |                | 6. W_WeaponFrame()  |
    | 3. Predict Locally  |                |    (fire, reload)   |
    |    - PM_PlayerMove  |                |                     |
    |    - Weapon fire    |   Proxy Snap   | 7. Sync Proxy       |
    |    - Shell casings  |<---------------| PM_SyncPrediction   |
    |    - Muzzle flash   |  (owner-only)  |    Proxy()          |
    |    - Bullet impacts |                |                     |
    |                     |                +---------------------+
    | 8. Receive Snapshot  |
    |    Reset to server  |
    |    baseline         |
    |                     |
    | 9. Replay buffered  |
    |    commands after   |
    |    servercommandframe
    |                     |
    | 10. Render predicted|
    |     state           |
    +---------------------+
    
    RECONCILIATION DETAIL:
    +----------------------------------------------------------+
    | if (weapon action unchanged && prediction ahead):        |
    |   KEEP client state (prevents animation rollback)        |
    | else:                                                    |
    |   ACCEPT server state, replay from there                 |
    +----------------------------------------------------------+
```

### Prediction Pipeline

```
    Input Frame N        Input Frame N+1      Snapshot Arrives
    +-----------+        +-----------+        +-----------+
    | Capture   |        | Capture   |        | Reset to  |
    | Store in  |------->| Store in  |------->| server    |
    | ring[N]   |        | ring[N+1] |        | baseline  |
    | Predict   |        | Predict   |        |           |
    | locally   |        | locally   |        | Replay    |
    +-----------+        +-----------+        | ring[ack] |
                                              | through   |
                                              | ring[N+1] |
                                              +-----------+
    
    Ring Buffer: [cmd0][cmd1][cmd2]...[cmd127]  (wraps)
                                 ^         ^
                          server_ack    latest
```

### Brush Entity Prediction (Doors & Buttons)

```
    Client predicts door opening:       Server confirms:
    
    +--------+   USE    +--------+     +--------+
    | CLOSED |--------->| MOVING |     | MOVING |
    +--------+          +--------+     +--------+
                            |              |
                     Client ahead?    Server ahead?
                       YES: keep       YES: accept
                       client pos      server pos
```

---

## Weapon Arsenal

### Primary Weapons (Slot 1)

| Weapon | Origin | Mag | Damage | Spread | Fire Rate | Special |
|:---|:---|:---:|:---:|:---:|:---:|:---|
| **AK-47** | CS 1.6 | 30/90 | 16-8 | 0.012 + 0.07 move | Full-auto 0.1s | Bolt pull on draw |
| **M4A1** | CS 1.6 | 30/90 | 18-10 | 0.01 + 0.06 move | Full-auto 0.1s | Silencer toggle (alt-fire) |
| **AWP** | CS 1.6 | 10/20 | 120-90 | 0.03 + 0.10 move | Bolt 1.2s | 2-stage zoom scope |
| **Scout** | CS 1.6 | 10/30 | 90-65 | 0.02 + 0.08 move | Bolt 1.0s | 2-stage zoom scope |
| **G3SG1** | CS 1.6 | 20/60 | 60-40 | 0.02 + 0.08 move | Semi 0.25s | 2-stage zoom scope |
| **MP5** | CS 1.6 | 30/120 | 12-6 | 0.01 + 0.06 move | Full-auto 0.1s | |
| **M3 Super 90** | CS 1.6 | 8/24 | 6x12 pellets | 0.08 fixed | Pump 1.0s | Shell-by-shell reload |
| **M249** | Custom | 50/150 | 14-7 | 0.08 + 0.12 move | Full-auto 0.1s | Belt-fed LMG |
| **98K Karabiner** | DoD | 5/25 | 100-70 | 0.025 + 0.09 move | Bolt 1.05s | Bayonet stab (alt-fire) |
| **HL Shotgun** | HL1 | 8/24 | 6x8 pellets | 0.08 / 0.12 dbl | Pump 0.75s | Double-barrel alt-fire |
| **Flak Shotgun** | Custom | 24 | 6x8 pellets | 0.04 fixed | Pump 1.0s | No reserve, tight spread |
| **Grenade Launcher** | Custom | 6 | 110-20 (180u radius) | Projectile | 0.8s | Toss arc, impact/timer detonation |
| **Rebar Gun** | Custom | 12 | 75-60 | Hitscan | 0.6s | Visual projectile at impact |

### Secondary Weapons (Slot 2)

| Weapon | Origin | Mag | Damage | Spread | Fire Rate | Special |
|:---|:---|:---:|:---:|:---:|:---:|:---|
| **Desert Eagle** | CS 1.6 | 7/35 | 54-34 | 0.008 + 0.06 move | Semi 0.3s | High alpha damage |
| **Glock 18** | CS 1.6 | 20/40 | 18-10 | 0.01 + 0.05 move | Semi 0.15s | 3-round burst (alt-fire) |
| **.357 Revolver** | HL1 | 6/18 | 70-45 | 0.004 + 0.03 move | Semi 0.75s | Highest pistol damage |
| **Pistol** | Custom | 12/24 | 20-8 | 0.004 + 0.045 move | Semi 0.2s | Balanced sidearm |

### Melee Weapons (Slot 3)

| Weapon | Origin | Primary | Alt-Fire |
|:---|:---|:---|:---|
| **Knife** | CS 1.6 | Slash: 20 dmg, 64u range, 0.35s | Stab: 50 dmg, 72u range, 0.6s |
| **Crowbar** | HL1 | Swing: 25 dmg, 64u range, 0.5s | -- |
| **Wrench** | Custom | Swing: 25 dmg, 64u range, 0.6s | -- |

### Special Weapons

| Weapon | Origin | Mechanic |
|:---|:---|:---|
| **Gauss Gun** | HL1 | Primary: 20 dmg hitscan. Alt: **hold to charge** (40-200 dmg over 4s), drains ammo while charging, overcharge self-damage |
| **Crossbow** | HL1 | Projectile (speed 3000). 2-stage zoom scope. **Scoped damage: 120** vs unscoped: 50 |

---

## Movement System

Ported from **EzQuake's pmove.c** with GoldSrc-authentic physics.

```
    Movement Feature Map
    
    +------------------+     +------------------+     +------------------+
    |   GROUND MOVE    |     |    AIR MOVE      |     |   WATER MOVE     |
    |                  |     |                  |     |                  |
    | - Friction       |     | - Air strafing   |     | - Water accel    |
    | - Acceleration   |     | - Bunnyhopping   |     | - Water friction |
    | - Step climbing  |     | - Air crouch     |     | - Sinking (-60)  |
    | - Ramp following |     |   (crouch-jump)  |     | - No fall damage |
    | - Edge friction  |     | - Air step (1%   |     |                  |
    | - Sprint/Walk    |     |   penalty/unit)  |     +------------------+
    +------------------+     +------------------+
            |                        |
            v                        v
    +--------------------------------------------------+
    |              SHARED SYSTEMS                       |
    |                                                   |
    | Ducking        Smooth 0.4s transition, spline     |
    |                interpolation, hull height change   |
    |                                                   |
    | Stamina        CS 1.6 landing fatigue, exp decay  |
    |                framerate-independent               |
    |                                                   |
    | SlideMove      Multi-plane clip (8 bumps),        |
    |                ramp-seam fix, momentum preservation|
    |                                                   |
    | Ladders        GoldSrc-style, look-direction      |
    |                climbing with detach cooldown       |
    |                                                   |
    | Teleporters    Predicted client-side, optional     |
    |                velocity/angle preservation         |
    |                                                   |
    | Push Triggers  Additive/replace/tunnel/source      |
    |                modes, predicted both sides          |
    +--------------------------------------------------+
```

### Key Movement CVars

| CVar | Default | Description |
|:---|:---:|:---|
| `mv_airaccelerate` | 10 | Air acceleration (enables strafing) |
| `mv_stamina` | 1 | CS 1.6 landing fatigue |
| `mv_autohop` | 0 | Auto-bunnyhop on hold |
| `sv_sprintspeed` | -- | Sprint speed multiplier |
| `sv_walkspeed` | -- | Walk speed (hold +speed) |
| `pm_hull_height` | 56 | Player hull height |

---

## Project Structure

```
src/
+-- cl_progs.src                 # Client compile list
+-- sv_progs.src                 # Server compile list
|
+-- client/                      # CLIENT-SIDE (CSQC)
|   +-- cl_player.qc            # Prediction engine (seed/buffer/reconcile)
|   +-- cl_weapons.qc           # Weapon dispatch (function pointer system)
|   +-- cl_crosshair.qc         # Dynamic spread-reactive crosshair
|   +-- cl_hud.qc               # Health, ammo, weapon slots, pain flash
|   +-- cl_muzzleflash.qc       # Dynamic muzzle light effects
|   +-- cl_bulletimpact.qc      # Impact particles, lights, ricochet sounds
|   +-- cl_bulletholes.qc       # Persistent decal system (2048 capacity)
|   +-- cl_shells.qc            # Physics shell casings & magazine drops
|   +-- cl_brushsync.qc         # Door/button prediction & reconciliation
|   +-- cl_push.qc              # Push trigger linked list (client)
|   +-- cl_teleport.qc          # Teleporter linked list (client)
|   +-- cl_ladder.qc            # Ladder linked list (client)
|   +-- cl_spectate.qc          # Death cam, 1st/3rd person, freecam
|   +-- cl_debuginfo.qc         # Impact debug visualization
|   +-- cl_main.qc              # CSQC entry points
|   +-- cl_customdefs.qc        # Client globals
|
+-- server/                      # SERVER-SIDE (SSQC)
|   +-- sv_player.qc            # Spawn, teams, fall damage, proxy sync
|   +-- sv_weapons.qc           # Damage, pickup, drop, weapon selection
|   +-- sv_main.qc              # Round lifecycle, freeze time, elimination
|   +-- sv_combat.qc            # Combat helpers
|   +-- sv_doors.qc             # func_door, func_button (movers)
|   +-- sv_push.qc              # trigger_push (jump pads)
|   +-- sv_teleport.qc          # trigger_teleport
|   +-- sv_ladder.qc            # trigger_ladder
|   +-- sv_use.qc               # +use system (tracebox + cone fallback)
|   +-- sv_brushsync.qc         # Brush entity replication to CSQC
|   +-- sv_customdefs.qc        # Server globals, round state
|
+-- shared/                      # SHARED (compiled by both progs)
|   +-- sh_pmove.qc             # Player movement physics (GoldSrc port)
|   +-- sh_weapons.qc           # Weapon IDs, states, field declarations
|   +-- sh_weapon_logic.qc      # Spread hashing, stance modifiers
|   +-- sh_weapon_standard.qc   # Generic state machines, hitscan helpers
|   +-- sh_customdefs.qc        # Stats, events, precache
|   |
|   +-- weapons/                 # PER-WEAPON FILES (22 weapons)
|       +-- sh_wpn_csak47.qc    #   Each file contains:
|       +-- sh_wpn_csm4a1.qc    #   - Constants (damage, spread, timing)
|       +-- sh_wpn_csdeagle.qc  #   - Shared state machine
|       +-- sh_wpn_csknife.qc   #   - Server: fire, reload, equip, drop
|       +-- ...                  #   - Client: prediction, display frame,
|                                #     CSQC equip, drop clear
+-- menu/
    +-- m_teamselect.qc          # Team selection UI
    +-- m_scoreboard.qc          # Live scoreboard
    +-- m_createserver.qc        # Server creation menu
```

---

## Technical Deep Dives

### Client-Side Prediction

The prediction system uses a **3-phase architecture** ensuring instant input response while maintaining server authority:

**Phase 1 - Seeding:** Before the first proxy snapshot arrives, `predicted_player` is seeded from the engine's local entity for immediate responsiveness.

**Phase 2 - Buffering:** Each input frame is stored in a 128-slot ring buffer and applied instantly to the predicted player entity. Weapon actions (fire, reload, switch) execute immediately with predicted sounds, shell casings, and muzzle flash.

**Phase 3 - Reconciliation:** When a server proxy snapshot arrives:
1. Reset predicted state to the server-confirmed baseline
2. Replay all buffered commands from `servercommandframe` to present
3. Smart guards prevent animation rollback when local prediction is already ahead

### Deterministic Spread

Weapons use a **sine-based hash function** to generate identical spread patterns on client and server:

```
hash(seed) = frac(sin(seed * 12.9898 + 78.233) * 43758.5453)
```

The `wep_action_id` counter increments per shot, ensuring each bullet's spread is reproducible. Pellet-based weapons (shotguns) offset by pellet index for unique per-pellet jitter.

**Stance modifiers** apply multiplicatively:
- Crouching (grounded): 0.4x spread
- Airborne/landing: penalty decays over time
- Sustained fire: penalty builds per shot, decays when resting

### Lag Compensation

Server-side hitscan traces use FTE's `MOVE_LAGGED` flag, which automatically traces against **historical player positions** based on the attacker's latency. Combined with client-side predicted impacts, this creates a system where:
- Shooter sees instant bullet impact (predicted)
- Server validates the hit against rewound positions
- Other players see the impact via multicast events

### Debug Visualization

`cl_debug_impacts 1` renders 3D crosshairs at impact points:
- **Green** = client-predicted hit position
- **Purple** = server-authoritative hit position

Allows real-time comparison of prediction accuracy vs server authority with 10-second persistence and alpha fade-out.

---

## Game Modes

### Team Deathmatch
Standard respawn-based team combat with configurable death delay.

### Elimination
Round-based, no respawn. Last team standing wins. Features:
- **Freeze time** — configurable pre-round period (WASD and attack blocked, jumping/crouching/weapon switching allowed)
- **Round phases** — Freeze -> Active -> Round End -> Next Round
- **Death cam** — 3-second delay before spectator transition
- **Spectator modes** — First-person, third-person follow, freecam

### Networked Stats
Game state is pushed via `clientstat()` for efficient HUD rendering:
- Round timer, phase, number
- Team scores, winning team
- Freeze time remaining
- Death delay countdown
- Player team assignment

---

## Visual Effects

| System | Implementation | Details |
|:---|:---|:---|
| **Bullet Holes** | Linked-list decal pool | 2048 max, surface-aligned sprites, tracks moving brushes |
| **Shell Casings** | Physics entities | MOVETYPE_TOSS, bounce sounds, surface-settling orientation |
| **Magazine Drops** | Physics entities | Weapon-specific models (pistol, rifle mags) |
| **Muzzle Flash** | Dynamic light | 300-unit radius, 0.1s warm-orange fade, predicted instantly |
| **Bullet Impact** | Particles + light | te_gunshot particles, 60u light, ricochet sounds (5 variants) |
| **Dynamic Crosshair** | Spread-reactive | Gap scales with movement speed, stance, fire penalty |
| **Pain Flash** | HUD overlay | Red screen flash on damage, 0.4s fade |
| **Scope Overlay** | Full-screen vignette | Circular scope graphic for sniper weapons |

---

## Building

Requires the [FTEQW engine](https://www.fteqw.org/) and its QuakeC compiler (fteqcc).

```bash
# Compile server progs
fteqcc -src src sv_progs.src

# Compile client progs  
fteqcc -src src cl_progs.src
```

---

*Built with QuakeC on the FTE Quake engine.*
