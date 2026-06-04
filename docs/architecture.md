# Architecture

## Singletons (autoloads)

| Singleton | Responsibility |
| --- | --- |
| `Game` | Match config, teams, live scoreboard, match-over signal. |
| `Net` | ENet host/join, player list, config sync, match-start RPC. |
| `Missions` | Loads/validates JSON missions from `res://missions/`. |
| `WeaponDB` | Data-driven weapon catalog (`WEAPONS` array). |

## Networking & authority

LAN / direct-IP using Godot's high-level multiplayer over ENet. The **host is always
peer id 1** and is authoritative for game logic, scoring and bots.

- **Players** are owned by their peer: each player node's multiplayer authority is set to
  the owning peer id, which runs input/movement; everyone else receives transform,
  health and weapon index via a `MultiplayerSynchronizer`.
- **Bots** are authored by the host (authority 1). Only the host runs the AI; clients
  display replicated state.
- **Spawning** uses a `MultiplayerSpawner` with a custom `spawn_function` so init data
  (id, team, name, position) is applied identically on every peer.
- **Damage** is applied on the *victim's* authority: a hitscan that connects calls
  `hit()` on the target, which routes `receive_damage()` to that target's authority.
- **Scoring** is host-authoritative (`Game.add_kill`) and broadcast to clients.

"Solo vs Bots" is just a host on localhost that starts immediately — one code path for
offline and online.

### Match start handshake

`Net.start_match()` (host) replicates the config and RPCs every peer to load
`world.tscn`. Each client reports `world ready` back to the host; once all expected peers
are ready (or a 5 s grace timer fires) the host spawns all players + bots and starts the
selected mode.

## World & modes

`world.gd` loads the map, runs the start handshake, and dispatches by mode:

- **Deathmatch** — spawns `bot_count` respawning bots; each combatant gets a unique team
  (free-for-all); ends at the frag limit.
- **Co-op** — instantiates an **`ObjectiveRunner`** with the chosen mission; players share
  `TEAM_PLAYERS`, bots are `TEAM_ENEMIES`.

## Maps

Maps subclass `MapBase` (`scripts/world/map_base.gd`) and build geometry in code via
helpers (`add_box`, `add_wall`, `add_cover`, `add_spawn`, `add_zone`, …). The navmesh is
**baked at runtime** from the generated mesh geometry, so map scenes stay tiny.

## Mission runner

`ObjectiveRunner` (host-only) walks a mission's objectives in order, spawning enemies,
polling zones/timers, and reporting progress text to all clients. New objective types are
added by extending its `_begin_objective()` / `_process()` — see
[missions.md](missions.md).

## Data flow (one frame, host)

```
input → player.gd (authority) → move_and_slide / weapon_manager.fire (hitscan)
      → target.hit() → receive_damage() on victim authority → death
      → host Game.add_kill → score_changed → broadcast to clients
bots: bot.gd (host) → perceive → navigate → shoot → same damage routing
```
