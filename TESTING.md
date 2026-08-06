# Owed in-game checks — monster AI programme

Things the headless harness **cannot** verify, listed newest-first. Everything not
listed here has been driven headlessly and is backed by numbers in the session log.

The harness limits that create this list:

- ~~**Bots have no netchan.**~~ **LIFTED in Patch 127** — see below. A real client
  now runs headlessly, so CSQC entity delivery, wire format, `setmodel` results and
  every `print()` in CSQC are all verifiable without a window.
- **Nothing renders.** Animation, model orientation, muzzle positions and beam
  visuals are still invisible: the headless renderer replaces `SCR_UpdateScreen`
  wholesale, so `CSQC_UpdateView` — and therefore every `predraw` — never runs.
- **Sound is not audible.** Precache is verifiable; playback is not.

---

## PATCH 128 — the assassin's trigger, and corpses that bleed

### The assassin had never fired a shot

`monster_human_assassin` / `monster_male_assassin` — **504 placements**. `hassassin.mdl`'s
`shoot` sequence raises event code **1** (`ASSASSIN_AE_SHOOT1`, `hassassin.cpp:57`), and
`Assassin_ClassInit` inherited `Grunt_Event`, whose lowest handled code is 2. Her shoot fell
off the end of the dispatch; her grenade toss **is** code 2 and was swallowed by the grunt's
reload no-op. They chased you and mimed.

Now `Assassin_Event`, with HL's escalating accuracy (`hassassin.cpp:201-210`): the cone
opens to 0.10 after a two-second lull and walks shut by 0.01 per round to a floor of 0.02.
Sustained fire is what makes her dangerous; breaking the streak is the counter.

**Measured**: `[ai] shots: grunt=0 barney=0 assassin=15` on fresh progs.

Her grenade handler is written but **inert on purpose** — `hassassin.cpp:688` gates the
throw on `m_iFrustration > 2`, a counter that only climbs when she cannot reach or hit you.
Handing her grenades without it would make her open every fight with one.

### Corpses — and a correction to our own comment

`sv_ai_core.qc` said *"Corpses do not block. HL makes them non-solid for the same reason"*
and went `SOLID_NOT`. **Half-Life does not.** `schedule.cpp:451-468` has the
`pev->solid = SOLID_NOT;` line **commented out** and squashes the bbox to a one-unit-tall
pancake instead — solving the exact problem (bodies blocking a doorway) without giving up
the body. That one line was why nothing about corpse damage worked.

`BecomeDead()` (`combat.cpp:518-532`) is now mirrored exactly: stays `DAMAGE_YES`, gets
`max_health/2` as its own gib pool, and `max_health` is repurposed as a blood-decal budget.

Damage type arrives through a new `sv_dmg_bits` global — 0 means bullet, and only the
handful of non-bullet sources set it. That is 8 edits instead of 58, and the same shape as
the `sv_in_radius_explosion` flag directly above it.

**Measured, `sv_ai_corpsetest 1`:**

```
[corpse] killed "monster_headcrab": deadflag=2 solid=3 takedamage=1 health=5 size_z=1
[corpse] 10 bullets: hits=10 gibs=0 (gibs MUST be 0) health=5
[corpse] club swings to gib: 17 (chips=16 gibs=1)
```

Bullets bleed a body and never break it — `DMG_BULLET` is deliberately absent from
`DMG_GIB_CORPSE` (`cbase.h:638`). Club/blast/sonic/crush chip it by `damage * 0.1` and the
hit that lands over the remainder tears it apart.

**Three defects the numbers caught, all fixed:**

1. `max_health` was never recorded at spawn, so the corpse pool was derived from a health
   that was already zero — every body came out at 1 HP and burst on the first swing.
2. A freed edict keeps returning its old field values for the rest of the frame, so a
   shotgun's remaining pellets or a radius blast walking its list would re-enter the corpse
   branch and gib the same body repeatedly. `Monster_Gib` now tears down the identity
   *before* the remove.
3. `AI_PublishMonsterModels` rebuilt its set from `monster_chain`, which corpses **leave**
   on death — so when the last live grunt died, every grunt corpse stopped being traceable
   by the shooter's own client. Bodies bled only while one of their kind was still alive.
   The set now accumulates and never forgets.

**Owed check A — gib appearance.** Gibs are CSQC-spawned, and `setcustomskin` is live for
CSQC (`pr_csqc.c:7152`) even though it is `PF_Fixme` on the server — so `hgibs.mdl`'s 11
submodels and `agibs.mdl`'s 4 are selectable **today**, without the engine bodygroup work.
Human classes throw 5 chunks, alien 4, launch speed scaled by overkill (×0.7 / ×2 / ×4).
None of it has been looked at.

**Owed check B — corpses are solid now.** They keep their x/y footprint and collapse to one
unit tall. Walk over a pile of bodies and check nothing snags. This is the one item with a
real fallback if it feels wrong (per-class `SOLID_NOT`).

Regression after both: five maps, `BAD=0` on both self-tests, errors 0, **crashaddr
unchanged at 1824**.

---

## PATCH 127 — the headless CLIENT, and the four HL equipment weapons

### The harness changed: a real client, no window

FTE ships a null renderer (`engine/client/vid_headless.c`, `QR_HEADLESS`) and
`config_fteqw.h` leaves `HEADLESSQUAKE` defined, so the shipped `fteqw64.exe`
can run as a **real connected client with no window**:

```
fteqw64.exe -game quakers -nohome +set vid_renderer headless \
    +developer 1 +sv_debug_ent_types 1 +connect 127.0.0.1:27500
```

Driver: `/c/tmp/hlclient.sh <map> <seconds> <tag> [server args...]`.

Three things had to be right before it produced anything:

| symptom | cause |
|---|---|
| "Connection lost or aborted" every retry | `+set port 27500` is ignored; the server binds an ephemeral port. Use **`-port 27500`** |
| client in-game but every test stalls "waiting for a live in-world player" | a client with nobody at the keyboard sits in **team select** forever at `SOLID_NOT`/`MOVETYPE_NONE`. New **`sv_autojoin 1`** takes the same path the menu button does |
| every developer-gated CSQC `print()` silently missing | `cfg/default.cfg:115` sets `developer 0` and execs **after** every `+set` on the command line. Pass the bare command form `+developer 1` as well |

### The grenade: both halves now proven correct, so it is not what it looked like

`sv_proj_test 1` spawns one **world-owned** HL grenade 64 units in front of you.
That matters because `projectile_SendEntity` hides a projectile from its owner —
so in single player the replicated path is **only** ever exercised by a monster's
grenade, and the player's own is always the CSQC-predicted fake.

Driven through the headless client, the CSQC entity is created, holds
`modelindex=388` and `drawmask=1`, sits at a sane origin, and **survives the full
24 s of the test** (48 consecutive live samples). Server side was already proven
last patch. Both halves are correct; whatever you saw is in the final draw, which
is the one step the headless renderer cannot reach.

**Owed check 1.** `sv_proj_test 1` in-game. If you can see that grenade, the
replication path is fine and the grunt's throw differs for some other reason; if
you cannot, it is the renderer and the next step is a `predraw` breakpoint.

### While packing: the CSQC half of Patch 126 had never shipped

`quakers_csprogs.pk3` contained the montrace work but **not** the `[proj]`
diagnostic — `cl_progs.src` was compiled before that edit and the pack ran on the
stale `.dat`. So Patch 126's monster-collision bleeding may not have been in the
build you played. It is now. `/c/tmp/hlclient.sh` refuses to launch if any
`client/` or `shared/` source is newer than the packed pk3, checked **separately**
from the server's own staleness test.

### The four weapons — satchel, tripmine, snark, hivehand

Ported from `satchel.cpp`, `tripmine.cpp`, `squeakgrenade.cpp`, `hornetgun.cpp` +
`hornet.cpp`. Sequence indices were read out of the models, not the enums, and
they agree. Damage from `valve/skill.cfg`: satchel 150, tripmine 150, snark
bite 10 / pop 5 / health 2, hornet 5. Radii are HL's derived `damage * 2.5`.

All four use the mount's **GoldSrc IDST viewmodels directly**
(`weapon_uses_sequences = TRUE`) — no converted IDPO copies needed.

**The `w_tripmine.mdl` compromise turned out not to exist.** HL draws the deployed
mine as `v_tripmine.mdl` at body 3; FTE cannot select that (`gl_hlmdl.c:1767`
hardcodes `entity_body = 0`, and `cl_ents.c:5109` clears `customskin` for every
replicated entity). But `p_tripmine.mdl` has one bodypart, `reference_tripmine` —
already the bare mine with no hands, which is exactly what body 3 selected.

Verified headlessly with `sv_hlequip_test 1` (fires each weapon once, 2 s apart,
then counts what is alive):

```
[tripmine] placed at 536 272 -232 normal=0 0 1 surface="worldspawn"
[tripmine] armed, beamfrac=0.0644
[tripmine] beam broken: was 0.0644 now 0.0096 by "monster_snark"
[tripmine] delaydeath -> explode ; beams still alive=0
[hlequip] satchels=0 (thrown AND detonated) mines=0 snarks=1 hornets=2 beams=0
[hlequip] ammo left: satchel=4 tripmine=4 snark=14 hornet=6
```

The snark walking into the tripmine's laser was not staged — it is a behavioural
proof that the snark hunts and that the beam-break test fires on a real mover.

**Two real bugs the test caught, both since fixed:**

1. **The two hornets annihilated each other** — `[hornet] died on "hornet" after
   0 s`. `hornet.cpp:369` ignores another hornet by modelindex *and* goes
   `SOLID_NOT` so the pair stop re-touching. I had also collapsed `TrackTouch`
   into `DieTouch`: a **tracking** hornet bounces off anything it will not hurt
   (`hornet.cpp:376-388`) and only the fast dart dies on contact. Now `hornets=2`.
2. **`.takedamage` is not the test for a player in this mod** — players sit at
   `DAMAGE_NO` and are accepted inside `W_CanDamageTarget` (`sv_weapons.qc:1149`).
   Gating on it alone meant a snark bit crates and monsters but walked straight
   over the person it was hunting. Same fix in the hornet.

Also fixed: the snark's kill credit. `squeakgrenade.cpp:266` clears `pev->owner`
on the first bounce — that is what lets a snark turn round and bite its thrower —
but keeps `m_hOwner` for attribution. Collapsing the two handed every snark kill
to the snark; `.snark_owner` is now separate.

**Owed check 2 — the satchel's two-viewmodel dance.** Throwing swaps you to
`v_satchel_radio.mdl`; `+attack2` detonates every charge you own anywhere on the
map and the idle swaps the satchel back. The state machine is measured, the model
swap is not.

**Owed check 3 — tripmine placement orientation.** `p_tripmine.mdl` is authored to
hang off a player's hand, so its origin/rotation may not sit flush against a wall
the way `v_tripmine`'s world bodygroup would. The mine is placed at
`endpos + normal*8` facing `vectoangles(normal)`, which is HL's own maths; if it
looks wrong it is the model's pivot, not the placement.

**Owed check 4 — the tripmine laser.** It rides the shipped `env_beam` transport
(`CSQC_ENT_ENV_BEAM`) at HL's colour `0 214 198`, brightness 64, width 10. The
beam entity is created, sent and cleaned up (`beams still alive=0` measured at the
moment of death) — but nobody has looked at it.

**Owed check 5 — the hornet's flight.** Tracking uses HL's turn-rate falloff
(`hornet.cpp:243`: the wider the turn the slower it goes). Two speeds, red 600 /
orange 800, two-in-five red. Measured to exist; not watched.

Regression after all of the above: five maps, `schedules: 27 built, 110/384 tasks
used, BAD=0`, `squad accounting: BAD=0`, errors 0 on every map, **crashaddr
unchanged at 1824**.

---

## PATCH 126 — NPC fidelity from the Half-Life SDK

**The SDK is on this machine**: `/c/msys64/home/Lex/halflife/dlls`, 104 `.cpp` files.
Everything in this section was read out of it rather than recalled, and each item
below cites the file and line it came from. That changes the character of this
work — these are ports, not reimplementations.

### Verified headlessly (numbers in the session log)

| what | evidence |
|---|---|
| Barney's fire sound | was `weapons/hks*.wav`, the **player's MP5** (`mon_grunt.qc:115`). Now `barney/ba_attack2.wav` with HL's lopsided pitch shift (`barney.cpp:356-364`) |
| one report per burst | HL emits the gun sound on **BURST1 only** (`hgrunt.cpp:913-937`); ours played it on all three codes, stacking three overlapping samples per burst |
| shotgun grunts | `HGRUNT_SHOTGUN` had been declared and never read, so `weapons/sbarrel1.wav` was precached and never once played. Now one 5-pellet blast at `VECTOR_CONE_15DEGREES` (`hgrunt.cpp:828`, `sk_hgrunt_pellets2`) |
| Barney's accuracy | was the grunt's 5°; `barney.cpp:355` is `VECTOR_CONE_2DEGREES` |
| provoke escalation | measured end-to-end: hit 1 aimed away → `dot=-1 stray`, `memory=1` (SUSPICIOUS), still friendly; hit 2 → `memory=3`, `enemy=PLAYER`; then `forgiven=1` exactly 6 s later at `sv_ai_grudge_time 6` |
| scientists provoke instantly | `scientist.cpp:771-778` has no facing test and no line — and `SC_MAD`/`SC_SHOT` genuinely do not exist in `sentences.txt`, so that is deliberate on Valve's part, not an omission |
| the complaining scientist | `SC_SCARED` is HL's `TLK_NOSHOOT` group (`scientist.cpp:745`), spoken by a **bystander** when a player *damages* a talker (`talkmonster.cpp:1193`). Ours fired it on every gunshot within 1280 u. Measured `noshoot=1` per provoke now |
| monster model broadcast | `published 4 monster modelindexes to clients` on `hl_c01_a1` |

### Ground speeds — the animation is the speed

HL never stores monster speeds as constants: `GetSequenceInfo`
(`animation.cpp:245-249`) derives them from each sequence's own baked
`linearmovement`, so the gait and the travel rate physically cannot disagree.
Ours were hand-typed and **almost every run was about half its real value** —
which is exactly "they move at walking speed while using their running animations".

Measured off the shipped models with the programme's struct reader:

| | ours was | real | |
|---|---|---|---|
| barney | 160 | **362.4** | 44% of its own run cycle |
| hgrunt | 180 | **304.0** | |
| scientist | 170 | **275.4** | (RUN_SCARED is 315.5) |
| houndeye | 200 | **409.6** | |
| assassin | 220 | **483.4** | the fastest thing in HL |
| gargantua | 180 | **356.0** | |
| headcrab | 150 | **50.2** | *slower* — its threat is the leap, not the chase |
| zombie | 40 | **72.5** | |

Flyers and swimmers (controller, ichthyosaur, leech, apache, osprey) measure 0
because HL moves them in code, not animation — their hand-set values were left
alone.

### Where the walk animation went

`SCHED_FOLLOW` asked for `ACT_RUN` unconditionally, and following is the only
movement most allies ever do — so the walk cycle was effectively unreachable in
normal play. HL picks by **distance**, not by schedule:
`TASK_MOVE_TO_TARGET_RANGE` (`AI_BaseNPC_Schedule.cpp:429-436`) walks under 190,
runs at 270 or more, and holds in between (the SDK's own comment: "overlap the
range to prevent oscillation").

*My plan said HL picks the gait by monster state. That was wrong — it is baked
per-schedule and per-distance. Corrected against the source before implementing.*

---

## Owed in-game checks from Patch 126

Client-visible, so headlessly unverifiable — **please check these with the new
`fteqw64.exe`**:

1. **NPCs bleed when you shoot them.** Monsters are engine entities and were
   invisible to CSQC's trace, so the shooter's bullet passed *through* them and
   the local impact landed on the wall behind — as concrete, with a bullet hole,
   at the wrong depth. Everyone else saw it correctly, because they get the
   server's version; the shooter is the one player `W_ImpactEffectSend` skips.
   Now ray-vs-AABB over `getentity()` (`cl_monstertrace.qc`).
   Console check: `developer 1` prints `[montrace] models=N sweeps=N monster-hits=N`.
2. **Heads move smoothly.** Bone controllers were taken raw at the AI think rate
   (10 Hz) while the body interpolated. Now blended — but **only for bounded
   controllers**; wrapping ones (`type & 0x8000`) still snap, which is what the
   original "never interpolate" note was really protecting.
3. **Mouths follow the actual audio.** Was `0.5 + 0.5*sin(time*22)`, unconnected
   to the sound. GoldSrc drives the jaw from the sample's amplitude in the *sound
   engine*, and `S_GetChannelLevel` already computed exactly that and had no
   callers. Now wired into controller 4 and scaled into each model's own range.
4. **Brushes through the They Hunger skybox.** `gl_warp.c:480` names the symptom
   verbatim. The cause: when the sky shader carries a GLSL program — the normal
   case — `R_DrawSkyChain` returns "draw as normal" from *above* the
   `GL_SkyForceDepth` call at the bottom, so the mask never runs. World geometry
   is still hidden by BSP PVS, which is why the leak shows as entities and never
   as walls. Fixed behind **`r_sky_forcedepth`** (default 1); set it to 0 to
   confirm the diagnosis by making the bug come back.
5. **`r_hlmdl_seqblend 1` — animation blending.** `gl_hlmdl.c` has carried
   `FIXME: we don't handle frame2` forever: HL models never cross-fade between
   sequences, they snap. The data was already being computed and discarded.
   **Default OFF** — it is the hottest path in HL model rendering and affects
   every studiomodel including players, and I cannot see it. Turn it on and judge.
6. **The grunt's grenade.** The server side is *proven* correct — measured
   `modelindex=388`, live velocity, `SendFlags` bumped every tick. So the fault is
   client-side. `developer 1` now prints `[proj] new type=N model="..." modelindex=N`
   on every projectile: modelindex 0 means the client never precached it, an empty
   model string means the type byte did not resolve. One throw names the cause.

---

## PATCH 125b — bone controllers were never actually switched on  *(CORRECTION)*

**Patch 125 was reported as working and was not.** Every part of the feature was
correct — the QC set the values, the delta flagged them, the writer wrote five
shorts, the reader read them, the renderer consumed them — except that the
extension bit was never put in an advertised mask. `PEXT2_BONECONTROLS` appeared
only in `PEXT2_CLIENTSUPPORT`, which is the *"warn about unknown bits"* set, not
the offered one. `Net_PextMask()` never returned it, so neither side offered it,
negotiation always came back 0, the server's `pext2 & PEXT2_BONECONTROLS` gate was
never true, and **not one byte of bone-controller data was ever transmitted.**

That is why head turn and mouth both did nothing, and why "I traced the whole path
and it looks right" was worthless as evidence — the path *was* right, and switched
off.

One line in `common/net_chan.c` fixes it, inside the replacementdeltas block
(the payload rides in `UF_BONEDATA`, which only exists in that stream).

**Verified, not inferred:** a real client against a real server now logs
`client: pext2=0x97f bonecontrols=YES deltas=YES`. `0x97f` contains `0x800`.

There is now a permanent connect-time line (`developer 1`) reporting exactly this
per client, because a silently-unnegotiated capability is indistinguishable from
QC that never ran.

- [ ] **Heads should track you** (±60° scientist/barney/otis, ±70° hgrunt).
- [ ] **Jaws should move while talking.**
- [ ] **Turret guns should lead and elevate**; the barnacle tongue should stretch.
- [ ] Confirm the line above appears when you connect.

## F4 test bench — nothing was clickable

`NPC_PanelInputEvent` swallowed the mouse and returned TRUE **without ever calling
`sui_input_event`**. SUI is where the cursor lives and where `sui_action_element`
hit-tests, so no widget was ever under the pointer: every button drew, none ever
highlighted, none ever fired. The panel looked complete and was completely inert.

F1 (`cl_debugpanel.qc:297`), F2 (`cl_serverpanel.qc:1026`) and F3
(`cl_carpanel.qc:412`) all forward then absorb; F4 was the only one that did not.
Now matches.

## Level transitions corrupted textures

**Not a renderer bug — a WAD resolution bug.** The create-server menu loads a map
as `map "@<spec>/<name>"`; `SV_Map_f` stashes the spec, `SV_SpawnServer` biases the
worldmodel *and the texture WAD lookups* to that game, and publishes it as the
`*mappref` serverinfo key. A bare `changelevel foo` deliberately **clears** that
hint (`sv_ccmds.c:751` names changelevel as one of the paths that must not inherit
a stale one), so the next map's WADs resolve by plain mount priority instead.

The names collide and the content does not. Measured on this install:
`halflife.wad` exists in `Half-Life/valve`, `Half-Life/bshift` and
`Sven Co-op/svencoop`, **all three exactly 37,914,096 bytes, and valve's MD5
differs from the other two.** Same name, same size, different texture data — so a
map that loaded its WAD from one game and then gets another after a transition
renders every face with the wrong pixels. `hl_c01_a1 → a2` and the Opposing Force
maps are exactly the ones that hit it.

Both QC changelevel sites now re-attach the spec. The `@` form is explicitly
exempt from the package-manager's gamecode block (`sv_ccmds.c:817` tests
`*mangled != '@'`), so QC is allowed to use it.

- [ ] **Walk `hl_c01_a1` → `a2` and check the textures survive.** Then an Opposing
      Force chapter transition.

## GoldSrc / OpFor / Blue Shift pickups — partial, and here is the exact gap

Census across all four mounted games (125 valve + 55 gearbox + 37 bshift + 108
svencoop maps): **72 distinct pickup classnames, ~7500 placements**, almost none of
which had a spawn function — so they were becoming invisible inert relays.

**Now working (name-only aliases to guns this mod already has):**
`weapon_shotgun` (186), `weapon_9mmAR` (214), `weapon_mp5`, `weapon_9mmhandgun`,
`weapon_handgrenade` (458 — the single biggest), `weapon_rpg` (104),
`weapon_egon`, `weapon_python`. Plus real pickups for **`item_suit`**,
`item_battery`, `item_longjump`, `item_antidote`, `item_security`.

`item_suit` grants armour (50, capped 100; battery 15 — Half-Life's own numbers).
That is a **deliberate divergence**: HL's suit grants no armour, it switches the
HEV suit on, which unlocks the HUD/flashlight/voice — none of which are gated
here, so a faithful port would be a pickup that visibly does nothing. The plan's
note that "no armour stat exists in this mod" was wrong; `.float armor` is in
`sv_customdefs.qc`.

**Still missing — no such weapon exists in this mod, so aliasing would be a lie:**
`weapon_satchel` (353), `weapon_tripmine` (286), `weapon_snark` (99),
`weapon_hornetgun` (29), and the whole Opposing Force set — `weapon_sniperrifle`
(72), `weapon_m249` (61), `weapon_pipewrench` (48), `weapon_eagle` (39),
`weapon_sporelauncher` (36), `weapon_displacer` (34), `weapon_shockrifle` (27),
`weapon_grapple` (27), `weapon_knife` (15), `weapon_penguin` (4) — plus Sven's own
(`weapon_uzi`, `weapon_m16`, `weapon_sawedoff`, `weapon_colt1911`, …). These need
new weapons implemented, which is a different job from moving names over.

**Still missing — no such system:** `item_longjump` spawns and fires its chain but
grants nothing (no longjump module in the movement code); the Opposing Force CTF
items (`item_ctfflag`, `item_ctfbase`, `item_ctfaccelerator`, …, 22+9×5) need CTF.

**`ammo_*` is deliberately NOT bulk-aliased.** Half-Life keeps global per-calibre
pools, so `ammo_357` means "add rounds to the .357 pool" whether or not you own the
gun. This mod keeps ammo **per slot** (`slot_primary_ammo` etc.,
`shared/sh_weapon_slotammo.qc`), so there is no pool to add to unless the player
already carries the matching weapon. `ammo_9mmclip`/`ammo_9mmbox` work because
they were special-cased against the glock and SMG. Doing the rest means deciding
what ammo-without-a-gun means here — a design question, not a mapping exercise.
Affected volume: `ammo_buckshot` (431), `ammo_9mmbox` (330), `ammo_357` (389),
`ammo_rpgclip` (376), `ammo_ARgrenades` (368), `ammo_gaussclip` (368),
`ammo_crossbow` (274), and the OpFor calibres (`ammo_spore` 323, `ammo_556` 244,
`ammo_762` 233).

## scripted_sequence is live — the maps have choreography now

**This is the big one and it is what puts barney in the chair.** 2019 of these
corpus-wide; `hl_c01_a1` alone has 95 and **zero** `path_corner`, so this class is
not part of that map's choreography system, it *is* the choreography system.

Verified headless on `hl_c01_a1`:

| | |
|---|---|
| scripts on the map | **95**, of which **7** claim an actor at map load |
| actors posed and holding | **7/7** — barneyatdesk, leaningbarney, airlockbarney, introroomleaner, coffee, and the arguing gman + scientist |
| scenes played to completion | 3 played → 3 done → 3 chains fired |
| soft-lock guards fired | lost=0 forced=0 broke=0 |

**What to look at in-game.** Spawn on `hl_c01_a1` and walk the intro:

1. **The security guard is sitting at the desk** in the first room. That is
   `barneyatdesk`, teleported onto his mark and holding `sit1` forever. If he is
   standing, possession failed — check `developer 1` for `[script] "" claimed
   monster_barney "barneyatdesk"`.
2. **The G-Man and a scientist are arguing** further in. The G-Man is a posed body
   with no AI at all (`mon_corpses.qc` builds him that way, correctly — gman.mdl
   has no attacks), so he is driven straight from the script entity. He should be
   in `idle01` and should play `listen` / `bigno` / `bigyes` when the scene fires.
3. **The intro walkers walk** when you cross their trigger.
4. `sv_ai_debug 1` prints `[ai]   script now: walking=N posed=N playing=N` every
   two seconds — the live census. `posed=7` on this map with nothing triggered.

**KNOWN LIMITATION — scripted transit, not scripted acting.** Two of three
scripted *walks* on `hl_c01_a1` stop short of their mark. Both causes were
measured, and neither is in the script layer:

- `gizmoscistart`: 155 units short, blocker = **worldspawn**. The mark is round a
  corner and the nav graph cannot route there — that map's 98 `info_node`s build
  into **8 disconnected components**, the largest holding 39 of them.
- `introwalkerguy1mm`: 521 units short, blocker = **another `monster_scientist`**
  standing in the route. Monsters do not currently push past or route around each
  other.

Both give up *safely*: the actor stops, the scene plays from where it got to, and
the target chain still fires, so nothing can soft-lock. Improving either means
improving locomotion (nav connectivity / monster-vs-monster avoidance), which is
its own piece of work. Watch for actors that stop in corridors — that is this, not
a broken script.

**Also worth confirming by eye:** `m_iszPlay` names that the installed models do
not carry. `hl_c01_a1`'s `enterbarney2`/`enterbarney3` ask for `sit2` and `sit3`,
and **neither Valve's barney.mdl nor Sven's replacement has them** — only `sit1`.
Those scripts complete and fire their chains rather than freezing him, and the
`noseq` counter records it.

## Talkers — mouth, refusals, and gunfire  *(all three were reported broken in-game)*

- **The jaw window was wrong, not the wiring.** The mouth envelope used the same
  0.85 s as the word spacing. Measured over the 1448 words `sentences.txt`
  actually references that resolve in the mount: **median 0.89 s, mean 2.02 s, p90
  4.17 s**. Spacing wants the median, total speaking time wants the mean — using
  the median for both shut the jaw after 0.85 s of a line still going four seconds
  later, which reads as no jaw movement at all. Now 2.0 s/word for the mouth.
  *Needs the Patch 125 client to be visible at all — if you are running
  `fteqw64.prepatch125.exe`, no bone controller reaches the client and the head
  will not turn either.*
- **"I'm busy" is now spoken.** Pre-disaster talkers play HL's own `SC_POK` /
  `BA_POK` group (`barney/ba_post`, `ba_duty`, `ba_raincheck`, `ba_later`) instead
  of only printing a line. Accepting a follow plays `SC_OK`/`BA_OK`, telling one to
  wait plays `SC_WAIT`/`BA_WAIT`. The console text stays as the fallback for
  classes with no sentence group.
- **They react to gunfire now.** `COND_HEAR_SOUND` had exactly one producer —
  taking damage — so a player could empty a magazine in a room of scientists and
  nothing looked up. `AI_HeardGunfire` is called from `SH_StandardTryFire`, the one
  authoritative fire point for every standard weapon; talkers within 1280 units
  turn, look and play `SC_SCARED`/`BA_SCARED`. **They deliberately do not flee** —
  HL scientists take cover from danger sounds, but an escort that bolts every time
  you fire is unusable in co-op.

## Cockroaches  *(reported: stacked, moving in lockstep, camera sinks)*

- **The pile is the map, not a bug.** `th_ep1_01` has six `monstermaker`s asking
  for `monster_cockroach` with `m_imaxlivechildren` up to **7** and
  `monstercount -1`, all spawning on the maker's own origin. The count is correct.
- **They now scatter and desync**: a traced random offset at spawn (skipped if it
  would push one through a wall) plus per-roach speed jitter around 90.
- **You can squash them, and that fixes the camera too.** HL's `CRoach::Touch`
  kills a roach on contact with any *moving* player. A roach is a solid 2×2×1 box,
  so standing on one puts the player a unit up while CSQC prediction — which does
  not have it — predicts the floor; that disagreement *is* the sinking view. In HL
  it cannot happen because the roach dies before it can support you. Same three
  lines fix both symptoms. `roach/rch_smash.wav` plays (the old comment here
  claiming roach.mdl has no sounds was wrong — HL precaches three and all three
  are in the mount).
- **Still missing vs HL's CRoach:** light sensitivity (roaches flee lit areas),
  food-seeking and eating, and idle wander to random spots. The wander is the one
  you would notice — HL roaches scurry constantly rather than holding position.

## ENGINE PATCH 125 — bone controllers are now networked  *(needs the new binaries)*

**This is the one item that changes the engine, so read it first.** `fteqw64.exe` and
`fteqwsv64.exe` in `C:\FTEQuake` are new builds; the previous ones are kept beside them as
`fteqw64.prepatch125.exe` / `fteqwsv64.prepatch125.exe`. If anything below misbehaves, swap
those back and everything returns to the pre-patch behaviour.

`.bonecontrol1..5` existed in progdefs and `framestate_t.bonecontrols` was already read by the
HL model renderer, but nothing ever carried them across the wire — so a server-side HL model
could not aim. `PEXT2_BONECONTROLS` (0x800) now sends five shorts inside the existing
`UF_BONEDATA` payload, under a spare flag bit.

- [ ] **A pre-patch client must still connect to a patched server, and vice versa.** This is
      the compatibility claim and the only thing I cannot verify without a real client. It is
      airtight *by construction* — the 0x20 flag bit is only ever set when the extension is in
      `client->fteprotocolextensions2`, which an old client never advertises, and both baseline
      emitters pass that same per-client set (verified by reading, `sv_user.c:1724` and `:1862`)
      — but "airtight by construction" is not the same as "seen working".
- [ ] **Existing demos must still replay.** Same mechanism, same reasoning, same caveat.
- [ ] **Turret aim.** `monster_sentry` / `miniturret` / `turret`: the base should still swivel
      as before, and the **gun should now lead it** and **elevate**, which the chassis could
      never do. Verified headlessly only that they still deploy, scan, fire and hit
      (4 attacks, `shots=2 hits=2`).
- [ ] **Barnacle tongue is now drawn.** It should hang ~64 units at rest and stretch to the
      victim when something walks under it. The length comes from the same trace that applies
      the damage, so the drawn tip should be exactly where the biting happens.
- [ ] **Grunt / barney aim tracking.** Their spine should turn toward you between bursts, up to
      the model's own limit (±70° hgrunt, ±60° barney) and no further, with the body catching up
      after. If a grunt tracks *past* those limits something is wrong with the units.

**The units are not uniform, and this is the trap.** `HL_CalcBoneAdj` (gl_hlmdl.c:988) branches
on the controller's `type`: `& 0x8000` (wrapping rotation) is consumed **raw as radians and
unclamped**; `[0x0008,0x0020]` is **degrees, clamped** to the model's own range; anything else
is **raw units**. That is why the turret's yaw is passed in radians and its pitch in degrees, in
the same function. Measured ranges are documented in `sv_ai_combat.qc`.

---

## Grenades are live  *(the byte→short widening landed)*

`GREN_TOSS` / `LAUNCH` / `DROP` are no longer no-ops. The HL grenade's owner field is now a
**short** on the wire in both directions, which is what was blocking this: a monster edict past
255 aliased onto whatever player sat at `(n & 255)` and that player silently lost the explosion FX.

Measured: **10 range_attack2 selections → 9 throws → 9 explosions**, owner correctly attributed
as `monster_human_grunt`, peak 100 at radius 250. All four safety vetoes observed firing
(9 "no clear arc", 6 "enemy too close", 3 "friendly inside the blast", 1 "enemy airborne").

- [ ] **Watch a grunt actually throw one.** The arc is HL's own `VecCheckToss`, so it should lob
      over cover rather than through it.
- [ ] **They should not frag each other or you.** The 256-unit minimum and the faction proximity
      check are what prevent it; `sv_ai_debug 1` names the veto whenever a throw is refused.
- [ ] **hgrunt.mdl has TWO sequences tagged act 29** — `throwgrenade` (code 7) and
      `launchgrenade` (code 8) — and `frameforaction` picks between them at random. Both codes
      now release whatever the grunt is *carrying* rather than what the animation rolled, so a
      hand-grenade grunt should never fire a contact round. Worth confirming by eye.
- [ ] Grenade count is `sv_ai_grunt_grenades` (default 3). HL's grunts have unlimited; 3 is a
      multiplayer-sanity choice, not a port of anything.

---

## Allies follow on +use

The `monster_player_usable` gate added back in B2 finally does something. **+use an ally** and it
escorts you; +use again and it waits. `cmd ai_follow` (aim at an ally, `sv_cheats 1`) runs the
exact same path, for when you want to know whether the behaviour is broken or the press just
landed on a wall.

Three failures were found and fixed getting here, all measured:

| | before | after |
|---|---|---|
| follow selections | 20 | 354 |
| follow **failures** | 19 | **0** |

1. The follower walked to the leader's **exact origin** (`AI_GOAL_REACH` is 40) while its stop
   band is 128 — so it shoved into the player, tripped the stuck counter and reported BLOCKED.
   It could not succeed even once, by construction.
2. It **waited on the nav queue**. Eight allies requesting in one tick meant most were refused,
   each waited out a 2 s deadline, failed with `COND_NO_PATH`, and the failure backoff pushed the
   next request out past its own retry — permanent starvation. HL's allies do not graph-search to
   the player at all; `CTalkMonster` walks straight at them. It now asks the queue as a courtesy
   and gets on with walking.
3. All followers aimed at the **same point** and jammed into each other. They now spread around a
   ring, at an angle derived from the edict number so it is stable.

- [ ] **An escorted ally still fights.** Verified: 4 range attacks, 3 hits on headcrabs, 6 crab
      kills *while following*. Worth seeing.
- [ ] **KNOWN, and HL-accurate: an ally will shoot you if you stand in its line of fire.**
      Measured once in 80 s with eight allies ringed around one player (10 damage, pass-through
      while it was shooting a headcrab). Its enemy was never the player — the faction matrix
      prevents that — the bullet simply went through. Newly *more likely* because followers now
      stand close. Say the word and the ring widens or ally bullets pass through allies.
- [ ] The escort drops if you die or get more than 1024 units away.

---

## Bigmomma lays headcrabs  *(was OPEN)*

Her spawn sequence is tagged `ACT_MELEE_ATTACK2` and **nothing in the generic ladder ever selects
that activity** — the event was wired, event-correct, and unreachable. It now has its own
schedule and a class selector.

Measured: **13 selections → 13 births**, and the live-child count rises *and falls*
(1,1,1,2,2,1…3), which is the slot-release path working — so a gonarch whose brood is killed can
birth a fresh one.

- [ ] Watch her actually birth one. `sv_ai_bigmomma_crabgap` (8 s) and
      `sv_ai_bigmomma_maxcrabs` (10) tune it; drop the gap to 2 to see it quickly.
- [ ] She refuses to birth into solid, so a gonarch backed against a wall should skip rather than
      drop a crab inside the geometry.

---


## THE TEST BENCH  —  **F4**

A drawn CSQC panel, same family as F1 (cvars), F2 (server browser) and F3 (car
tuning): draggable, cursor takeover, game keeps ticking underneath. It reuses the
F1 panel's visual constants and its button helper, so the two cannot drift apart.

**Spawn tab** — all 37 AI classes as buttons in four labelled groups (humans and
allies / aliens / static-aquatic-airborne / heavy). Each spawns **where you are
looking**, so aim at a bit of floor and click. Labels carry the warnings that
matter: `^2ALLY` on the ones that must not shoot you, `FLEES` on scientist and
roach, `UP` on the barnacle (aim at a **ceiling**), `WATER` on the swimmers.

**Bottom bar** — spawn count -/+ (1..16), `freeze` (pause every monster
mid-animation and walk around it), `hurt` (damage what you are aiming at, to test
flinch and death without shooting), `clear all`.

**Status tab** — `ai_status` and `ai_list` to console, plus a live count of
monster entities this client can actually see. That count is the fastest way to
notice "the server says it spawned eight and I can see none", which is exactly
the failure the W3 grunts had.

`ai_status` is the important readout: every bug in this programme showed up as
the **wrong schedule**, not a wrong task, and that is the column it prints — hp,
state, schedule name, condition bits, current enemy, distance.

Everything is `sv_cheats`-gated except the two read-only commands. The same
commands work from the console (`cmd ai_spawn <class> [n]`) and there is an
optional `cfg/aidebug.cfg` of keybinds if you ever want them without the panel.

## VERIFIED — allies actually fight (3 bugs found and fixed)

`sv_ai_spawnclass2` was added so two different classes can be spawned side by
side; without it the faction matrix could not be tested at all. Barney + headcrab
on th_ep1_01, with a player present:

| | before | after |
|---|---|---|
| barney -> headcrab hits | 1 | **6** |
| headcrab -> barney hits | 12 | 4 |
| headcrab deaths | 0 | **6** |
| barney -> player hits | 0 | **0** |
| schedule selections, all classes | 1793 | **763** |

Three real bugs, all in shipped code:

1. **Barney had a melee range but no melee animation.** `barney.mdl` has no
   `act 30` at all, so `SCHED_MELEE_ATTACK1` fell through the activity fallback to
   sequence 0 and he stood playing an IDLE pose while "attacking". The hgrunt
   keeps its melee because it genuinely has a frontkick.
2. **The close-range veto left him with nothing.** `Grunt_CheckAttack` refuses the
   gun inside 70 units because grunts kick instead — with melee removed that left
   Barney unable to do anything at all at contact range. It now only vetoes when a
   melee alternative exists.
3. **`COND_PROVOKED` is never cleared** and was in `alert_stand`'s interrupt mask,
   so that schedule was interrupted on its first tick forever — 707 selections in
   50 s. It is HL's persistent *memory* flag, not an event. Removed from that mask;
   still in `idle_stand`'s, where waking a dormant monster is the point.

- [ ] Confirm in game: an ally should shoot monsters, never you, and should not
      visibly stutter between poses.

## W7 — bosses, part one (bigmomma, apache, osprey)

Bigmomma verified: 25 `melee_attack1`, hits landing.

- [ ] **Bigmomma is 1000 hp, 50 melee, 120-unit reach.** Check she is a fight and
      not a wall.
- [ ] Her **mortar** is a 200-unit blast centred on YOU, not a lobbed projectile.
      HL lobs a real shell; this is the same threat without a new projectile type,
      but it cannot be dodged by out-running the arc. Change if it feels unfair.
- [ ] **`monster_apache`** hovers at 320 units and fires 3-round bursts.
      **`monster_osprey`** is deliberately UNARMED — in HL it is a troop transport
      that drops grunts, and the dropping belongs with scripted_sequence (W8).
      Both are one-sequence models, so they have no death animation: they will
      simply stop. Known.

## OPEN — bigmomma never lays headcrabs

The `LAY_CRAB` handler is written and wired to the right event (code 12), and it
spawns a real `monster_headcrab` through `Monster_Build` so the child gets a brain
and a hull like any other. But the sequence carrying that event is tagged
**act 31 (ACT_MELEE_ATTACK2)**, and no schedule in the table ever selects that
activity — so the event never fires. Her signature behaviour is therefore absent.
Needs a class `ai_selectsched` that periodically picks a lay-crab schedule.
Written up rather than left as a silent gap.

## OPEN — stukabat lands no damage

`monster_stukabat` selects `range_attack1` 12 times in 45 s and connects zero
times. Three causes ruled out: the attack IS correctly tagged `act 28` (its model
has no `act 30` at all), the sweep reach now matches the range that gates it, and
volume-mode melee now aims in 3D rather than along the yaw plane. Still zero.
Most likely it never actually closes to within its 80-unit reach because a flyer
follows waypoints lifted to its cruise height. Everything else works — it flies,
chases and plays the attack. Low priority (60 placements), flagged not hidden.

## W5/W6 tail — heavy melee (189 placements)

Gargantua verified: 3 `melee_attack1`, 3 hitclaims.

- [ ] **Gargantua stomp lands at 1.36 s of a 1.5 s animation** — the wind-up is
      the tell, same as the houndeye. 800 hp, 50 dmg slash, 50 dmg stomp in a
      400-unit radius. Check it is survivable.
- [ ] `monster_babygarg` is the same rig at half damage and 0.5 scale reach.
- [ ] Neither gargantua bleeds (HL behaviour).
- [ ] **`monster_kingpin`'s model has only 3 sequences** — idle, walk, run, no
      attack animation at all. It deals damage from the per-tick hook, so it
      walks into you and hurts without an animated swing. Known, not a bug.


## W6 — turrets (453 placements, 3 classnames)

The first classes to use AIMODE_STATIC and named sequences. Verified headless:
13 shots / 13 hits / 104 dmg, `arrived=0` and `volstep=0` (no static monster ever
entered the movement path), 18 schedules built, `BAD=0`.

- [ ] **Rate of fire comes from the model.** The looping `fire` sequence carries
      one `EVENT_MUZZLEFLASH` per round — 3 on sentry, 7 on miniturret, 3 on
      turret at 150 fps — so each keeps its own authored cadence. Check they
      sound distinct from each other and that the flash matches the shot.
- [ ] **Deploy / retire.** `monster_miniturret` and `monster_turret` start
      retracted, pop up on sighting, and fold away after 5 s with no target.
      `monster_sentry` starts deployed and never retires (it is the free-standing
      one). Check the pop-up animation plays fully and isn't re-triggered.
- [ ] **Ceiling mounts must not fall.** STATIC skips `droptofloor` entirely —
      that is the whole reason the mode exists. Find a ceiling turret and confirm
      it stays on the ceiling.
- [ ] Turrets swivel their base to aim (`ai_yaw_speed 120`). HL aims with bone
      controllers instead, which is W1a; until then the whole model rotates.
      Check that reads acceptably.
- [ ] They do not bleed (`bloodcolor -1`) and take **metal** impacts, not flesh.

## W4 — factions and allies (FIXES A SHIPPED BUG)

`monster_barney` (319), `monster_otis` (81), `monster_human_grunt_ally` (406) and
`monster_human_medic_ally` (52) were **shooting players** from W3 until now — they
were tagged `CLASS_PLAYER_ALLY` but nothing read the tag. Verified headless that
allies no longer damage players and that hostiles still do (grunt 13 hitclaims on
the bot).

- [ ] **Allies must not shoot you.** Barney/otis/ally-grunts/medics.
- [ ] **Allies SHOULD shoot monsters.** This is the part the harness could not
      construct — it spawns one class at a time, so allies and hostiles were never
      co-located. Put a barney near a headcrab and confirm it engages.
- [ ] **`monster_scientist` (271) must never fight.** Both attack ranges are 0 and
      the matrix returns R_FEAR, so it should run (`SCHED_FLEE_ENEMY`, the schedule
      built for the cockroach in W2). Check it flees rather than standing still.
- [ ] **Aliens must ignore each other.** A zombie should not attack a headcrab.
      HL's real table is R_NO across the whole alien block; my first draft had
      predators hunting prey, which would have had maps killing themselves off
      before the player arrived.
- [ ] Turrets/robogrunts (`CLASS_MACHINE`) shoot players and aliens but not
      human military.
- [ ] The map `classify` key overrides the class default — 2969 entities in the
      corpus carry one and none were read before now. Worth spot-checking a map
      that uses it.
- [ ] Scientists are now `monster_player_usable`; +use does nothing yet (follow
      behaviour is still to come) but the gate is live.

## W6c — barnacle (183 placements)

Verified headless: 8/8 hung from the ceiling by the test harness, tongue landed
damage, `barnacle_chomp` fires on contact.

- [ ] **The tongue is not drawn and the victim is not lifted.** Both need the
      bone-controller engine patch (W1a) — that controller is what sets tongue
      length. What works today is the gameplay: standing under one hurts
      continuously and it visibly chews. This is the most visibly incomplete
      class in the programme; it is not a bug report.
- [ ] Barnacles must stay on the **ceiling**. AIMODE_STATIC skips `droptofloor`
      specifically for this class.
- [ ] Damage is 10 every 0.5 s (`sv_ai_barnacle_dmg`). Check that is a hazard
      rather than an instant death.
- [ ] A barnacle over a catwalk must not reach through it — the tongue trace is
      `MOVE_NORMAL` so world geometry blocks it.

## W6b — swimmers and the flyer (398 placements)

First classes written AGAINST the locomotion modes rather than forced into them
with `sv_ai_forcemode`. Verified headless: controller held clearance
`max=64 mean=52.9` against a configured `ai_flyheight` of 64, constant across the
whole run; leech refused 89 volume steps that would have beached it.

- [ ] **`monster_alien_controller`** hovers at 64 units and never closes — it has
      no melee range at all. Check it looks like it is floating, not standing.
      Its energy ball reuses the **egon beam**; change if it reads wrong.
- [ ] **`monster_leech`** has NO walk or run — both gait cycles are tagged
      `ACT_SWIM`. The activity fallback now routes WALK → SWIM → IDLE; before that
      it glided everywhere in its hover pose. Check it swims rather than glides.
- [ ] **`monster_ichthyosaur`** bites for 35 (HL's figure) with a 90-unit reach.
      That is a lot — check it is not unfair in a confined pool.
- [ ] Swimmers placed **out of water** log a warning once and then cannot move at
      all, by design. If a map's leeches sit motionless, check the log for
      "swimmer placed out of water" before assuming the AI is broken.

## W5 — alien melee/ranged (816 placements, 5 classnames)

First monsters with real projectiles. Verified headless: agrunt 9 class events /
9 hitclaims, bullsquid 8 `range_attack1` / 15 class events / 7 hitclaims.

- [ ] **The alien grunt fires FIVE hornets per attack** (codes 1-5), and its
      `longshoot` sequence fires seven. The volley is the attack. Check it reads
      as a volley and isn't overwhelming — `sv_ai_agrunt_dmg` (default 8) tunes it.
- [ ] **Bullsquid spit arcs** (gravity 0.5), **pitdrone spikes fly flat**
      (gravity 0). Check both look right and that neither tunnels through a
      player at close range (they use `MOVETYPE_FLYMISSILE` for that reason).
- [ ] Projectiles are plain server entities, not the CSQC `PROJ_TYPE_*` system —
      so they are **not** client-predicted. At high ping they may look slightly
      behind. That is expected, not a bug.
- [ ] `monster_alien_voltigore`'s ranged attack reuses the **egon beam** rather
      than a projectile. If it reads wrong, that's the thing to change.
- [ ] `monster_gonome` falls back to the **zombie** model if Opposing Force
      content is ever unmounted; `pitdrone` falls back to **bullsquid**.

## W3 — the gun shooters (~2600 placements, 13 classnames)

Verified headless: grunt 15 shots / 13 hits / 104 dmg, barney 10 shots / 10 hits.

- [ ] **Three-round burst.** A grunt fires 3 rounds per attack, 0.1 s apart, from
      anim events on a LOOPING sequence. 15 shots from 5 attacks confirms the
      mechanism; check it *sounds* and *looks* like a burst, not a stutter.
- [ ] Grunts kick instead of shooting inside 70 units — check the transition.
- [ ] **Model resolution.** `steam:Half-Life/gearbox` is now mounted, so every AI
      class resolves to a real file — run `sv_ai_selftest 1` and read the
      `[ai-selftest] model ...` inventory, which prints what each class got and
      which mounted game it came from. Current result, zero MISSING:
      valve → headcrab, zombie, roach, islave, houndeye, hgrunt, hassassin, barney;
      gearbox → massn (419), otis, strooper, hgrunt_opfor/medic/torch;
      svencoop → hwgrunt.
      Only `monster_robogrunt` and `monster_bodyguard` fall back (to hgrunt and
      barney) — no mounted game ships those two.
- [ ] **Blue Shift is not installed** (no `bshift` dir, no Steam manifest). The
      `fs_addons.txt` line is present but commented; uncomment after installing.
- [x] ~~**Grenades are deliberately inert.**~~ **DONE** — the owner field is now a short and
      all three events release a real grenade. See the grenades section above.

## W1d / W5-first — new monsters (spawn-tested headless, never seen)

`sv_ai_spawnclass <class>` + `sv_ai_spawntest 8`.

- [ ] **`monster_alien_slave`** (726 placements, #2 class in the corpus). Verified
      headless: 10 `range_attack1`, 58 class anim events, 10 hitclaims landing.
      The beam fires **1.6 s into** the animation, after four charge-up events —
      check the zap looks synced to the arms coming up, not early.
      Uses `HL_BEAM_EGON` for the visual; swap to `HL_BEAM_GAUSS` if the colour
      reads wrong.
- [ ] A single islave claw swing carries **three** damage events (0.32/0.59/0.95 s),
      which is HL-correct but means melee hurts ~3x its per-hit number. Check it
      isn't brutal.
- [ ] **`monster_houndeye`** (231). Blast lands **2.36 s into** a 2.4 s animation —
      the long tell is the whole point, backing off should save you.
- [ ] Houndeye blast no longer damages other houndeyes (same-classname exclusion).
      Confirm a pack doesn't wipe itself; deaths went 5 → 0 headless.
- [ ] Monsters now take **flesh** impact effects instead of concrete dust
      (`W_ClassifyImpactMaterial` ignored `FL_MONSTER` entirely before). Shoot a
      headcrab and check for blood, not stone chips.

## W1b — wire-format widths (HIGH: desync would be obvious but severe)

Three fields changed byte → short. Server and client ship together and each field
has exactly one writer and one reader (verified statically), but the path was
never exercised.

A reader one byte short desynchronises **every event after it in the same
packet**, so a mistake here is loud, not subtle — impacts and tracers would go
visibly haywire rather than being slightly off.

- [ ] Fire a gun near another player. Tracer must start at **their muzzle**, not
      fly in from an arbitrary point.
- [ ] Fire the **gauss** and the **egon**. Onlookers must see the beam.
- [ ] Take a hit. Flinch animation must play.
- [ ] Shoot a `func_breakable`. Bullet holes must attach and vanish with it.

## W1e — animation events

- [ ] **Zombie footsteps.** Their walk cycle carries six `EVENT_SOUND` events
      naming `common/npc_step1..4.wav`. These have never played — the events were
      mis-documented as vestigial. Precache is confirmed (8 sounds found in
      `zombie.mdl`); audibility is not.
- [ ] **Body-drop thud** when a zombie dies (`EVENT_BODYDROP_LIGHT` at 0.650 s of
      `diesimple`).

## W1c — locomotion modes

Counters prove QC is the only thing moving these and that clearance holds at the
configured height, but nothing proves they *look* right.

- [ ] `sv_ai_forcemode 1` + `sv_ai_spawntest 8` — flying headcrabs should hover
      and track, not skate along the floor or bob.
- [ ] `sv_ai_forcemode 3` — static headcrabs should sit still and rotate to face,
      never try to close distance.
- [ ] A dead flyer should **fall** and land (`FL_FLY` is cleared on death).

## B2/B3 — still owed from earlier waves

- [ ] Headcrab **leap feel** — the ballistic solve is HL's, but the arc has never
      been watched.
- [ ] Walk/run speeds are **hand-set**. HL derives them from
      `seq->linearmovement`, which no QC builtin exposes, so a monster that skates
      or moon-walks means the number needs tuning, not that the code is wrong.
      Current: headcrab 60/150, zombie 40/40, zombie_soldier 35/35, roach 90/90.

---

## Notes / assumptions to confirm

- Sven Co-op's *They Hunger* monster set is assumed to work from the mounted
  Steam HL install. Models resolve from `steam:Half-Life/valve` — see the
  `hl-models-come-from-steam-mount` memory note. `th_*` classnames that are pure
  reskins are handled as variants of the base class.
- `monster_male_assassin` was pointing at `models/male_assassin.mdl`, which does
  not exist; corrected to `models/massn.mdl` (419 placements).
- Three `-> "?"` lines (an unbuilt schedule id) appear at map load on dead
  entities during the squad self-test. Predates this programme, confined to the
  `sv_ai_selftest` path, no gameplay effect. Cosmetic.

---

# PATCH 129 — the playtest defects (round 4)

Fourteen reports from a session at the keyboard, which collapsed into six systemic
faults. Three of them were caused by Patch 128's own corpse change.

## What was measured, not assumed

`sv_ai_animtest` (new, runs under `sv_ai_selftest 1`) prints, per registered class,
how many of Half-Life's 77 activities resolve to a real sequence and **every distinct
low event code the model raises**. It found a third broken shooter nobody had reported.

`sv_ai_firetest` (new) spawns the reported-broken shooters around the first live
player with line of sight, keeps the target alive, and prints the damage each one
lands. On `2fort`:

| class | before | after |
|---|---|---|
| `monster_male_assassin` | 0 (structurally) | **400** |
| `monster_shocktrooper`  | 0 (structurally) | **232** |
| `monster_hwgrunt`       | 0 (structurally) | **116** |
| `monster_alien_slave`   | worked, silent   | **30**, with sounds |
| `monster_houndeye`      | 0                | **still 0 — see owed test C** |

`sv_ai_corpsetest`: `deadflag=2 solid=5 takedamage=1 size_z=1` (5 = `SOLID_CORPSE`),
`10 bullets: hits=10 gibs=0`, `club swings to gib: 42 (chips=41 gibs=1)`.

Five-map regression clean, both self-tests `BAD=0`, errors 0, crashaddr 1824 → 1824.

## OWED IN-GAME TESTS

**A — corpses.** They are `SOLID_CORPSE` now: walk over a pile and confirm you pass
straight through with no snag and **no view sink with `cl_driftlock 1`**, and that a
crowbar still breaks a body apart. That last part is the risk — the melee/hitscan
opt-in in `W_WeaponTraceLine` and `W_ServerTraceLineWithPhysDrops` is the only thing
keeping corpses hittable at all. If bodies become unshootable, that pair is why.

**B — bullet holes from NPCs.** Stand where a grunt is shooting at a wall. Before,
exactly one hole appeared per monster per life. There should now be one per shot.

**C — the houndeye.** `sv_ai_firetest` still reports `dmg=0`, but with
`sched=chase_enemy` — it was walking, not attacking, so the blast is **unconfirmed**
rather than known-broken. The `takedamage` filter that provably excluded players is
gone from `AI_BlastAttack`. Spawn one with `cmd ai_spawn monster_houndeye`, stand at
~200 units and let it wind up. It should hurt, and hurt less the further out you are
(falloff now reaches zero at the rim, as HL does). It still has **no visible shockwave** —
that sprite is not implemented.

**D — dropped weapons.** `sv_ai_dropweapons` defaults on. Barneys drop a glock, grunts
an MP5 or shotgun. **Known cosmetic gap:** the corpse keeps a painted-on gun as well,
because selecting a bodygroup on a server entity needs the engine change that is next.

**E — firing cadence.** Barney/grunts fire ~2.4x faster (the flat 1.2 s cooldown that
sat on top of the animation is gone). `sv_ai_range_cadence 0` = exactly Half-Life;
1 (default) makes distant shooters slower and slightly irregular.

**F — the roach.** `Cockroach_Touch` had never been called in the mod's life: player
touch is dispatched by hand in `SV_CheckTouchTriggers` and only knew triggers and
buttons. Walk over one; it should squash.

**G — OpFor voices.** Shocktroopers and gonomes were entirely mute (all their sounds
sit on event 1011, which nothing handled and nothing precached). They should now speak,
step and die audibly.

---

## PATCH 130 — houndeye voice + visible blast, lipsync, the OpFor sidearm

Four playtest reports, and a fifth never-firing NPC that the sweep found on its own.

### Measured

| | before | after |
|---|---|---|
| `monster_human_medic_ally` damage landed | **0** (never fired in its life) | 160 |
| `monster_human_torch_ally` damage landed | 0 | 168 |
| `monster_houndeye` damage landed | **0** (unconfirmed since patch 129) | **28.4 — confirmed** |
| `hl_c01_a1` scripted_sentence speakers resolved by name | 0 / 24 | **24 / 24** |
| houndeye voices used | 5 of 6 | 6 of 6 (`he_hunt` was dead) |

Five-map regression clean, `crashaddr` 1824 → 1824, all three VMs 0 warnings.

### What was wrong

**The squeak is `he_hunt`, and nothing had ever played it.** It is not on an event and
not on a schedule: `houndeye.cpp:846-852` rolls 20% per think while the hound is in
COMBAT and running. `HOUND_AE_WARN` (code 1) plays it too, and we had that code filed
under "movement beats" as a deliberate no-op. Both are wired now, plus the blink
(`pev->skin` against the three eye skins in `houndeyeT.mdl` — no monster in this mod
had ever set `.skin`).

**The blast was invisible because the engine has no `TE_BEAMCYLINDER`.** `SonicAttack`
writes two of them and nothing else; the wind-up writes a `TE_IMPLOSION` every frame.
Neither temp entity exists in FTE. `shared/sh_shockwave.qc` + `CSQC_EVENT_SHOCKWAVE`
draw both as ribbon rings through the same `spriteframe()` / `_beam` shader route
`cl_env_beam.qc` uses for its RING mode, from HL's own `sprites/shockwave.spr`.

**39% of the game's scripted dialogue came out of the wrong mouth.** `scripted_sentence`
names its speaker with a key spelled `entity`, which cannot be a QC field name — the old
note here concluded it was unreachable and fell back to a nearest-monster radius search.
It is reachable: the engine calls `ED_ParseUnknownEpair` (`pr_cmds.c:487-506`) and this
mod has implemented it since the multi_manager work. Measured over the corpus: 758
scripted_sentences, **all** carrying the key; the radius guess found nothing for 98 (the
line then played from an invisible point entity, which is why no jaw moved — the mouth is
driven by the voice channel's amplitude on the *speaking entity*) and picked the wrong
monster for 196 more. `hl_c01_a1` alone was 20 wrong out of 24.

**The torch ally's gun sound was an MP5 because the animation is called `crouching_mp5`.**
The sequence name is inherited from the shared rig and lies. The bodyparts lump does not:
`hgrunt_torch.mdl`'s weapons group is `Desert_Eagle / engineer_torch / gunholster`, and
`hgrunt_medic.mdl`'s is `Desert_Eagle / glock / hypodermic / gunholster`. Both now use
`weapons/desert_eagle_fire.wav`, a handgun's 2 degree cone instead of the grunt's 5, a
pistol drop, and no grenade loadout they have no sequence for.

**The medic ally had never fired a shot.** `monster_human_medic_ally` runs
`Barney_ClassInit`, whose handler shoots on code 3; `hgrunt_medic.mdl` fires on code 4.
Same shape as the male assassin and the shocktrooper, found by diffing the codes each
model raises (`sv_ai_animtest`) against the codes its handler consumes.

### Engine

`r_hlmdl_seqblend` now defaults **on**. The cross-sequence bone blend landed in Patch 126
defaulted off because it could not be verified without eyes on it; it has now been played
and asked for. It also got its own clock — it used to borrow `lerpweight[0]`, which is
"how long the *previous* sequence happened to run for", so a monster idling ten seconds
faded over 0.3 s while one whose schedule churned faded over 0.03 s and still snapped.
`r_hlmdl_seqblend_time` (default 0.12) is now the whole answer.

### Owed in-game tests

**A — the houndeye.** `cmd ai_spawn monster_houndeye`. It should chatter while running at
you, rear up with rings converging inward, then throw two expanding rings on the thump.

**B — lipsync.** Any Half-Life chapter map. Scripted lines should come out of the NPC that
is actually talking, and that NPC's jaw should move.

**C — animation smoothing.** Watch any NPC change from idle to walk to attack. Toggle
`r_hlmdl_seqblend 0/1` to compare; tune with `r_hlmdl_seqblend_time`.

**D — the torch/medic allies.** They should fire a Desert Eagle, one loud round at a time.

### Found, not fixed

A **headless client crashes on 2fort with HL studio monsters spawned on it** (Quake BSP29
plus studiomodels). `hl_c01_a1` with the same seven models is clean, and it reproduces
with `r_hlmdl_seqblend 0`, so it is neither this patch's QC nor its engine change — a
pre-existing engine bug that only this test-harness combination reaches.

*Diagnosed and fixed in Patch 131 — it was the BC7 texture decoder, not the monsters.*

---

## PATCH 131 — the BC7 crash, the corner fix, and the gun in the hand

### The crash was a texture decoder, not a monster and not a missing mount

Symbolised from `crashaddr.txt` against the unstripped `fteqw64.exe.db` the Makefile keeps
beside the shipped binary: the fault was in **`Image_Decode_BC7_Block`**, on the texture
worker thread, nothing to do with the monsters that appeared to trigger it. They only
correlated because spawning them pulled new textures through the hi-res replacement path.

Four bugs in that one function, all long-standing:

1. **A write sixteen pixels behind the block.** The RGB pass walks `out` forward by
   `4*(w-4)` across the four rows; the alpha pass and the channel-rotation pass each
   rewound by `w*4` before running again. For the first block of an image that writes
   behind the heap allocation, and for a partial block (where the caller hands the decoder
   a 16×16 stack scratch) it writes behind a stack array. The damage lands in memory freed
   later, which is why the visible fault was inside `BZ_Free`. Both passes are reached only
   by BC7 modes 4 and 5, which is why the two `FIXME: untested` notes above them survived
   so long. Fixed structurally: the decoder now fills a local 4×4 and blits once, so no
   pass does pointer arithmetic at all.
2. **`etc_expandv` ran outside the subset loop**, on `palette[i]` with `i == numsubsets` —
   `palette[3]` on a 3-subset block, an out-of-bounds read-modify-write into `tab`. It also
   meant the endpoints were never expanded, so **every BC7 texture in the game has been
   decoding darker than it was authored**.
3. A copy-paste that read `palette[i][0]` where it meant `[1]`, making the second
   endpoint's alpha a duplicate of the first's.
4. **Mode 8 (reserved) was unhandled** — reachable from any block whose first byte is zero.

What made it start biting is content: **6095 BC7 textures in the material packs, 145 of them
not a multiple of 4 in one axis**, which is what drives the partial-block paths.

Verified: the headless client on 2fort died within ~10 s before, and now survives a full
five minutes plus a clean 40 s run, `crashaddr` unmoved.

### Corners

`AI_StepToward` tried `yaw+40` then `yaw-40` with no memory. Forty degrees does not clear an
inside corner — the monster's own bounding box still overlaps the wall — so both usually
failed and it stalled. When one did succeed nothing recorded which, so the next tick was
free to pick the other: right, left, right, forever, with `walkmove` reporting success every
time, which also meant **the stuck detector never fired and it never re-pathed**.

Three changes, all things HL already does: the fan **widens** (45 / 90 / 135 — 90 is the
pure slide that actually clears a corner), the side is **latched** until the direct line
reopens, and a successful sidestep is followed by an immediate retry of the original heading
— the **corner cut**, which rounds a doorframe in one tick instead of scraping the wall.

Two bookkeeping bugs fixed alongside: the blocked branch never re-seated `ai_lastorg`, so
the first step that did succeed compared against a stale point and reset the stuck counter;
and the `>60°` turn gate returned MOVING without touching any counter, so a monster whose
wanted heading kept flipping span on the spot indefinitely. A blocked route is now also
**discarded** — it used to be kept, so the re-selected schedule marched straight back into
the same corner.

*(Correction to the plan note: `Nav_RequestPath`'s `avoid` argument is a link-flag mask,
not a position to route around, so feeding it the blocking point would have done nothing.)*

### p_models

`gl_hlmdl.c` read `entity_body = 0/*rent->body*/`, so **every studiomodel in the game drew
its default parts**. `barney.mdl` spawns at `BARNEY_BODY_GUNHOLSTERED`, so his pistol was in
his holster exactly as authored; `hgrunt.mdl`'s default happens to be the MP5, which is why
grunts looked right and he did not — the same bug, invisible on one model and glaring on the
other. `.body` was parsed and stored by the monster spawner and read by nothing.

Now a real entvar, networked in `entity_state_t` under its own `PEXT2_BODYGROUP` extension
(its own bit, not riding on `PEXT2_BONECONTROLS`, so older builds and existing demos are not
dropped on the new flag), and read by the renderer. Values are dumped from each model's
bodyparts lump — GoldSrc packs every part into one integer via `(body / base) % nummodels`.

That also lights up three animation events the sweep had flagged as raised-but-unconsumed:
`BAR_AE_DRAW`, `BAR_AE_HOLSTER` and `GRU_AE_DROP_GUN` — so a corpse that drops a pickup no
longer keeps the same weapon welded to its hand.

### Measured

| | before | after |
|---|---|---|
| 2fort headless client survival | ~10 s to segfault | **5 min, clean** |
| `hl_c01_a1` barneys with a gun in hand | 0 / 4 | **4 / 4** |
| corner-cuts (sidestep → original heading) | n/a (no such move) | fires; `sidestep=1 cornercut=1` |

Five-map regression clean, `crashaddr` 1956 → 1956, all three VMs 0 warnings.

### Owed in-game tests

**A — Barney's pistol.** It should be in his hand, not his holster, and gone from the corpse
once he drops it. Shotgun grunts should show the shotgun head.

**B — corners.** Lead an NPC round a doorframe and a pillar. `sv_ai_debug 1` prints
`sidestep=` and `cornercut=`; if sidesteps climb while cornercuts stay near zero, the fan is
finding room but not converting it into progress.

**C — BC7 textures.** Everything with a `.dds` should look slightly *brighter* than before
(the endpoints are finally being expanded). Anything that now looks wrong is bug 2 above
having been load-bearing somewhere.

### Not verified headlessly

The movement counters are structurally near-zero in every headless scenario available —
monsters on the test maps stay dormant, and the fire test hands them an enemy already in
range so they never walk. One sample did catch the full new path executing
(`walkmove=1 fails=1 sidestep=1 cornercut=1`), so it runs and works end to end, but it has
not been stress-tested. That is what owed test B is for.

---

## PATCH 132 — five systemic bugs in one function

Everything here lives in `AI_HandleSharedEvent` / `AI_EventSoundName`
(`server/sv_ai_anim.qc`), the one place every monster's animation events pass through. Three
were found by reading Valve's `HandleAnimEvent` beside ours line for line; two were found by
scanning the model corpus. All five were silent — the symptom in every case is a sound that
does not play, which looks exactly like a monster that has no such sound.

### 1 — the `*` prefix was never stripped, and the engine never even looked

GoldSrc writes `*` in front of a sound name to mean "stream this, don't cache it". It is a
storage hint, not part of the filename. FTE reads it as something else entirely: `S_LoadSound`
tests `*name == '*'`, takes it for a **Quake 2 sexed sound**, sets `SLS_FAILED` and returns
before the path is ever built (`engine/client/snd_mem.c:1058-1063`). So these were not files
that failed to resolve — they were files nobody looked for.

Measured across the 42 rigs the mod warms: **21 distinct names on 54 events**, every one of
them Valve's own — barney's and otis's `*buttons/blip1.wav`, the zombie's
`*debris/bustcrate1.wav`, and twenty scientist lines including `*scientist/scream3.wav` and
both `sci_pain` files. All 21 resolve in `valve/` the moment the star comes off.

### 2 — event code 2003 was unhandled

Not in the Half-Life SDK at all (`monsterevent.h` stops at 2010) — it is Sven Co-op's.
Identified by scanning **all 12038 loose `.mdl` files** in the mounts rather than guessing:
104 occurrences across 19 rigs, and every single one sits on a locomotion sequence — `walk`,
`walk_new`, `walk_scared`, `run`, `run1`, `run2`, `creeping_walk`, `pistol_walk` — with an
**empty options string in all 104**. It is a footstep event and there is nothing else it could
be.

Empty options means the sample has to be named in code, exactly like `BODYDROP`. The family is
quoted from the corpus rather than chosen: Valve's own models name `common/npc_step1..4.wav` in
843 `EVENT_SOUND` events, i.e. the same sound for the same purpose on the rigs that spell it out
instead of using 2003.

In *this* install only `hwgrunt.mdl` reaches the code — the valve copies of
hgrunt/barney/scientist/zombie win the path lookup — but that is a fact about mount order.

### 3 — `SWISHSOUND` was swallowed under a comment that was wrong

2010 rides on every melee wind-up in the gearbox rigs. It used to be discarded here under a
note claiming HL's client dll owned the sample and there was nothing to play. The sample is
named inline in the **server** dll (`monsters.cpp:2721-2726`), directly beneath Valve's own
all-caps warning that any monster using the event must precache it. An empty options field
means "the name is in the code", not "there is no name". Thirteen melee wind-ups across six
rigs had been swinging in silence.

### 4 — `BODYDROP` was invented rather than read

Three details wrong in one four-line branch (`monsters.cpp:2694-2719`):

| | was | Half-Life |
|---|---|---|
| file | LIGHT → bodydrop3, HEAVY → bodydrop4 | **random between the two, for both codes** |
| pitch | always 100 | HEAVY goes out at **90** (`EMIT_SOUND_DYN`) |
| gate | none | both gated on **`FL_ONGROUND`** |

So every heavy landing sounded identical to a light one, and a monster killed in mid-air
thudded while it was still falling.

### 5 — `ATTN_NORM` where Half-Life uses `ATTN_IDLE`

`monsters.cpp:2659` and `:2663` both pass `ATTN_IDLE` for `SCRIPT_EVENT_SOUND` and
`SCRIPT_EVENT_SOUND_VOICE`. The two engines agree on what that constant means — GoldSrc and
Quake both cut a sound off at `1000/attenuation` units and `ATTN_IDLE` is 2.0 in both — so this
is an exact match at 500 units. `ATTN_NORM` was carrying every monster footstep and every event
voice line 1000 units in a game whose own AI can only hear 1024, which is why one zombie could
be heard walking from most of a map away.

### New tool: `sv_ai_walktest`

`sv_ai_firetest` places its subjects already in range, so they stand still and shoot: a whole
firetest run reports `walkmove=0`. That left the entire moving half of the animation system
with no number on it. The walk test is its mirror — subjects spawn ~900 units out and have to
walk in — and its roster is one rig of each footstep dialect on purpose:
`monster_human_grunt` (spells footsteps out as `EVENT_SOUND`) as the control, `monster_hwgrunt`
(code 2003, no name) as the subject. `shared` moving while `step` stays at 0 would localise a
fault to the 2003 branch and nothing else.

### Measured

| counter | before | after |
|---|---|---|
| `star=` (stream prefixes stripped) | 0 — structurally impossible | **59** at map load |
| `step=` (2003 footsteps) | 0 — code unhandled | **1** in a 16 s walk test |
| `swish=` (2010 melee) | 0 — deliberately discarded | **2** in a firetest run |

59 rather than the corpus's 54 because `monster_bodyguard` falls back to `barney.mdl` on this
install, so that rig is warmed twice — confirmed against the model report, not assumed.

Five-map regression clean, `crashaddr` 1956 → 1956, all three VMs 0 warnings.

### Owed in-game tests

**A — volume.** Item 5 is the one change here that is HL-correct without being obviously
*better*. Monster footsteps and event voice lines now carry half as far. If NPC lines read as
too quiet, `ATTN_IDLE` → `ATTN_NORM` in the two `sound()` calls reverts it.

**B — the scientist.** Sixteen of his lines have never played. He should now be audible on the
scripted sequences in `hl_c01_a1`.

**C — the swish.** Grunt and male-assassin melee wind-ups should have a whoosh.

### Not verified headlessly

That the stripped names actually *load* on a client. The headless client harness runs with
`nosound 1`, so no sample is loaded either way — the run is clean but that is not evidence. The
claim rests on two things that are: all 21 files were confirmed present in `valve/` by direct
lookup through the mounts, and the engine's load path is unambiguous about the star.

---

## PATCH 133 — the grenade animation, and the same bug on four other rigs

### The reported bug, and Half-Life's own fix

> *"I think it plays the submachinegun grenade animation and not the grenade animation."*

Exactly right. `hgrunt.mdl` tags **two** sequences as activity 29: `throwgrenade` (the overhand
toss, event code 7 at 1.20 s) and `launchgrenade` (the underbarrel M203 shot, code 8 at
0.53 s). `frameforaction` re-rolls its weighted random on every call, so which one played was a
coin flip — and the *behaviour* was already loadout-driven, so the two openly disagreed: the
grunt mimed an M203 shot and a hand grenade came out.

Half-Life never had this because `CHGrunt::SetActivity` (`hgrunt.cpp:1866-1972`) picks these
**by name** and lets everything else fall through to `LookupActivity`. That per-class hook had
no equivalent here, so it is now `.ai_seqfor(m, act)` — called from `AI_SetActivity` at exactly
the point HL calls it, returning `""` to fall through, and falling through silently when a rig
does not carry the name (Sven ships replacement models freely).

### Four more collisions the same table resolves

Measured, not assumed — every activity tag with more than one candidate, across the shipped rigs:

| rig | act | candidates |
|---|---|---|
| hgrunt | 28 | `crouching_mp5` / `crouching_shotgun` |
| hgrunt | 29 | `launchgrenade` / `throwgrenade` |
| hgrunt_opfor | 28 | + `crouching_saw` |
| massn | 28 | + `crouching_m40a1` |
| hwgrunt | 28 | `attack` / `pistol_shoot` / `pistol_crouchshoot` |
| hwgrunt | 3, 4 | `creeping_walk`/`pistol_walk`, `run`/`pistol_run` |

So an MP5 grunt fired the shotgun pose half the time; an OpFor grunt fired the **SAW** pose a
third of the time, and the SAW animation raises *seven* burst codes against the MP5's three, so
he put twice the rounds downrange for free; and the HW grunt played a pistol animation two
times in three.

**The HW grunt case is also the sound bug**, and this is why it is one fix and not two: the
sound is chosen by which event code arrives, and the code comes from the animation. Playing
`pistol_shoot` routed him into the pistol branch, which called `Grunt_FireSound` → the MP5
report. He made a submachine gun's noise while holding a minigun. Fixing the pose fixes the
audio because on this rig they are the same decision.

**And `standing_mp5` / `standing_shotgun` carry `act=0 w=0`** — no activity tag at all. They
were unreachable, so **every grunt in this mod has fired from a crouch since the day the AI
landed**. HL reaches them by name off `m_fStanding`, which flips on a 1-in-10 roll per attack
selection; that is now ported too.

### The minigun had no sound call at all

`HWGrunt_Event`'s muzzleflash branch fired fifteen rounds over 0.58 s in complete silence.
`hassault/hw_shoot1-3.wav` have shipped in `valve/` since 1998 and were precached by nobody.
Rate-limited to one per burst rather than one per flash, because the samples are **1.19–1.29 s**
each — a full burst of minigun fire, not a single round.

### massn's bodygroup arithmetic was the hgrunt's

Dumped from the bodyparts lump:

```
hgrunt.mdl   heads n=4 base=1, weapons n=3 base=4   ->  body = head + weapon*4
massn.mdl    heads n=3 base=1, weapons n=3 base=3   ->  body = head + weapon*3
```

They shared a branch. massn's "gun gone" value was `head + 8`, which on a base of 3 asks for
weapon 8/3 — floored, that is the **M40A1**, so a disarmed massn corpse was handed a sniper
rifle. Split out with its own bases.

### Two invented sounds removed

`HGRUNT_AE_GREN_TOSS` (`hgrunt.cpp:882-892`) plays **nothing**; the callout is the `HG_THROW`
sentence, a different system. What was here instead was `hgrunt/gr_mgun1.wav` on `CHAN_VOICE` —
the MP5 burst report coming out of the grunt's throat on every single grenade throw. The M203's
`weapons/glauncher.wav` also goes out at HL's own volume of 0.8 rather than 1.

### The invisible grenade model: measured, and it is not the QC

Instrumented end to end with `sv_proj_test`, which now **repeats every 6 s** instead of firing
once (the headless client needs the better part of a minute to mount every VPK and start CSQC,
so a one-shot always fired into a world with nobody able to see it and its 30 s fuse expired
unseen) and falls back to a spectating player when no live one exists (the harness client never
presses fire, so the strict test waited 79 seconds and threw nothing — a silent early-out that
read exactly like "thrown and invisible").

Ten grenades over one run, server and client agreeing on every field:

```
[projtest] type=0 owner=world model="models/weapons/wpn_hlgrenade/w_grenade.mdl" modelindex=90
[proj] new  type=0 model="models/weapons/wpn_hlgrenade/w_grenade.mdl" modelindex=90 org=...
[proj] live type=0 modelindex=90 drawmask=1 org=... vel=...
```

That eliminates all three causes the instrumentation was written to distinguish: the model
resolves, the index is non-zero on **both** sides, `drawmask` is set and the origin tracks the
server through flight and settle. The model file is fine too — 7.2 × 6.6 × 11.0 units, an 85-colour
skin, no shader or replacement-texture override anywhere. Whatever remains is downstream of
everything the QC controls, and needs a screen.

### Measured

| | before | after |
|---|---|---|
| grenade sequence vs loadout | coin flip, uncorrelated | `if (weapons & HANDGRENADE)` — no randomness left |
| `seq overrides: taken=` | 0 (no such mechanism) | **17–19 per 2 s** in a firetest |
| `seq overrides: missing=` | n/a | **0** |
| boot-time `seqprobe` MISSING, 7 rigs | n/a | **empty on all seven** |
| HW grunt firetest damage | 124 | 128 |
| sound `not precached` warnings | — | **0** |

The boot-time probe is the better of the two numbers: the counter only reports names that were
actually *requested* during play, so a rig with a missing grenade animation would stay silent
until somebody happened to fight it at the right range. The probe reports on every map load, on
every install.

Five-map regression clean, `crashaddr` 1956 → 1956.

### Also fixed while here

`sv_ai_firetest`'s report window was 14 s, and the houndeye — the class the test was *added* to
clear — selects its first attack about three seconds after the report has already printed,
because it opens in `combat_face` and then needs a 2.36 s wind-up. Traced out of the log rather
than guessed at. Window is now 20 s, and **all seven of the roster land damage for the first
time**:

| class | 14 s window | 20 s window |
|---|---|---|
| male assassin | 464 | 696 |
| shocktrooper | 248 | 368 |
| human medic ally | 168 | 248 |
| human torch ally | 152 | 232 |
| hwgrunt | 128 | 124 |
| alien slave | 30 | 50 |
| **houndeye** | **0** | **2.83** |

### Owed in-game tests

**A — the grenade.** Watch a grunt throw. The overhand toss, not the M203 shot, and no MP5
report out of his throat.

**B — standing fire.** Grunts should now sometimes fire from a stand instead of always from a
crouch, and always with the pose for the gun they are holding.

**C — the HW grunt.** A minigun burst that sounds like a minigun.

**D — the grenade model.** Still the open one. `sv_proj_test 1` now throws one every six
seconds in front of you, so it is a single command to check.
