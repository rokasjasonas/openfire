# OpenFire

A cross-platform (Windows / macOS / Linux) **co-op & deathmatch first-person shooter**
built in **Godot 4.6**, featuring navmesh-driven **bots**, **LAN / direct-IP multiplayer**,
and an **easily configurable, drop-in mission system** for co-op.

All 3D models and textures are free **CC0** assets from [Kenney](https://kenney.nl).

![icon](icon.svg)

---

## Features

- **First-person shooter** — fluid movement (walk/sprint/crouch/jump), mouse look,
  5 data-driven weapons (rifle, SMG, shotgun, sniper, pistol) with ADS zoom, recoil,
  reloads, spread and hitscan damage.
- **Body-part damage** — head / torso / legs hitboxes with damage multipliers
  (headshots ≈ 2.5×, legs 0.75×), for both players and bots.
- **Grenades, footsteps, kill feed, directional damage indicator**, and an
  **options menu** (mouse sensitivity, master volume, FOV — saved to disk).
- **Smoothed netplay** — remote players and bots interpolate between updates.
- **Three game modes:**
  - **Deathmatch** — free-for-all vs other players and respawning bots, frag-limited.
  - **Team Deathmatch** — BLUE vs RED (players + bots), friendly fire off, team scoring.
  - **Co-op** — team up against AI through scripted missions, with **downed/revive**
    (go down instead of dying; teammates revive you) and **shared respawn lives**.
- **Bots** — `NavigationAgent3D` pathfinding, line-of-sight perception, patrol → chase →
  attack behaviour, difficulty scaling (Easy / Normal / Hard).
- **Enemy archetypes** — soldier, rusher (fast/weak), sniper (long-range/high-damage),
  and heavy (tanky), each with its own model, stats and behaviour; spawns are a mix.
- **Pickups** — health, grenades, ammo and weapon drops scattered on the maps, with
  respawn timers (glowing, floating, networked).
- **LAN / direct-IP multiplayer** — host a server, others join by IP. "Solo vs Bots"
  is the same code path hosting locally. Up to 8 players.
- **Configurable missions** — defined as plain **JSON** files in [`missions/`](missions/).
  Add a mission by dropping in a new file. See [docs/missions.md](docs/missions.md).
- **Three maps** — a symmetrical arena, a multi-room facility, and Highlands (a
  vertical stepped-ziggurat map with ramps and raised platforms), all built
  procedurally with runtime-baked navigation meshes and CC0 prototype textures.

---

## Quick start

You need the **Godot 4.6** editor. A portable copy was fetched into `.tools/godot`
during setup (gitignored); otherwise grab it from <https://godotengine.org/download>.

```bash
# Open the project in the editor
.tools/godot --path .

# …or run it directly
.tools/godot --path . res://scenes/main_menu.tscn
```

### Playing

1. Launch the game — you land on the main menu.
2. Pick a **mode** (Deathmatch / Co-op), a **map** or **mission**, **bot count** and **skill**.
3. Then either:
   - **Solo vs Bots** — start immediately, single-player against bots.
   - **Host** — open a server, share your LAN IP, press **Start Match** when friends join.
   - **Join** — type the host's IP and connect.

### Controls

| Action | Key |
| --- | --- |
| Move | `W` `A` `S` `D` |
| Jump | `Space` |
| Sprint / Crouch | `Shift` / `Ctrl` |
| Fire / Aim | `LMB` / `RMB` |
| Reload | `R` |
| Throw grenade | `G` |
| Weapons 1/2/3 | `1` `2` `3` |
| Scoreboard | `Tab` (hold) |
| Pause menu | `Esc` |

---

## Adding a mission (no code)

Drop a JSON file into [`missions/`](missions/):

```json
{
  "id": "my_mission",
  "name": "My Mission",
  "description": "Do the thing.",
  "map": "res://maps/facility.tscn",
  "enemy_skill": 1.0,
  "objectives": [
    { "type": "eliminate_all", "description": "Wipe them out", "enemy_count": 10, "wave_size": 4 },
    { "type": "reach_zone", "description": "Extract", "zone": "extraction" }
  ]
}
```

It appears in the co-op mission list automatically. Full schema and the list of
objective types (`eliminate_all`, `reach_zone`, `survive_time`, `defend`, …) are in
[docs/missions.md](docs/missions.md).

---

## Exporting (cross-platform builds)

Export presets for Windows, macOS and Linux are in `export_presets.cfg`. You need the
matching **export templates** installed once (Editor → *Manage Export Templates*, or
`.tools/godot --headless --install-export-templates`).

```bash
.tools/godot --headless --path . --export-release "Linux"   build/openfire.x86_64
.tools/godot --headless --path . --export-release "Windows" build/openfire.exe
.tools/godot --headless --path . --export-release "macOS"   build/openfire.zip
```

---

## Project layout

```
scenes/        player, bot, world, main menu, HUD, FX
scripts/
  autoload/    Game, Net, Missions, WeaponDB singletons
  player/      FPS controller + weapon manager
  ai/          bot AI
  world/       world flow, map builder, maps, objective runner
  ui/          menu, HUD, crosshair
maps/          arena + facility (procedural)
missions/      JSON mission definitions  ← add yours here
assets/kenney/ CC0 source packs + cleaned models/textures
tests/         headless smoke + LAN networking tests
```

See [docs/architecture.md](docs/architecture.md) for how networking, authority and the
mission runner fit together.

## Testing

Headless tests (no display needed):

```bash
# Single-process: host a co-op match, verify spawns + navmesh
.tools/godot --headless res://tests/smoke.tscn

# Two-process LAN test (run host in background, then client)
.tools/godot --headless res://tests/net_host.tscn &
.tools/godot --headless res://tests/net_client.tscn
```

## Versioning & auto-rebuild

The game version lives in `project.godot` (`config/version`) and is shown in the
corner of the main menu and the in-match HUD. `tools/rebuild.sh` bumps the patch
version and re-exports all three platform builds; a **Stop hook** in
`.claude/settings.json` runs it automatically after each Claude Code turn. Run it
by hand anytime with `bash tools/rebuild.sh`.

## License & credits

Code is MIT (see [LICENSE](LICENSE)). Art is CC0 from Kenney — see [CREDITS.md](CREDITS.md).
