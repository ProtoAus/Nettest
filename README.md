# Nettest

A tactical, team-based first-person shooter mod for the **[FTEQW](https://www.fteqw.org/)** (FTE
QuakeWorld) engine. Nettest blends Counter-Strike–style economy and round play, a large arsenal drawn
from Half-Life and Call-of-Duty–era weapons, and Quake movement — with server-side bots, persistent
progression, physics props, and a heavy client-side effects layer.

This repository holds the **QuakeC source** for the mod (server, client, and menu programs). The game
assets (maps, sounds, models, particle scripts, shaders, configs) live in the gamedir alongside the
compiled output and are not part of this repo.

> **Status:** work-in-progress personal project. No license is attached (all rights reserved).

---

## Features

- **Game modes** — Team Deathmatch, Elimination, Bomb Defuse (CS-style plant/defuse), Bunnyhop, Free-for-All,
  and Paintgun. Selected per server via gamemode cvars (`server/sv_main.qc`).
- **Weapons** — a large arsenal organized as families under `shared/weapons/sh_wpn_*.qc`: Counter-Strike
  guns (rifles, SMGs, pistols, snipers, shotguns), Half-Life weapons (crossbow, gauss, RPG, egon, .357,
  crowbar…), and a Crossfire/CoD-era set, plus melee (knives, katana, crowbar, fists). Shared mechanics:
  aim-down-sights, per-weapon recoil/spread, silencer toggles, context-sensitive reloads. Plus a
  **gravity gun** (pushes/pulls physics props) and a **grappling hook**.
- **Economy & progression** — CS-style cash and armor (`server/sv_money.qc`) and a persistent XP/level
  system backed by SQLite, keyed per player GUID (`server/sv_progression.qc`).
- **Bots** — server-side fake-client bots that reuse the human code paths, with A\* navigation over a
  waypoint graph and skill-tunable combat (`server/sv_bots.qc`, `server/sv_navnodes.qc`).
- **Physics props** — ODE rigid-body props you can push with `+use`, shove with weapon impacts, and
  carry (`server/sv_physprop.qc`).
- **Multi-format maps** — runs Quake, GoldSrc/Half-Life, Source (VBSP), and Call-of-Duty (IBSP) BSPs via
  the engine, with mapper entities for triggers, doors, trains, buy zones, bomb sites, weather, and more.
- **Client effects** — surface-aware bullet impacts and decals baked to persistent tri-soup meshes, blood,
  sprays, tracers, shells, weather, god rays (`env_sun`) and fog volumes (`func_fogvolume`); plus a
  rewind **killcam** and free-roam **spectator**. Per-texture materials drive impact FX and footsteps
  (`shared/sh_surfaceprops.qc` + `scripts/surfaceprops.txt`).
- **HUD & menus** — buy menu, crosshair, ammo/health/armor, killfeed, hit indicators, team select,
  scoreboard, player-model picker, spray editor, and a Create-Server UI + server browser.
- **Netcode** — server-authoritative hitscan with lag compensation (`server/sv_lagcomp.qc`) and shared,
  predicted player movement that runs identically on client and server (`shared/sh_pmove.qc`).

---

## Repository layout

```
src/
├── compile_qc.bat          Build script (invokes fteqcc for all three progs)
├── fteqcc64.exe            Pinned FTE QuakeC compiler (used by compile_qc.bat)
├── sv_progs.src            Server manifest   → ../qwprogs.dat
├── cl_progs.src            Client manifest   → ../csprogs.dat
├── m_progs.src             Menu manifest     → ../menu.dat
├── *_defs.qc               Engine builtin/global/field definitions
├── server/                 Server-side QuakeC (rounds, weapons, bots, entities, physics…)
├── client/                 Client-side QuakeC / CSQC (HUD, prediction, effects, killcam…)
├── shared/                 Compiled into BOTH server & client (movement, weapons, materials…)
│   └── weapons/            Per-weapon definitions (sh_wpn_*.qc)
├── menu/                   Menu QuakeC (main menu, server browser, create-server, team select…)
├── ftedefs/ genericdefs/   Engine builtin stubs
```

Each `*_progs.src` file lists, in order, the `.qc` files that make up that program; its first line is the
output `.dat` path (which points at `../`, i.e. the gamedir).

---

## Building

### Prerequisites
- **`fteqcc64.exe`** — FTE's QuakeC compiler. A copy is committed in this repo and used by the build
  script, so no separate download is needed.
- **An FTEQW engine build** to actually run the mod (see [Running](#running)).

### Compile
From the `src/` directory:

```bat
compile_qc.bat
```

That runs the three builds:

```bat
fteqcc64.exe sv_progs.src -max_strings 8388608
fteqcc64.exe cl_progs.src -max_strings 8388608
fteqcc64.exe m_progs.src  -max_strings 8388608
```

**Why `-max_strings 8388608`:** each program's string table has grown past fteqcc's default 2 MB limit.
Building without the larger buffer fails — on the server that surfaces as a *misleading*
`Unknown value "maxclients"` error in an unrelated file (the string table fills before that engine global
can be named), not as an obvious out-of-memory message. There is no working pragma equivalent, so the flag
is required for all three.

### Output
The compiled programs are written to the **parent gamedir** (`../` relative to `src/`):

| Manifest        | Output           |
| --------------- | ---------------- |
| `sv_progs.src`  | `../qwprogs.dat` |
| `cl_progs.src`  | `../csprogs.dat` |
| `m_progs.src`   | `../menu.dat`    |

A clean build prints `Compile finished` and `0 warnings` for each. Restart the server (and reconnect
clients — the `csprogs.dat` hash changes) to pick up new programs.

---

## Running

Nettest runs as a gamedir named `nettest/` under an FTEQW install:

1. Install an FTEQW engine build (see [Engine](#engine) below).
2. Place this mod's gamedir (the compiled `qwprogs.dat`, `csprogs.dat`, `menu.dat` plus the assets) as
   `nettest/` inside the engine directory.
3. Launch the client:
   ```
   fteqw64.exe -game nettest
   ```
   Use the in-game **Create Server** menu to host, or connect to a server from the browser. To host from
   the command line, add `+map <mapname>` (optionally with a server config via `+exec`).

---

## Engine

Nettest is developed against a **patched FTEQW fork, [ProtoAus/ftequakers](https://github.com/ProtoAus/ftequakers)**.
A number of mod features rely on engine patches that are not in stock FTEQW (e.g. prop-collision hulls,
fog volumes, god rays, and various map-format and networking fixes). For a guaranteed-compatible engine,
use a build from that fork's releases rather than a stock FTEQW download.

The mod itself is pure QuakeC — no engine code lives in this repository.
