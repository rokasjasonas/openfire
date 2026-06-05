extends Control
## Main menu + lobby. Configure a match, then Host / Join (by IP) / Solo-vs-bots.
## The host captures settings into Game.config; Net replicates them to clients.

const MAPS := [
	{ "name": "Arena", "path": "res://maps/arena.tscn" },
	{ "name": "Facility", "path": "res://maps/facility.tscn" },
	{ "name": "Highlands", "path": "res://maps/highlands.tscn" },
	{ "name": "Warehouse", "path": "res://maps/warehouse.tscn" },
	{ "name": "Ruins", "path": "res://maps/ruins.tscn" },
	{ "name": "Compound", "path": "res://maps/compound.tscn" },
]
const SKILLS := [
	{ "name": "Easy", "value": 0.6 },
	{ "name": "Normal", "value": 1.0 },
	{ "name": "Hard", "value": 1.4 },
]

@onready var setup_panel: Control = %SetupPanel
@onready var lobby_panel: Control = %LobbyPanel
@onready var name_edit: LineEdit = %NameEdit
@onready var mode_option: OptionButton = %ModeOption
@onready var map_row: Control = %MapRow
@onready var map_option: OptionButton = %MapOption
@onready var mission_row: Control = %MissionRow
@onready var mission_option: OptionButton = %MissionOption
@onready var frag_row: Control = %FragRow
@onready var frag_spin: SpinBox = %FragSpin
@onready var bots_spin: SpinBox = %BotsSpin
@onready var skill_option: OptionButton = %SkillOption
@onready var ip_edit: LineEdit = %IpEdit
@onready var status_label: Label = %StatusLabel
@onready var lobby_players: VBoxContainer = %LobbyPlayers
@onready var lobby_summary: Label = %LobbySummary
@onready var start_button: Button = %StartButton
@onready var options_panel: Control = %OptionsPanel

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Net.players_changed.connect(_refresh_lobby)
	Net.connection_succeeded.connect(_on_connected)
	Net.connection_failed.connect(_on_failed)
	Net.server_disconnected.connect(_on_server_disconnected)
	Net.match_started.connect(_on_match_started)

	name_edit.text = Game.player_name
	%VersionLabel.text = "v" + str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	mode_option.clear()
	mode_option.add_item("Deathmatch")
	mode_option.add_item("Co-op")
	mode_option.add_item("Team Deathmatch")
	map_option.clear()
	for m in MAPS:
		map_option.add_item(m["name"])
	skill_option.clear()
	for s in SKILLS:
		skill_option.add_item(s["name"])
	skill_option.selected = 1
	mission_option.clear()
	for mission in Missions.get_all():
		mission_option.add_item(mission["name"])

	%HostButton.pressed.connect(_on_host)
	%JoinButton.pressed.connect(_on_join)
	%SoloButton.pressed.connect(_on_solo)
	%QuitButton.pressed.connect(func(): get_tree().quit())
	mode_option.item_selected.connect(_on_mode_changed)
	start_button.pressed.connect(func(): Net.start_match())
	%BackButton.pressed.connect(_on_back)

	# Click sound on every button.
	for b in find_children("*", "Button", true):
		b.pressed.connect(func(): Audio.play_ui("res://assets/audio/ui_click.ogg", -4.0))

	_setup_options()
	_on_mode_changed(0)
	_show_setup()

func _setup_options() -> void:
	%SensSlider.value = Settings.mouse_sensitivity
	%VolSlider.value = Settings.master_volume
	%FovSlider.value = Settings.fov
	_update_option_labels()
	%SensSlider.value_changed.connect(_on_sens_changed)
	%VolSlider.value_changed.connect(_on_vol_changed)
	%FovSlider.value_changed.connect(_on_fov_changed)
	%OptionsButton.pressed.connect(_show_options)
	%OptionsBackButton.pressed.connect(_show_setup)

func _on_sens_changed(v: float) -> void:
	Settings.mouse_sensitivity = v
	_apply_and_save()

func _on_vol_changed(v: float) -> void:
	Settings.master_volume = v
	_apply_and_save()

func _on_fov_changed(v: float) -> void:
	Settings.fov = v
	_apply_and_save()

func _apply_and_save() -> void:
	_update_option_labels()
	Settings.apply()
	Settings.save()

func _update_option_labels() -> void:
	%SensValue.text = "%.2f" % Settings.mouse_sensitivity
	%VolValue.text = "%d%%" % int(round(Settings.master_volume * 100))
	%FovValue.text = "%d" % int(Settings.fov)

func _show_options() -> void:
	setup_panel.visible = false
	lobby_panel.visible = false
	options_panel.visible = true

func _on_mode_changed(_idx: int) -> void:
	var coop := mode_option.selected == 1
	map_row.visible = not coop
	frag_row.visible = not coop
	mission_row.visible = coop
	if coop and Missions.get_all().is_empty():
		status_label.text = "No missions found in res://missions/"

func _capture_config() -> void:
	Game.player_name = name_edit.text.strip_edges()
	if Game.player_name == "":
		Game.player_name = "Player"
	var coop := mode_option.selected == 1
	# Option order matches the Mode enum (0=Deathmatch, 1=Co-op, 2=Team Deathmatch).
	Game.config["mode"] = mode_option.selected
	Game.config["bot_count"] = int(bots_spin.value)
	Game.config["bot_skill"] = SKILLS[skill_option.selected]["value"]
	if coop:
		var missions := Missions.get_all()
		if not missions.is_empty():
			var m: Dictionary = missions[clampi(mission_option.selected, 0, missions.size() - 1)]
			Game.config["mission_id"] = m["id"]
			Game.config["map"] = m["map"]
	else:
		Game.config["map"] = MAPS[map_option.selected]["path"]
		Game.config["frag_limit"] = int(frag_spin.value)

# ---------------------------------------------------------------- buttons

func _on_host() -> void:
	_capture_config()
	if Net.host_game():
		status_label.text = "Hosting on port %d. Share your LAN IP with friends." % Net.DEFAULT_PORT
		_show_lobby()
	else:
		status_label.text = "Failed to host (port in use?)."

func _on_solo() -> void:
	_capture_config()
	Game.config["bot_count"] = maxi(1, int(bots_spin.value))
	if Net.host_game():
		Net.start_match()
	else:
		status_label.text = "Failed to start solo match."

func _on_join() -> void:
	Game.player_name = name_edit.text.strip_edges()
	if Game.player_name == "":
		Game.player_name = "Player"
	var ip := ip_edit.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	if Net.join_game(ip):
		status_label.text = "Connecting to %s…" % ip
	else:
		status_label.text = "Could not start client."

func _on_back() -> void:
	Net.disconnect_net()
	_show_setup()

# ---------------------------------------------------------------- net callbacks

func _on_connected() -> void:
	status_label.text = "Connected. Waiting for host to start…"
	_show_lobby()

func _on_failed() -> void:
	status_label.text = "Connection failed."
	_show_setup()

func _on_server_disconnected() -> void:
	status_label.text = "Disconnected from host."
	_show_setup()

func _on_match_started() -> void:
	get_tree().change_scene_to_file("res://scenes/world.tscn")

# ---------------------------------------------------------------- screens

func _show_setup() -> void:
	setup_panel.visible = true
	lobby_panel.visible = false
	options_panel.visible = false

func _show_lobby() -> void:
	setup_panel.visible = false
	options_panel.visible = false
	lobby_panel.visible = true
	start_button.visible = Net.is_host()
	_refresh_lobby()

func _refresh_lobby() -> void:
	if not lobby_panel.visible:
		return
	for c in lobby_players.get_children():
		c.queue_free()
	for pid in Net.players.keys():
		var l := Label.new()
		var tag := "  (host)" if pid == 1 else ""
		l.text = "• %s%s" % [Net.players[pid]["name"], tag]
		lobby_players.add_child(l)
	var summary := "%s" % Game.mode_name()
	if Game.is_coop():
		var m := Missions.get_mission(Game.config.get("mission_id", ""))
		summary += " — " + m.get("name", "?")
	else:
		summary += " — frag limit %d" % int(Game.config["frag_limit"])
	summary += "\nBots: %d (%s)" % [int(Game.config["bot_count"]), _skill_name(Game.config["bot_skill"])]
	lobby_summary.text = summary

func _skill_name(v: float) -> String:
	for s in SKILLS:
		if abs(s["value"] - v) < 0.01:
			return s["name"]
	return "Custom"
