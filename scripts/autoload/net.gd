extends Node
## High-level multiplayer over ENet for LAN / direct-IP play.
##
## The host is always peer id 1 and is authoritative for game logic and bots.
## "Solo vs bots" is just a host on localhost that starts immediately, so there
## is a single code path for offline and networked play.

signal players_changed
signal connection_succeeded
signal connection_failed
signal server_disconnected
signal match_started

const DEFAULT_PORT := 27015
const MAX_PLAYERS := 8

var peer: ENetMultiplayerPeer = null
# peer_id -> { "name": String }
var players: Dictionary = {}

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT) -> bool:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		push_error("Net: failed to create server on port %d (err %d)" % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	players.clear()
	players[1] = {"name": Game.player_name}
	players_changed.emit()
	return true

func join_game(ip: String, port: int = DEFAULT_PORT) -> bool:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		push_error("Net: failed to create client to %s:%d (err %d)" % [ip, port, err])
		return false
	multiplayer.multiplayer_peer = peer
	return true

func disconnect_net() -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	peer = null
	players.clear()
	players_changed.emit()

func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()

func local_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 1
	return multiplayer.get_unique_id()

func get_player_name(id: int) -> String:
	if players.has(id):
		return players[id]["name"]
	return "Player %d" % id

# ---------------------------------------------------------------- connection cb

func _on_peer_connected(_id: int) -> void:
	# Server waits for the newcomer to register its name (see _register_player).
	pass

func _on_peer_disconnected(id: int) -> void:
	if is_host():
		players.erase(id)
		_sync_players.rpc(players)
		players_changed.emit()

func _on_connected_to_server() -> void:
	# Client side: announce our chosen name to the host.
	_register_player.rpc_id(1, Game.player_name)
	connection_succeeded.emit()

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	peer = null
	connection_failed.emit()

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	peer = null
	players.clear()
	server_disconnected.emit()

# ---------------------------------------------------------------- rpcs

@rpc("any_peer", "reliable")
func _register_player(pname: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	players[id] = {"name": pname}
	# Bring the newcomer (and everyone) up to date.
	_sync_players.rpc(players)
	_sync_config.rpc(Game.config)
	players_changed.emit()

@rpc("authority", "reliable")
func _sync_players(p: Dictionary) -> void:
	players = p
	players_changed.emit()

@rpc("authority", "reliable")
func _sync_config(cfg: Dictionary) -> void:
	Game.config = cfg

## Host pushes the latest config to everyone (call when lobby settings change).
func push_config() -> void:
	if is_host():
		_sync_config.rpc(Game.config)

## Host starts the match: sync config one last time, then load the world on all peers.
func start_match() -> void:
	if not is_host():
		return
	_sync_config.rpc(Game.config)
	_do_start.rpc()

@rpc("authority", "call_local", "reliable")
func _do_start() -> void:
	match_started.emit()
