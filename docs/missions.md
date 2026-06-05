# Mission configuration

Co-op missions are plain JSON files in [`../missions/`](../missions/). They are discovered
and loaded automatically at launch (sorted by filename — prefix with `01_`, `02_`, … to
control order). **Adding a mission requires no code changes.**

## File schema

```jsonc
{
  "id": "unique_id",                 // required, unique
  "name": "Display Name",            // required, shown in the menu
  "description": "Short briefing.",  // shown on the HUD
  "map": "res://maps/facility.tscn", // required, which map to load
  "enemy_skill": 1.0,                // 0.6 easy … 1.4 hard; scales bot accuracy/cadence
  "objectives": [ /* one or more, run in order */ ]
}
```

## Objective types

Objectives run **sequentially**, top to bottom. Each is an object with a `type`,
a `description` (shown on the HUD), and type-specific parameters.

| `type` | Parameters | Completes when |
| --- | --- | --- |
| `eliminate_all` | `enemy_count`, `wave_size` | `enemy_count` enemies have been killed (kept topped up to `wave_size` concurrent) |
| `eliminate_count` | `enemy_count`, `wave_size` | alias of `eliminate_all` |
| `reach_zone` | `zone` | all living players stand inside the named zone |
| `survive_time` | `duration`, `spawn_interval`, `wave_size` | `duration` seconds elapse (enemies keep spawning) |
| `defend` | `zone`, `duration`, `spawn_interval`, `wave_size` | like `survive_time`, themed as holding a zone |
| `hold_console` | `zone`, `duration`, `wave_size`, `spawn_interval` | a player stands in the zone for a **cumulative** `duration` (progress slips back if abandoned); optional reinforcement pressure |
| `destroy_target` | `at` \| `zone`, `health`, `wave_size`, `spawn_interval` | a destructible objective (reactor/console) is shot down to 0 HP; optional defenders |
| `escort` | `from`, `to`, `speed`, `wave_size`, `spawn_interval` | a VIP walks from `from` to `to` — it only advances while a living player stays within ~10 m |
| `boss` | `boss_type`, `skill_mult`, `adds` | a boss enemy (default the `boss`/WARLORD archetype) is killed; `adds` reinforcements are kept alive until it falls |

### Zones & positions

`reach_zone` / `defend` / `hold_console` reference a **named zone** placed by the map.
`destroy_target` (`at`) and `escort` (`from`, `to`) accept **either** a zone id string
**or** an explicit `[x, y, z]` world-coordinate array. The `facility` map
provides: `alpha`, `bravo`, `defend`, `extraction`. To add zones, edit the map's
`build_level()` and call `add_zone("my_zone", position, size)` (see
[`../scripts/world/facility.gd`](../scripts/world/facility.gd)).

## Example

```json
{
  "id": "clear_the_facility",
  "name": "Clear the Facility",
  "description": "Sweep the compound of all hostiles, then reach the extraction point.",
  "map": "res://maps/facility.tscn",
  "enemy_skill": 0.9,
  "objectives": [
    { "type": "eliminate_all", "description": "Eliminate all hostiles", "enemy_count": 12, "wave_size": 4 },
    { "type": "reach_zone", "description": "Reach the extraction point", "zone": "extraction" }
  ]
}
```

## Adding a new objective TYPE (code)

Objective runtime lives in
[`../scripts/world/objective_runner.gd`](../scripts/world/objective_runner.gd).
Add a branch in `_begin_objective()` (setup) and, if it needs per-frame logic, in
`_process()`. Call `_advance()` to move to the next objective. Enemies are spawned via
`world.spawn_enemy(skill, respawns)`.
