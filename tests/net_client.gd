extends Node
## Headless client half of the networking test. Connects to a local host, then
## reports what got replicated to the client side (players + bots).

func _ready() -> void:
	Game.player_name = "Client"
	Net.match_started.connect(_load_world)
	Net.connection_succeeded.connect(func(): print("NETCLIENT: connected to host"))
	Net.server_disconnected.connect(func(): print("NETCLIENT: server disconnected"))
	Net.connection_failed.connect(func(): print("NETCLIENT: connection failed"))
	# Give the host a moment to bind the port.
	await get_tree().create_timer(2.5).timeout
	print("NETCLIENT: joining 127.0.0.1")
	Net.join_game("127.0.0.1")
	await get_tree().create_timer(6.0).timeout
	print("NETCLIENT: net_players=", Net.players.size(),
		" world_players=", get_tree().get_nodes_in_group("player").size(),
		" bots=", get_tree().get_nodes_in_group("bot").size())
	print("NETCLIENT: DONE")
	get_tree().quit()

func _load_world() -> void:
	await get_tree().process_frame
	get_tree().root.add_child(load("res://scenes/world.tscn").instantiate())
