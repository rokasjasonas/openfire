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
	{ "name": "Outpost (huge, vehicles)", "path": "res://maps/outpost.tscn" },
	{ "name": "Badlands (huge, vehicles)", "path": "res://maps/badlands.tscn" },
	{ "name": "Wasteland (massive, battle royale)", "path": "res://maps/wasteland.tscn" },
]
const SKILLS := [
	{ "name": "Easy", "value": 0.6 },
	{ "name": "Normal", "value": 1.0 },
	{ "name": "Hard", "value": 1.4 },
]
# Adventure uses one procedurally-generated terrain map, sized by map_size + seed.
const ADVENTURE_MAP := "res://maps/terrain.tscn"

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
@onready var mission_points_row: Control = %MissionPointsRow
@onready var mission_points_spin: SpinBox = %MissionPointsSpin
@onready var seed_row: Control = %SeedRow
@onready var seed_edit: LineEdit = %SeedEdit
@onready var theme_row: Control = %ThemeRow
@onready var theme_edit: LineEdit = %ThemeEdit
@onready var map_size_row: Control = %MapSizeRow
@onready var map_size_option: OptionButton = %MapSizeOption
@onready var inv_key_option: OptionButton = %InvKeyOption
@onready var character_row: Control = %CharacterRow
@onready var char_label: Label = %CharLabel
@onready var character_panel: Control = %CharacterPanel
@onready var create_panel: Control = %CreatePanel
@onready var char_list: VBoxContainer = %CharList

# Selectable inventory keys for Adventure (label + keycode).
const INV_KEYS := [
	{ "name": "Tab", "code": KEY_TAB },
	{ "name": "I", "code": KEY_I },
	{ "name": "B", "code": KEY_B },
	{ "name": "C", "code": KEY_C },
]

# Embedded llama.cpp models (Qwen2.5 Instruct, Q4_K_M GGUF). Downloaded on first
# Adventure start into user://models/. Bigger = better stories, larger download.
const AI_MODELS := [
	{
		"name": "Tiny — Qwen2.5 0.5B (~0.4 GB)",
		"file": "Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
		"url": "https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
	},
	{
		"name": "Small — Qwen2.5 1.5B (~1 GB)",
		"file": "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
		"url": "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
	},
	{
		"name": "Medium — Qwen2.5 3B (~2 GB)",
		"file": "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
		"url": "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf",
	},
	{
		"name": "Huge — Qwen2.5 7B (~4.7 GB)",
		"file": "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
		"url": "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf",
	},
]

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
	mode_option.add_item("Domination")
	mode_option.add_item("Battle Royale")
	mode_option.add_item("Adventure")
	mode_option.selected = Game.Mode.ADVENTURE  # Adventure is the default mode
	map_size_option.clear()
	for size_name in ["Tiny", "Small", "Medium", "Large"]:
		map_size_option.add_item(size_name)
	map_size_option.selected = 2   # Medium
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

	# Character screens (Adventure).
	%CreateKit.clear()
	for kit_id in Characters.KIT_IDS:
		%CreateKit.add_item(Characters.kit_name(kit_id))
	%CharBtn.pressed.connect(_show_characters)
	%ContinueBtn.pressed.connect(_on_continue)
	%CharBackBtn.pressed.connect(_show_setup)
	%NewCharBtn.pressed.connect(_show_create)
	%DeleteCharBtn.pressed.connect(_on_delete_character)
	%CreateConfirm.pressed.connect(_on_create_confirm)
	%CreateCancel.pressed.connect(_show_characters)
	_update_char_label()

	# Click sound on every button.
	for b in find_children("*", "Button", true):
		b.pressed.connect(func(): Audio.play_ui("res://assets/audio/ui_click.ogg", -4.0))

	_setup_options()
	_on_mode_changed(mode_option.selected)
	_show_setup()

func _setup_options() -> void:
	%SensSlider.value = Settings.mouse_sensitivity
	%VolSlider.value = Settings.master_volume
	%FovSlider.value = Settings.fov
	inv_key_option.clear()
	var sel := 0
	for i in INV_KEYS.size():
		inv_key_option.add_item(INV_KEYS[i]["name"])
		if int(INV_KEYS[i]["code"]) == Settings.inventory_keycode:
			sel = i
	inv_key_option.selected = sel
	# Embedded AI model preset: match the saved file to a preset (default Small).
	%LlmEmbedOption.clear()
	var msel := 1
	for i in AI_MODELS.size():
		%LlmEmbedOption.add_item(String(AI_MODELS[i]["name"]))
		if String(AI_MODELS[i]["file"]) == Settings.llm_model_file:
			msel = i
	%LlmEmbedOption.selected = msel
	%LlmEmbedOption.item_selected.connect(_on_llm_embed_changed)
	_update_option_labels()
	%SensSlider.value_changed.connect(_on_sens_changed)
	%VolSlider.value_changed.connect(_on_vol_changed)
	%FovSlider.value_changed.connect(_on_fov_changed)
	inv_key_option.item_selected.connect(_on_inv_key_changed)
	%LlmEndpointEdit.text = Settings.llm_endpoint
	%LlmModelEdit.text = Settings.llm_model
	%LlmEndpointEdit.text_changed.connect(_on_llm_endpoint_changed)
	%LlmModelEdit.text_changed.connect(_on_llm_model_changed)
	%OptionsButton.pressed.connect(_show_options)
	%OptionsBackButton.pressed.connect(_show_setup)

func _on_llm_embed_changed(idx: int) -> void:
	var m: Dictionary = AI_MODELS[clampi(idx, 0, AI_MODELS.size() - 1)]
	Settings.llm_model_url = String(m["url"])
	Settings.llm_model_file = String(m["file"])
	Settings.save()

func _on_llm_endpoint_changed(t: String) -> void:
	Settings.llm_endpoint = t.strip_edges()
	Settings.save()

func _on_llm_model_changed(t: String) -> void:
	Settings.llm_model = t.strip_edges()
	Settings.save()

func _on_inv_key_changed(idx: int) -> void:
	Settings.inventory_keycode = int(INV_KEYS[clampi(idx, 0, INV_KEYS.size() - 1)]["code"])
	Settings.save()

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
	character_panel.visible = false
	create_panel.visible = false

func _on_mode_changed(_idx: int) -> void:
	var coop := mode_option.selected == 1
	var br := mode_option.selected == 4  # Battle Royale: no frag limit, last one alive wins
	var adventure := mode_option.selected == 5
	map_row.visible = not coop and not adventure      # Adventure picks a size, not a map
	frag_row.visible = not coop and not br and not adventure
	mission_row.visible = coop
	mission_points_row.visible = adventure
	seed_row.visible = adventure
	map_size_row.visible = adventure
	theme_row.visible = adventure
	character_row.visible = adventure
	# Adventure hides the manual NPC count, but keeps the difficulty (Bot skill) selector.
	bots_spin.get_parent().visible = not adventure
	if coop and Missions.get_all().is_empty():
		status_label.text = "No missions found in res://missions/"

func _capture_config() -> void:
	Game.player_name = name_edit.text.strip_edges()
	if Game.player_name == "":
		Game.player_name = "Player"
	var coop := mode_option.selected == 1
	var adventure := mode_option.selected == 5
	# Option order matches the Mode enum (0=Deathmatch … 5=Adventure).
	Game.config["mode"] = mode_option.selected
	Game.config["bot_count"] = int(bots_spin.value)
	Game.config["bot_skill"] = SKILLS[skill_option.selected]["value"]
	if coop:
		var missions := Missions.get_all()
		if not missions.is_empty():
			var m: Dictionary = missions[clampi(mission_option.selected, 0, missions.size() - 1)]
			Game.config["mission_id"] = m["id"]
			Game.config["map"] = m["map"]
	elif adventure:
		Game.config.erase("climate")        # fresh world -> re-resolve from the theme
		Game.continue_data = {}
		Game.config["mission_points"] = int(mission_points_spin.value)
		Game.config["map_size"] = map_size_option.selected
		Game.config["map"] = ADVENTURE_MAP   # terrain.gd reads map_size + seed
		Game.config["frag_limit"] = 0
		Game.config["seed"] = _parse_seed(seed_edit.text.strip_edges())
		Game.config["theme"] = theme_edit.text.strip_edges()
		# NPC count is fixed (scaled by the world); difficulty comes from the skill
		# selector (bot_skill is already set from skill_option above).
		Game.config["bot_count"] = 12
	else:
		Game.config["map"] = MAPS[map_option.selected]["path"]
		Game.config["frag_limit"] = int(frag_spin.value)

## Resolve the seed field: blank = random, a plain integer = itself, else hashed.
func _parse_seed(txt: String) -> int:
	if txt == "":
		return randi()
	if txt.is_valid_int():
		return int(txt)
	return hash(txt)

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
	if not Game.is_adventure():
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
	character_panel.visible = false
	create_panel.visible = false
	_update_char_label()

func _show_lobby() -> void:
	setup_panel.visible = false
	options_panel.visible = false
	character_panel.visible = false
	create_panel.visible = false
	lobby_panel.visible = true
	start_button.visible = Net.is_host()
	_refresh_lobby()

# ---------------------------------------------------------------- characters

func _update_char_label() -> void:
	char_label.text = String(Characters.current.get("name", "(none)")) if Characters.has_current() else "(none)"
	# Continue is only offered when the chosen character has a saved adventure.
	%ContinueBtn.visible = Characters.has_current() and not (Characters.current.get("adventure", {}) as Dictionary).is_empty()

## Resume the chosen character's saved adventure: rebuild the same world (seed +
## climate) solo and restore the dynamic state once it's populated.
func _on_continue() -> void:
	var snap: Dictionary = Characters.current.get("adventure", {})
	if snap.is_empty():
		return
	Game.player_name = String(Characters.current.get("name", "Player"))
	Game.config["mode"] = Game.Mode.ADVENTURE
	Game.config["map"] = ADVENTURE_MAP
	Game.config["seed"] = int(snap.get("seed", 0))
	Game.config["map_size"] = int(snap.get("map_size", 2))
	Game.config["mission_points"] = int(snap.get("mission_points", 10))
	Game.config["theme"] = String(snap.get("theme", ""))
	Game.config["bot_skill"] = float(snap.get("bot_skill", 1.0))
	Game.config["bot_count"] = 12
	Game.config["frag_limit"] = 0
	if String(snap.get("climate", "")) != "":
		Game.config["climate"] = String(snap["climate"])
	else:
		Game.config.erase("climate")
	Game.continue_data = snap
	if Net.host_game():
		Net.start_match()
	else:
		status_label.text = "Failed to start (port in use?)."

func _show_characters() -> void:
	setup_panel.visible = false
	create_panel.visible = false
	character_panel.visible = true
	_rebuild_char_list()

func _rebuild_char_list() -> void:
	for c in char_list.get_children():
		c.queue_free()
	if Characters.profiles.is_empty():
		var empty := Label.new()
		empty.text = "No characters yet — create one."
		empty.modulate = Color(1, 1, 1, 0.5)
		char_list.add_child(empty)
		return
	for p in Characters.profiles:
		var pd: Dictionary = p
		var b := Button.new()
		var st: Dictionary = pd.get("stats", {})
		var chosen := String(pd.get("id", "")) == String(Characters.current.get("id", ""))
		b.text = "%s%s  ·  %s  ·  %d adv, %d pts" % [
			"▶ " if chosen else "", String(pd.get("name", "?")),
			Characters.kit_name(String(pd.get("kit", "scout"))),
			int(st.get("adventures", 0)), int(st.get("points", 0))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var id := String(pd.get("id", ""))
		b.pressed.connect(func(): _choose_character(id))
		char_list.add_child(b)

func _choose_character(id: String) -> void:
	Characters.set_current(id)
	_update_char_label()
	_rebuild_char_list()

func _on_delete_character() -> void:
	if Characters.has_current():
		Characters.delete(String(Characters.current["id"]))
		_rebuild_char_list()
		_update_char_label()

func _show_create() -> void:
	%CreateName.text = ""
	%CreateBackstory.text = ""
	%CreateKit.selected = 0
	%CreateColor.color = Color(0.4, 0.6, 0.9)
	character_panel.visible = false
	create_panel.visible = true

func _on_create_confirm() -> void:
	var kit: String = Characters.KIT_IDS[clampi(%CreateKit.selected, 0, Characters.KIT_IDS.size() - 1)]
	Characters.create(%CreateName.text, %CreateColor.color, kit, %CreateBackstory.text)
	_show_characters()

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
	elif Game.is_battle_royale():
		summary += " — last one standing"
	elif Game.is_adventure():
		summary += " — %d mission points" % int(Game.config.get("mission_points", 10))
	else:
		summary += " — frag limit %d" % int(Game.config["frag_limit"])
	summary += "\nBots: %d (%s)" % [int(Game.config["bot_count"]), _skill_name(Game.config["bot_skill"])]
	lobby_summary.text = summary

func _skill_name(v: float) -> String:
	for s in SKILLS:
		if abs(s["value"] - v) < 0.01:
			return s["name"]
	return "Custom"
