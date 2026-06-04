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

func _ready() -> void:
	add_to_group("world")
	spawner.spawn_function = Callable(self, "_spawn_combatant")
	_load_map()
	Game.match_active = true

	if Net.is_host():
		Game.reset_scores()
		Game.score_changed.connect(_host_broadcast_scores)
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
	# Spawn a player for every connected peer.
	for pid in Net.players.keys():
		_spawn_player(pid)
	if Game.is_coop():
		_start_coop()
	else:
		_start_deathmatch()

# ---------------------------------------------------------------- spawning

func _spawn_player(peer_id: int) -> void:
	var team: int = Game.TEAM_PLAYERS if Game.is_coop() else peer_id  # FFA: unique team
	var xform := get_spawn_transform(false)
	Game.register_combatant(peer_id, Net.get_player_name(peer_id), false, team)
	spawner.spawn({
		"type": "player",
		"id": peer_id,
		"team": team,
		"name": Net.get_player_name(peer_id),
		"pos": xform.origin,
	})

func spawn_enemy(skill: float, respawns: bool, at: Vector3 = Vector3.INF) -> int:
	_bot_counter += 1
	var id := -1000 - _bot_counter
	var team: int = Game.TEAM_ENEMIES if Game.is_coop() else id  # FFA: unique team
	var pos := at
	if pos == Vector3.INF:
		pos = get_spawn_transform(true).origin
	Game.register_combatant(id, "Bot %d" % _bot_counter, true, team)
	spawner.spawn({
		"type": "bot",
		"id": id,
		"team": team,
		"name": "Bot %d" % _bot_counter,
		"skill": skill,
		"respawns": respawns,
		"pos": pos,
	})
	return id

## Runs on every peer (via MultiplayerSpawner) to construct the node from data.
func _spawn_combatant(data: Dictionary) -> Node:
	if data["type"] == "player":
		var p := PLAYER_SCENE.instantiate()
		p.name = "P%d" % int(data["id"])
		p.combatant_id = int(data["id"])
		p.team = int(data["team"])
		p.display_name = String(data["name"])
		p.position = data["pos"]
		p.set_multiplayer_authority(int(data["id"]))
		return p
	else:
		var b := BOT_SCENE.instantiate()
		b.name = "B%d" % absi(int(data["id"]))
		b.position = data["pos"]
		# Authority stays with the host (default), which drives the AI.
		b.configure(int(data["id"]), int(data["team"]), float(data["skill"]), bool(data["respawns"]), String(data["name"]))
		if Net.is_host():
			b.died.connect(_on_bot_died)
		return b

func _on_bot_died(_attacker_id: int, victim_id: int) -> void:
	if _objective_runner and _objective_runner.has_method("notify_enemy_killed"):
		_objective_runner.notify_enemy_killed(victim_id)

# ---------------------------------------------------------------- modes

func _start_deathmatch() -> void:
	set_objective_text.rpc("Deathmatch — first to %d frags" % int(Game.config["frag_limit"]))
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true)

func _start_coop() -> void:
	var mission := Missions.get_mission(Game.config.get("mission_id", ""))
	if mission.is_empty():
		set_objective_text.rpc("No mission loaded.")
		return
	_objective_runner = OBJECTIVE_RUNNER.new()
	_objective_runner.name = "ObjectiveRunner"
	add_child(_objective_runner)
	_objective_runner.start(self, mission)

# ---------------------------------------------------------------- helpers

func get_spawn_transform(prefer_enemy: bool) -> Transform3D:
	var group := "spawn_enemy" if prefer_enemy else "spawn_player"
	var markers := get_tree().get_nodes_in_group(group)
	if markers.is_empty():
		markers = get_tree().get_nodes_in_group("spawn_player")
	if markers.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	var m: Node3D = markers[randi() % markers.size()]
	var t := m.global_transform
	t.origin += Vector3.UP * 0.2
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
