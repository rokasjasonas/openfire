extends Node3D
## The in-match scene. The host is authoritative: it loads the map, waits for all
## clients to report their world ready, then spawns every player + the bots and
## starts the selected mode (deathmatch or co-op mission).

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const BOT_SCENE := preload("res://scenes/bot.tscn")
const OBJECTIVE_RUNNER := preload("res://scripts/world/objective_runner.gd")

@onready var map_holder: Node3D = $MapHolder
@onready var combatants: Node3D = $Combatants
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var hud = $HUD

var _bot_counter: int = 0
var _expected_peers: Array = []
var _ready_peers: Dictionary = {}
var _begun: bool = false
var _objective_runner: Node = null
var _player_team: Dictionary = {}

func _ready() -> void:
	add_to_group("world")
	spawner.spawn_function = Callable(self, "_spawn_combatant")
	_load_map()
	Game.match_active = true

	if Net.is_host():
		Game.reset_scores()
		Game.score_changed.connect(_host_broadcast_scores)
		Game.kill_logged.connect(_host_on_kill)
		Game.match_over.connect(_host_on_match_over)
		_expected_peers = Net.players.keys()
		_ready_peers[1] = true
		# Fallback: begin anyway after a short grace period.
		get_tree().create_timer(5.0).timeout.connect(_begin)
		_try_begin()
	else:
		_report_ready.rpc_id(1)

func _load_map() -> void:
	var map_path: String = Game.config["map"]
	if Game.is_coop():
		var m := Missions.get_mission(Game.config.get("mission_id", ""))
		if not m.is_empty():
			map_path = m["map"]
	if not ResourceLoader.exists(map_path):
		map_path = "res://maps/arena.tscn"
	var map: Node = load(map_path).instantiate()
	map_holder.add_child(map)

# ---------------------------------------------------------------- start handshake

@rpc("any_peer", "reliable")
func _report_ready() -> void:
	if not Net.is_host():
		return
	_ready_peers[multiplayer.get_remote_sender_id()] = true
	_try_begin()

func _try_begin() -> void:
	if _begun or not Net.is_host():
		return
	# Begin as soon as every expected peer has reported its world ready.
	# (The 5s grace timer in _ready() calls _begin() directly as a fallback.)
	for pid in _expected_peers:
		if not _ready_peers.has(pid):
			return
	_begin()

func _begin() -> void:
	if _begun:
		return
	_begun = true
	if Game.is_team_deathmatch() or Game.is_domination():
		_assign_teams()
	# Spawn a player for every connected peer.
	for pid in Net.players.keys():
		_spawn_player(pid)
	if Game.is_coop():
		_start_coop()
	elif Game.is_team_deathmatch():
		_start_team_deathmatch()
	elif Game.is_domination():
		_start_domination()
	else:
		_start_deathmatch()

func _assign_teams() -> void:
	# Alternate connected peers between the two teams for rough balance.
	var ids := Net.players.keys()
	ids.sort()
	for i in ids.size():
		_player_team[ids[i]] = i % 2

# ---------------------------------------------------------------- spawning

func _spawn_player(peer_id: int) -> void:
	var team: int
	if Game.is_coop():
		team = Game.TEAM_PLAYERS
	elif Game.is_team_deathmatch() or Game.is_domination():
		team = _player_team.get(peer_id, 0)
	else:
		team = peer_id  # FFA: unique team
	var xform := get_spawn_transform(false)
	Game.register_combatant(peer_id, Net.get_player_name(peer_id), false, team)
	spawner.spawn({
		"type": "player",
		"id": peer_id,
		"team": team,
		"name": Net.get_player_name(peer_id),
		"pos": xform.origin,
	})

func spawn_enemy(skill: float, respawns: bool, at: Vector3 = Vector3.INF, etype: String = "", team_override: int = -999) -> int:
	_bot_counter += 1
	var id := -1000 - _bot_counter
	var team: int
	if team_override != -999:
		team = team_override
	elif Game.is_coop():
		team = Game.TEAM_ENEMIES
	else:
		team = id  # FFA: unique team
	var pos := at
	if pos == Vector3.INF:
		pos = get_spawn_transform(true).origin
	if etype == "":
		etype = _random_enemy_type()
	Game.register_combatant(id, "Bot %d" % _bot_counter, true, team)
	spawner.spawn({
		"type": "bot",
		"id": id,
		"team": team,
		"name": "Bot %d" % _bot_counter,
		"skill": skill,
		"respawns": respawns,
		"pos": pos,
		"etype": etype,
	})
	return id

const BOT_SCRIPT := preload("res://scripts/ai/bot.gd")
const TARGET_SCRIPT := preload("res://scripts/world/destructible_target.gd")
const ESCORT_SCRIPT := preload("res://scripts/world/escort_marker.gd")

func _random_enemy_type() -> String:
	var weights: Dictionary = BOT_SCRIPT.SPAWN_WEIGHTS
	var total := 0
	for k in weights:
		total += int(weights[k])
	var r := randi() % maxi(total, 1)
	for k in weights:
		r -= int(weights[k])
		if r < 0:
			return k
	return "soldier"

## Runs on every peer (via MultiplayerSpawner) to construct the node from data.
func _spawn_combatant(data: Dictionary) -> Node:
	match String(data["type"]):
		"player":
			var p := PLAYER_SCENE.instantiate()
			p.name = "P%d" % int(data["id"])
			p.combatant_id = int(data["id"])
			p.team = int(data["team"])
			p.display_name = String(data["name"])
			p.position = data["pos"]
			p.set_multiplayer_authority(int(data["id"]))
			return p
		"target":
			var t: Node3D = TARGET_SCRIPT.new()
			t.name = "T%d" % absi(int(data["id"]))
			t.position = data["pos"]
			t.setup(int(data["id"]), float(data["health"]))
			return t
		"escort":
			var e: Node3D = ESCORT_SCRIPT.new()
			e.name = "E%d" % absi(int(data["id"]))
			e.position = data["pos"]
			e.setup(int(data["id"]), data["dest"], float(data["speed"]))
			return e
		_:
			var b := BOT_SCENE.instantiate()
			b.name = "B%d" % absi(int(data["id"]))
			b.position = data["pos"]
			# Authority stays with the host (default), which drives the AI.
			b.configure(int(data["id"]), int(data["team"]), float(data["skill"]), bool(data["respawns"]), String(data["name"]), String(data.get("etype", "soldier")))
			if Net.is_host():
				b.died.connect(_on_bot_died)
			return b

## Host-only: spawn a destructible objective target (replicated). Returns the node.
func spawn_target(pos: Vector3, health: float) -> Node:
	_bot_counter += 1
	var id := -3000 - _bot_counter
	return spawner.spawn({"type": "target", "id": id, "pos": pos, "health": health})

## Host-only: spawn an escort VIP that walks from its spawn to `dest`. Returns the node.
func spawn_escort(from: Vector3, dest: Vector3, speed: float) -> Node:
	_bot_counter += 1
	var id := -4000 - _bot_counter
	return spawner.spawn({"type": "escort", "id": id, "pos": from, "dest": dest, "speed": speed})

func _on_bot_died(_attacker_id: int, victim_id: int) -> void:
	if _objective_runner and _objective_runner.has_method("notify_enemy_killed"):
		_objective_runner.notify_enemy_killed(victim_id)

# ---------------------------------------------------------------- modes

func _start_deathmatch() -> void:
	set_objective_text.rpc("Deathmatch — first to %d frags" % int(Game.config["frag_limit"]))
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true)

func _start_team_deathmatch() -> void:
	set_objective_text.rpc("Team Deathmatch — %s vs %s, first to %d" % [
		Game.team_name(0), Game.team_name(1), int(Game.config["frag_limit"])])
	# Fill both teams with bots, alternating.
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true, Vector3.INF, "", i % 2)

# ---------------------------------------------------------------- domination

const DOM_CAP_RATE := 0.4
var _dom_score_t := 0.0
var _dom_sync_t := 0.0

func _start_domination() -> void:
	set_objective_text.rpc("Domination — hold the points to score, first to %d" % Game.DOM_LIMIT)
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true, Vector3.INF, "", i % 2)
	set_process(true)

func _process(delta: float) -> void:
	if not Net.is_host() or not Game.is_domination() or not Game.match_active:
		return
	_dom_sync_t += delta
	var broadcast := _dom_sync_t >= 0.25
	if broadcast:
		_dom_sync_t = 0.0
	for cp in get_tree().get_nodes_in_group("control_point"):
		var counts: Array = cp.team_counts()
		var blue: int = counts[0]
		var red: int = counts[1]
		if blue > 0 and red == 0:
			cp.bar = minf(1.0, cp.bar + DOM_CAP_RATE * delta)
		elif red > 0 and blue == 0:
			cp.bar = maxf(-1.0, cp.bar - DOM_CAP_RATE * delta)
		if cp.bar >= 0.99:
			cp.owner_team = 0
		elif cp.bar <= -0.99:
			cp.owner_team = 1
		else:
			cp.owner_team = -1
		if broadcast:
			cp.set_state.rpc(cp.bar, cp.owner_team)
	_dom_score_t += delta
	if _dom_score_t >= 1.0:
		_dom_score_t = 0.0
		for cp in get_tree().get_nodes_in_group("control_point"):
			if cp.owner_team >= 0:
				Game.add_dom_point(cp.owner_team)
		_sync_dom.rpc(Game.dom_score.duplicate())

@rpc("authority", "call_local", "reliable")
func _sync_dom(scores_arr: Array) -> void:
	if not Net.is_host():
		Game.dom_score = scores_arr
		Game.dom_changed.emit()

func _start_coop() -> void:
	var mission := Missions.get_mission(Game.config.get("mission_id", ""))
	if mission.is_empty():
		set_objective_text.rpc("No mission loaded.")
		return
	_set_lives.rpc(int(mission.get("lives", 6)))
	_objective_runner = OBJECTIVE_RUNNER.new()
	_objective_runner.name = "ObjectiveRunner"
	add_child(_objective_runner)
	_objective_runner.start(self, mission)

# ---------------------------------------------------------------- co-op lives

@rpc("authority", "call_local", "reliable")
func _set_lives(n: int) -> void:
	Game.coop_lives = n
	Game.lives_changed.emit(n)

## A downed player bled out and asks the host for a shared life.
@rpc("any_peer", "reliable")
func request_life(victim_id: int) -> void:
	if not Net.is_host():
		return
	var granted := Game.coop_lives > 0
	if granted:
		Game.coop_lives -= 1
	_life_result.rpc(victim_id, granted, Game.coop_lives)

@rpc("authority", "call_local", "reliable")
func _life_result(victim_id: int, granted: bool, lives: int) -> void:
	Game.coop_lives = lives
	Game.lives_changed.emit(lives)
	var p := _player_by_id(victim_id)
	if p and p.is_multiplayer_authority():
		p.apply_life_result(granted)
	if Net.is_host():
		check_coop_wipe()

func _player_by_id(id: int) -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p.combatant_id == id:
			return p
	return null

## Host: mission fails if no one can act and there are no lives left to recover.
func check_coop_wipe() -> void:
	if not Net.is_host() or not Game.is_coop() or not Game.match_active:
		return
	if Game.coop_lives > 0:
		return
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead") and not p.get("downed") and not p.get("fully_dead"):
			return  # someone is still up
	Game.end_match({"reason": "mission_failed"})

# ---------------------------------------------------------------- helpers

func get_spawn_transform(prefer_enemy: bool) -> Transform3D:
	var group := "spawn_enemy" if prefer_enemy else "spawn_player"
	var markers := get_tree().get_nodes_in_group(group)
	if markers.is_empty():
		markers = get_tree().get_nodes_in_group("spawn_player")
	if markers.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	# Pick the marker farthest from any living combatant so two bodies never
	# spawn on top of each other (overlapping capsules get violently ejected
	# upward by depenetration). Random order breaks ties / adds variety.
	markers.shuffle()
	var combatants := get_tree().get_nodes_in_group("combatant")
	var best: Node3D = markers[0]
	var best_clearance := -1.0
	for m in markers:
		var nearest := INF
		for c in combatants:
			if not is_instance_valid(c) or c.get("dead"):
				continue
			nearest = minf(nearest, m.global_position.distance_to(c.global_position))
		if nearest > best_clearance:
			best_clearance = nearest
			best = m
	var t := best.global_transform
	# Small horizontal jitter + slight lift so simultaneous spawns never coincide.
	t.origin += Vector3(randf_range(-0.7, 0.7), 0.3, randf_range(-0.7, 0.7))
	t.basis = Basis.IDENTITY
	return t

func count_alive_enemies() -> int:
	var c := 0
	for b in get_tree().get_nodes_in_group("bot"):
		if not b.get("dead"):
			c += 1
	return c

func alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead"):
			out.append(p)
	return out

# ---------------------------------------------------------------- replicated UI

@rpc("authority", "call_local", "reliable")
func set_objective_text(t: String) -> void:
	if hud and hud.has_method("set_objective"):
		hud.set_objective(t)

func broadcast_objective(t: String) -> void:
	if Net.is_host():
		set_objective_text.rpc(t)

func _host_broadcast_scores() -> void:
	_recv_scores.rpc(Game.scores)

@rpc("authority", "call_local", "reliable")
func _recv_scores(data: Dictionary) -> void:
	if not Net.is_host():
		Game.scores = data
		Game.score_changed.emit()

func _host_on_kill(killer_id: int, victim_id: int) -> void:
	var killer: String = Game.scores.get(killer_id, {}).get("name", "?")
	var victim: String = Game.scores.get(victim_id, {}).get("name", "?")
	var kt: int = int(Game.scores.get(killer_id, {}).get("team", -1))
	var vt: int = int(Game.scores.get(victim_id, {}).get("team", -1))
	var suicide := killer_id == victim_id
	_kill_feed.rpc(killer, victim, suicide, kt, vt)

@rpc("authority", "call_local", "reliable")
func _kill_feed(killer: String, victim: String, suicide: bool, killer_team: int, victim_team: int) -> void:
	if hud and hud.has_method("add_kill_feed"):
		hud.add_kill_feed(killer, victim, suicide, killer_team, victim_team)

# ---------------------------------------------------------------- match end

func _host_on_match_over(result: Dictionary) -> void:
	_show_result.rpc(result)

@rpc("authority", "call_local", "reliable")
func _show_result(result: Dictionary) -> void:
	Game.match_active = false
	if hud and hud.has_method("show_result"):
		hud.show_result(result)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().create_timer(7.0).timeout
	_leave_to_menu()

func _leave_to_menu() -> void:
	Net.disconnect_net()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
