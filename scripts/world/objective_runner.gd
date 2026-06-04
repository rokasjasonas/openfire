extends Node
## Host-only driver that executes a mission's objectives in order.
## Add a new objective TYPE by adding a branch in _begin_objective() and _process().
##
## Supported objective types:
##   eliminate_all   { enemy_count, wave_size }   kill a fixed number of enemies
##   eliminate_count { enemy_count, wave_size }   (alias of eliminate_all)
##   reach_zone      { zone }                      get all living players into a zone
##   survive_time    { duration, spawn_interval, wave_size }
##   defend          { zone, duration, spawn_interval, wave_size }

var world: Node
var mission: Dictionary
var objectives: Array = []
var index: int = 0
var current: Dictionary = {}

var _skill: float = 1.0
var _active: bool = false

# eliminate state
var _kill_target: int = 0
var _killed: int = 0
var _spawned: int = 0
var _concurrent: int = 4

# timed state
var _time_left: float = 0.0
var _spawn_interval: float = 4.0
var _spawn_accum: float = 0.0
var _last_announce: int = -1

func start(w: Node, m: Dictionary) -> void:
	world = w
	mission = m
	objectives = m.get("objectives", [])
	_skill = float(m.get("enemy_skill", Game.config.get("bot_skill", 1.0)))
	index = 0
	set_process(false)
	_begin_objective()

func _begin_objective() -> void:
	if index >= objectives.size():
		_complete_mission()
		return
	current = objectives[index]
	var desc: String = current.get("description", current.get("type", "Objective"))
	world.broadcast_objective("[%d/%d] %s" % [index + 1, objectives.size(), desc])
	_active = true
	_last_announce = -1
	match current.get("type", ""):
		"eliminate_all", "eliminate_count":
			_kill_target = int(current.get("enemy_count", 8))
			_concurrent = int(current.get("wave_size", 4))
			_killed = 0
			_spawned = 0
			_maintain_enemies()
		"reach_zone":
			pass  # polled in _process
		"survive_time", "defend":
			_time_left = float(current.get("duration", 60))
			_spawn_interval = float(current.get("spawn_interval", 4.0))
			_concurrent = int(current.get("wave_size", 5))
			_spawn_accum = 0.0
		_:
			push_warning("ObjectiveRunner: unknown objective type '%s' — skipping" % current.get("type", ""))
			_advance()
			return
	set_process(true)

func _maintain_enemies() -> void:
	# Keep up to _concurrent enemies alive until _kill_target have been spawned.
	while _spawned < _kill_target and world.count_alive_enemies() < _concurrent:
		world.spawn_enemy(_skill, false)
		_spawned += 1

## Called by world when any bot dies.
func notify_enemy_killed(_victim_id: int) -> void:
	if not _active:
		return
	var t: String = current.get("type", "")
	if t == "eliminate_all" or t == "eliminate_count":
		_killed += 1
		world.broadcast_objective("[%d/%d] %s  (%d/%d)" % [
			index + 1, objectives.size(), current.get("description", "Eliminate"), _killed, _kill_target])
		if _killed >= _kill_target:
			_advance()
		else:
			_maintain_enemies()

func _process(delta: float) -> void:
	if not _active:
		return
	match current.get("type", ""):
		"reach_zone":
			_check_reach_zone()
		"survive_time", "defend":
			_tick_timed(delta)

func _check_reach_zone() -> void:
	var zone := _find_zone(current.get("zone", "extraction"))
	if zone == null:
		_advance()
		return
	var alive: Array = world.alive_players()
	if alive.is_empty():
		return
	var inside := 0
	for b in zone.get_overlapping_bodies():
		if b.is_in_group("player") and not b.get("dead"):
			inside += 1
	if inside >= alive.size():
		_advance()

func _tick_timed(delta: float) -> void:
	_time_left -= delta
	var secs := int(ceil(_time_left))
	if secs != _last_announce:
		_last_announce = secs
		var label: String = current.get("description", "Hold out")
		world.broadcast_objective("[%d/%d] %s  (%ds)" % [index + 1, objectives.size(), label, max(0, secs)])
	_spawn_accum += delta
	if _spawn_accum >= _spawn_interval:
		_spawn_accum = 0.0
		var to_spawn: int = _concurrent - world.count_alive_enemies()
		for i in max(0, to_spawn):
			world.spawn_enemy(_skill, false)
	if _time_left <= 0.0:
		_advance()

func _advance() -> void:
	_active = false
	set_process(false)
	index += 1
	# brief beat before the next objective
	await get_tree().create_timer(1.5).timeout
	_begin_objective()

func _complete_mission() -> void:
	world.broadcast_objective("Mission complete!")
	Game.end_match({"reason": "mission_complete", "success": true, "mission": mission.get("name", "")})

func _find_zone(zone_id: String) -> Area3D:
	for z in get_tree().get_nodes_in_group("zone"):
		if z.get_meta("zone_id", "") == zone_id:
			return z
	return null
