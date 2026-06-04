extends CanvasLayer
## In-match HUD: health, ammo, weapon, objective banner, scoreboard, death/result
## and a lightweight pause overlay. Binds to the local player once it is spawned.

@onready var health_bar: ProgressBar = %HealthBar
@onready var health_label: Label = %HealthLabel
@onready var ammo_label: Label = %AmmoLabel
@onready var weapon_label: Label = %WeaponLabel
@onready var objective_label: Label = %ObjectiveLabel
@onready var death_label: Label = %DeathLabel
@onready var scoreboard: Panel = %Scoreboard
@onready var score_rows: VBoxContainer = %ScoreRows
@onready var result_panel: Panel = %ResultPanel
@onready var result_label: Label = %ResultLabel
@onready var pause_panel: Panel = %PausePanel
@onready var crosshair: Control = $Crosshair
@onready var damage_flash: ColorRect = %DamageFlash
@onready var grenade_label: Label = %GrenadeLabel
@onready var damage_direction: Control = $DamageDirection
@onready var kill_feed: VBoxContainer = %KillFeed

var _player: Node = null
var _last_health: float = -1.0
var _flash_tween: Tween = null

func _ready() -> void:
	scoreboard.visible = false
	result_panel.visible = false
	pause_panel.visible = false
	death_label.visible = false
	Game.score_changed.connect(_refresh_scoreboard)
	%ResumeButton.pressed.connect(_resume)
	%LeaveButton.pressed.connect(_leave)
	%VersionLabel.text = "v" + str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	set_process(true)

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_try_bind()
	elif death_label.visible != _player.dead and pause_panel.visible == false:
		death_label.visible = _player.dead

func _try_bind() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if p.is_multiplayer_authority():
			_player = p
			p.health_changed.connect(_on_health)
			p.ammo_changed.connect(_on_ammo)
			p.weapon_changed.connect(_on_weapon)
			p.dealt_damage.connect(_on_dealt_damage)
			p.grenades_changed.connect(_on_grenades)
			p.damaged_from.connect(_on_damaged_from)
			_on_health(p.sync_health, p.MAX_HEALTH)
			_on_grenades(p.grenades)
			break

func _on_damaged_from(angle: float) -> void:
	if damage_direction and damage_direction.has_method("show_from"):
		damage_direction.show_from(angle)

## Add a "killer ▸ victim" line that fades out after a few seconds.
func add_kill_feed(killer: String, victim: String, suicide: bool) -> void:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if suicide:
		l.text = "%s ☠" % victim
	else:
		l.text = "%s  ▸  %s" % [killer, victim]
	l.add_theme_color_override("font_color", Color(1, 0.85, 0.6))
	kill_feed.add_child(l)
	while kill_feed.get_child_count() > 5:
		kill_feed.get_child(0).free()
	var tw := l.create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)

func _on_grenades(count: int) -> void:
	grenade_label.text = "Grenades: %d" % count

func _on_dealt_damage(_amount: float) -> void:
	if crosshair and crosshair.has_method("hit"):
		crosshair.hit()

func _on_health(cur: float, maxhp: float) -> void:
	health_bar.max_value = maxhp
	health_bar.value = cur
	health_label.text = "%d" % int(cur)
	# Flash red when health drops (i.e. the player took damage).
	if _last_health >= 0.0 and cur < _last_health:
		_flash_damage(_last_health - cur, cur / maxhp)
	_last_health = cur

func _flash_damage(amount: float, health_frac: float) -> void:
	# Stronger flash for bigger hits and when low on health.
	var intensity := clampf(0.25 + amount / 100.0 * 0.5 + (1.0 - health_frac) * 0.25, 0.2, 0.75)
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	damage_flash.color.a = intensity
	_flash_tween = create_tween()
	_flash_tween.tween_property(damage_flash, "color:a", 0.0, 0.5).set_ease(Tween.EASE_OUT)

func _on_ammo(mag: int, reserve: int) -> void:
	ammo_label.text = "%d / %d" % [mag, reserve]

func _on_weapon(wname: String) -> void:
	weapon_label.text = wname

func set_objective(t: String) -> void:
	objective_label.text = t
	objective_label.visible = t != ""

# ---------------------------------------------------------------- scoreboard

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("scoreboard"):
		scoreboard.visible = true
		_refresh_scoreboard()
	elif event.is_action_released("scoreboard"):
		scoreboard.visible = false
	if event.is_action_pressed("pause"):
		_toggle_pause()

func _refresh_scoreboard() -> void:
	if not scoreboard.visible and not result_panel.visible:
		return
	for c in score_rows.get_children():
		c.queue_free()
	var header := _make_row("Player", "K", "D", true)
	score_rows.add_child(header)
	for row in Game.sorted_scoreboard():
		var label: String = row["name"]
		if row.get("is_bot", false):
			label = "🤖 " + label
		score_rows.add_child(_make_row(label, str(row["kills"]), str(row["deaths"]), false))

func _make_row(a: String, b: String, c: String, header: bool) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l1 := Label.new()
	l1.text = a
	l1.custom_minimum_size.x = 240
	var l2 := Label.new()
	l2.text = b
	l2.custom_minimum_size.x = 50
	var l3 := Label.new()
	l3.text = c
	l3.custom_minimum_size.x = 50
	if header:
		for l in [l1, l2, l3]:
			l.add_theme_color_override("font_color", Color(1, 0.8, 0.4))
	h.add_child(l1)
	h.add_child(l2)
	h.add_child(l3)
	return h

# ---------------------------------------------------------------- result / pause

func show_result(result: Dictionary) -> void:
	result_panel.visible = true
	scoreboard.visible = false
	var txt := "Match Over"
	match result.get("reason", ""):
		"mission_complete":
			txt = "MISSION COMPLETE\n%s" % result.get("mission", "")
		"frag_limit":
			var wid: int = int(result.get("winner", 0))
			var wname: String = Net.get_player_name(wid) if wid > 0 else String(Game.scores.get(wid, {}).get("name", "Bot"))
			txt = "%s wins!" % wname
		"time":
			txt = "Time!"
	result_label.text = txt + "\n\nReturning to menu…"
	_refresh_scoreboard()

func _toggle_pause() -> void:
	if result_panel.visible:
		return
	pause_panel.visible = not pause_panel.visible
	if pause_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _resume() -> void:
	pause_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _leave() -> void:
	Net.disconnect_net()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
