extends Node
## Headless host half of the networking test. Hosts, waits for a client, starts
## the match, then reports what spawned on the host side.

func _ready() -> void:
	Game.player_name = "Host"
	Game.config = {
		"mode": Game.Mode.DEATHMATCH,
		"map": "res://maps/arena.tscn",
		"mission_id": "",
		"bot_count": 2,
		"bot_skill": 1.0,
		"frag_limit": 25,
		"time_limit": 600,
	}
	Net.match_started.connect(_load_world)
	Net.host_game()
	print("NETHOST: hosting on ", Net.DEFAULT_PORT)
	# Wait for a client (up to ~15s).
	var waited := 0.0
	while Net.players.size() < 2 and waited < 15.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	print("NETHOST: peers after wait = ", Net.players.size())
	if Net.players.size() < 2:
		print("NETHOST: no client connected — FAIL")
		get_tree().quit()
		return
	print("NETHOST: starting match")
	Net.start_match()
	await get_tree().create_timer(6.0).timeout
	print("NETHOST: net_players=", Net.players.size(),
		" world_players=", get_tree().get_nodes_in_group("player").size(),
		" bots=", get_tree().get_nodes_in_group("bot").size())
	print("NETHOST: DONE")
	# Stay alive long enough for the client to take its measurement.
	await get_tree().create_timer(16.0).timeout
	get_tree().quit()

func _load_world() -> void:
	await get_tree().process_frame
	get_tree().root.add_child(load("res://scenes/world.tscn").instantiate())
