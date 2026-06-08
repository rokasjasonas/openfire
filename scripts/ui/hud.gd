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
@onready var event_log: VBoxContainer = %EventLog
@onready var celebration: Label = %Celebration
@onready var tabs: TabContainer = %Tabs
@onready var stats_list: VBoxContainer = %StatsList
@onready var team_score_label: Label = %TeamScoreLabel
@onready var lives_label: Label = %LivesLabel
@onready var vehicle_prompt: Label = %VehiclePrompt
@onready var car_health_bar: ProgressBar = %CarHealthBar
@onready var car_health_label: Label = %CarHealthLabel
@onready var hunger_bar: ProgressBar = %HungerBar
@onready var hunger_label: Label = %HungerLabel
@onready var thirst_bar: ProgressBar = %ThirstBar
@onready var thirst_label: Label = %ThirstLabel
@onready var oxygen_bar: ProgressBar = %OxygenBar
@onready var oxygen_label: Label = %OxygenLabel
@onready var inventory_panel: Panel = %InventoryPanel
@onready var backpack_grid: Control = %InvGrid
@onready var equip_panel: Control = %EquipPanel
@onready var inv_capacity: Label = %InvCapacity
@onready var npc_prompt: Label = %NpcPrompt
@onready var npc_dialog: Panel = %NpcDialog
@onready var npc_name: Label = %NpcName
@onready var npc_role: Label = %NpcRole
@onready var npc_body: Label = %NpcBody
@onready var quest_tracker: Label = %QuestTracker
@onready var generating_panel: Panel = %GeneratingPanel
var _offer_quest_id: int = -1

var _player: Node = null
var _last_health: float = -1.0
var _flash_tween: Tween = null
var _spawn_msec: int = 0   # for "time survived" in the Stats tab

const RESULT_COUNTDOWN := 3.0
var _result_base_text: String = ""
var _result_left: float = 0.0

func _ready() -> void:
	scoreboard.visible = false
	result_panel.visible = false
	pause_panel.visible = false
	death_label.visible = false
	Game.score_changed.connect(_refresh_scoreboard)
	Game.score_changed.connect(_refresh_team_score)
	Game.dom_changed.connect(_refresh_team_score)
	Game.lives_changed.connect(_on_lives)
	team_score_label.visible = false
	car_health_bar.visible = false
	car_health_label.visible = false
	hunger_bar.visible = false
	hunger_label.visible = false
	thirst_bar.visible = false
	thirst_label.visible = false
	oxygen_bar.visible = false
	oxygen_label.visible = false
	inventory_panel.visible = false
	celebration.visible = false
	tabs.tab_changed.connect(func(_i): _refresh_stats())
	npc_dialog.visible = false
	npc_prompt.text = ""
	quest_tracker.text = ""
	quest_tracker.visible = false
	generating_panel.visible = false
	%NpcClose.pressed.connect(_close_npc_dialog)
	%NpcAccept.pressed.connect(_on_accept_quest)
	_refresh_team_score()
	_on_lives(Game.coop_lives)
	%ResumeButton.pressed.connect(_resume)
	%LeaveButton.pressed.connect(_leave)
	%VersionLabel.text = "v" + str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	set_process(true)

func _process(delta: float) -> void:
	if result_panel.visible and _result_left > 0.0:
		_result_left = maxf(0.0, _result_left - delta)
		_update_result_label()
	# Survival shows a loading overlay until the world is generated and you spawn in.
	var loading := Game.is_survival() and Game.match_active and (_player == null or not is_instance_valid(_player))
	if generating_panel.visible != loading:
		generating_panel.visible = loading
	# Keep the Stats tab live (time survived / accuracy tick) while it's open.
	if inventory_panel.visible and tabs.get_current_tab_control() != null \
			and tabs.get_current_tab_control().name == "Stats":
		_refresh_stats()
	if _player == null or not is_instance_valid(_player):
		_try_bind()
	elif not pause_panel.visible:
		_update_status_label()
		_update_vehicle_prompt()
		_update_npc_prompt()
		_update_health_display()
		crosshair.visible = _player.driving == null or \
			(is_instance_valid(_player.driving) and _player.driving.is_in_group("aircraft"))

func _update_npc_prompt() -> void:
	var busy: bool = _player.driving != null or npc_dialog.visible
	var pk = _player.near_pickup
	if Game.is_survival() and pk != null and is_instance_valid(pk) and not busy:
		npc_prompt.text = "[E] Pick up %s" % pk.label()
		return
	var n = _player.near_npc
	if Game.is_survival() and n != null and is_instance_valid(n) and not busy:
		npc_prompt.text = "%s — %s (%s)    [E] Talk" % [String(n.display_name), String(n.role), String(n.faction)]
	else:
		npc_prompt.text = ""

func _on_talk(info: Dictionary) -> void:
	npc_name.text = String(info.get("name", "?"))
	var role_line := "%s — %s" % [String(info.get("role", "")), String(info.get("faction", ""))]
	if String(info.get("persona", "")) != "":
		role_line += "  ·  " + String(info["persona"])
	npc_role.text = role_line
	var body := String(info.get("greeting", ""))
	if info.has("lore"):
		body += "\n\n" + String(info["lore"])
	if info.has("quest_id"):
		body += "\n\nTASK: %s\n%s" % [String(info.get("quest_title", "")), String(info.get("quest_desc", ""))]
		_offer_quest_id = int(info["quest_id"])
		%NpcAccept.visible = true
	else:
		_offer_quest_id = -1
		%NpcAccept.visible = false
	npc_body.text = body
	npc_dialog.visible = true
	npc_prompt.text = ""
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_accept_quest() -> void:
	if _offer_quest_id >= 0:
		var w := get_tree().get_first_node_in_group("world")
		if w:
			w.accept_quest.rpc_id(1, _offer_quest_id)
	_offer_quest_id = -1
	_close_npc_dialog()

func _close_npc_dialog() -> void:
	npc_dialog.visible = false
	if not pause_panel.visible and not inventory_panel.visible and not result_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func set_quest_tracker(t: String) -> void:
	quest_tracker.text = t

func set_loading_text(t: String) -> void:
	var lbl := generating_panel.get_node_or_null("GenLabel")
	if lbl:
		lbl.text = t

func _update_health_display() -> void:
	# Player health is always shown on the main bar (driven by _on_health). The car
	# health is shown as a separate extra bar only while seated in a vehicle.
	var inside := _player.driving != null and is_instance_valid(_player.driving)
	car_health_bar.visible = inside
	car_health_label.visible = inside
	if inside:
		var car = _player.driving
		car_health_bar.max_value = car.MAX_HEALTH
		car_health_bar.value = car.health
		var icon: String = "🚁" if car.is_in_group("aircraft") else "🚗"
		car_health_label.text = "%s %d" % [icon, int(car.health)]

func _update_vehicle_prompt() -> void:
	if _player.driving != null and is_instance_valid(_player.driving):
		if _player.driving.has_method("is_overturned") and _player.driving.is_overturned():
			vehicle_prompt.text = "[R] Flip car    [E] Exit"
		else:
			vehicle_prompt.text = "[E] Exit    [Space] Handbrake    [R] Flip"
	elif _player.near_vehicle:
		vehicle_prompt.text = "[E] Enter vehicle"
	else:
		vehicle_prompt.text = ""

func _on_lives(n: int) -> void:
	lives_label.visible = Game.is_coop()
	lives_label.text = "Lives: %d" % n

func _update_status_label() -> void:
	if _player.fully_dead:
		death_label.text = "You are out — spectating"
		death_label.visible = true
	elif _player.downed:
		if _player._revive_prog > 0.05:
			death_label.text = "Being revived…  %d%%" % int(_player._revive_prog / _player.REVIVE_TIME * 100.0)
		else:
			death_label.text = "DOWNED — wait for a teammate"
		death_label.visible = true
	elif _player.dead:
		death_label.text = "You are out — spectating" if Game.is_battle_royale() else "You died — respawning…"
		death_label.visible = true
	else:
		death_label.visible = false

func _try_bind() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		if p.is_multiplayer_authority():
			_player = p
			_spawn_msec = Time.get_ticks_msec()
			p.health_changed.connect(_on_health)
			p.ammo_changed.connect(_on_ammo)
			p.weapon_changed.connect(_on_weapon)
			p.dealt_damage.connect(_on_dealt_damage)
			p.grenades_changed.connect(_on_grenades)
			p.damaged_from.connect(_on_damaged_from)
			p.hunger_changed.connect(_on_hunger)
			p.thirst_changed.connect(_on_thirst)
			p.oxygen_changed.connect(_on_oxygen)
			p.inventory_changed.connect(_refresh_inventory)
			p.equipment_changed.connect(_refresh_equip)
			p.talk_to.connect(_on_talk)
			backpack_grid.set_player(p)
			equip_panel.set_player(p)
			backpack_grid.equip_panel = equip_panel
			_on_health(p.sync_health, p.MAX_HEALTH)
			_on_grenades(p.grenades)
			# Hunger/thirst bars are only shown in Survival mode.
			var surv := Game.is_survival()
			hunger_bar.visible = surv
			hunger_label.visible = surv
			thirst_bar.visible = surv
			thirst_label.visible = surv
			if surv:
				_on_hunger(p.hunger, p.MAX_NEED)
				_on_thirst(p.thirst, p.MAX_NEED)
			quest_tracker.visible = surv
			break

func _refresh_team_score() -> void:
	if Game.is_team_deathmatch():
		team_score_label.visible = true
		team_score_label.text = "%s  %d   —   %d  %s" % [
			Game.team_name(0), Game.team_score(0), Game.team_score(1), Game.team_name(1)]
	elif Game.is_domination():
		team_score_label.visible = true
		team_score_label.text = "%s  %d   —   %d  %s     %s" % [
			Game.team_name(0), int(Game.dom_score[0]), int(Game.dom_score[1]), Game.team_name(1), _cp_status()]
	else:
		team_score_label.visible = false

func _cp_status() -> String:
	var cps := get_tree().get_nodes_in_group("control_point")
	cps.sort_custom(func(a, b): return a.point_id < b.point_id)
	var parts: Array = []
	for cp in cps:
		var who := "-"
		if cp.owner_team == 0:
			who = Game.team_name(0)[0]
		elif cp.owner_team == 1:
			who = Game.team_name(1)[0]
		parts.append("%s:%s" % [cp.point_id, who])
	return " ".join(parts)

func _on_damaged_from(angle: float) -> void:
	if damage_direction and damage_direction.has_method("show_from"):
		damage_direction.show_from(angle)

## Add a "killer ▸ victim" line (names coloured by team) to the events log.
func add_kill_feed(killer: String, victim: String, suicide: bool, killer_team: int = -1, victim_team: int = -1) -> void:
	var kc := _feed_color(killer_team)
	var vc := _feed_color(victim_team)
	if suicide:
		_add_event_line("[color=%s]%s[/color] ☠" % [vc, victim])
	else:
		_add_event_line("[color=%s]%s[/color]  ▸  [color=%s]%s[/color]" % [kc, killer, vc, victim])

## Add a non-kill event line (quest accepted/completed, etc.) to the events log.
func add_event(text: String) -> void:
	var col := "#7fe0a0" if text.begins_with("✓") else "#d8c070"
	_add_event_line("[color=%s]%s[/color]" % [col, text])

## Shared: append a right-aligned bbcode line to the events log; oldest fade & drop.
func _add_event_line(bbcode: String) -> void:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.custom_minimum_size = Vector2(0, 22)
	rt.text = "[right]%s[/right]" % bbcode
	event_log.add_child(rt)
	while event_log.get_child_count() > 6:
		event_log.get_child(0).free()
	var tw := rt.create_tween()
	tw.tween_interval(5.0)
	tw.tween_property(rt, "modulate:a", 0.0, 1.0)
	tw.tween_callback(rt.queue_free)

## A little top-centre celebration banner when a quest/mission is completed.
func celebrate(title: String) -> void:
	celebration.text = "★  MISSION COMPLETE  ★\n%s" % title
	celebration.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	celebration.visible = true
	celebration.modulate = Color(1, 1, 1, 0)
	celebration.pivot_offset = celebration.size * 0.5
	celebration.scale = Vector2(0.6, 0.6)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(celebration, "modulate:a", 1.0, 0.25)
	tw.tween_property(celebration, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(1.8)
	tw.chain().tween_property(celebration, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(func(): celebration.visible = false)

func _feed_color(team: int) -> String:
	if Game.is_team_mode() and team >= 0:
		return "#" + Game.team_color(team).to_html(false)
	return "#e0c080"  # neutral gold for free-for-all

func _on_grenades(count: int) -> void:
	grenade_label.text = "Grenades: %d" % count

func _on_hunger(value: float, maximum: float) -> void:
	hunger_bar.max_value = maximum
	hunger_bar.value = value
	hunger_label.text = "Hunger %d" % int(value)

func _on_thirst(value: float, maximum: float) -> void:
	thirst_bar.max_value = maximum
	thirst_bar.value = value
	thirst_label.text = "Thirst %d" % int(value)

## Oxygen bar appears only while you're losing/regaining air (hidden when full).
func _on_oxygen(value: float, maximum: float) -> void:
	oxygen_bar.max_value = maximum
	oxygen_bar.value = value
	oxygen_label.text = "Oxygen %d" % int(value)
	var show_ox := value < maximum - 0.5
	oxygen_bar.visible = show_ox
	oxygen_label.visible = show_ox

# ---------------------------------------------------------------- survival backpack

func _is_inventory_key(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and (event as InputEventKey).keycode == Settings.inventory_keycode

func _toggle_inventory() -> void:
	if result_panel.visible or pause_panel.visible:
		return
	inventory_panel.visible = not inventory_panel.visible
	if inventory_panel.visible:
		_refresh_inventory()
		_refresh_stats()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _refresh_inventory() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	backpack_grid.set_player(_player)
	backpack_grid.equip_panel = equip_panel
	inv_capacity.text = "Space  %d / %d" % [_player.inv_used(), _player.inv_cell_count()]

func _refresh_equip() -> void:
	equip_panel.refresh()

# ---------------------------------------------------------------- stats tab

func _refresh_stats() -> void:
	if stats_list == null:
		return
	for c in stats_list.get_children():
		c.queue_free()
	if _player == null or not is_instance_valid(_player):
		_stats_header("No data yet")
		return

	var sc: Dictionary = Game.scores.get(_player.combatant_id, {})
	var kills := int(sc.get("kills", 0))
	var deaths := int(sc.get("deaths", 0))
	var shots := int(_player.shots_fired)
	_stats_header("Combat")
	_stat_row("Kills", str(kills))
	_stat_row("Deaths", str(deaths))
	_stat_row("K / D", "%.2f" % (float(kills) / float(maxi(1, deaths))))
	_stat_row("Bullets fired", str(shots))
	_stat_row("Accuracy", ("%d%%" % int(round(100.0 * float(_player.shots_hit) / float(shots)))) if shots > 0 else "—")

	var qm = get_tree().get_first_node_in_group("quest_manager")
	if qm != null:
		var done := 0
		for q in qm.quests:
			if q.get("state", "") == "complete":
				done += 1
		_stats_header("Mission")
		_stat_row("Mission points", "%d / %d" % [int(qm.points), int(qm.target_points)])
		_stat_row("Quests completed", str(done))

	_stats_header("Run")
	_stat_row("Distance walked", "%d m" % int(_player.meters_walked))
	var secs := int((Time.get_ticks_msec() - _spawn_msec) / 1000)
	_stat_row("Time survived", "%d:%02d" % [secs / 60, secs % 60])

func _stats_header(t: String) -> void:
	var l := Label.new()
	l.text = t.to_upper()
	l.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	stats_list.add_child(l)

func _stat_row(label_text: String, value: String) -> void:
	var h := HBoxContainer.new()
	var a := Label.new()
	a.text = label_text
	a.custom_minimum_size.x = 240
	a.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	var b := Label.new()
	b.text = value
	h.add_child(a)
	h.add_child(b)
	stats_list.add_child(h)

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
	# Survival: the configurable inventory key opens/closes the backpack (and, when
	# it is Tab, takes precedence over the scoreboard).
	if Game.is_survival() and _is_inventory_key(event):
		_toggle_inventory()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("scoreboard"):
		scoreboard.visible = true
		_refresh_scoreboard()
		# Keep the mouse captured so you can still look/aim and fire while the
		# scoreboard overlay is up. The panel is mouse-transparent, so it never
		# steals input.
	elif event.is_action_released("scoreboard"):
		scoreboard.visible = false
	if event.is_action_pressed("pause"):
		_toggle_pause()

func _refresh_scoreboard() -> void:
	if not scoreboard.visible and not result_panel.visible:
		return
	for c in score_rows.get_children():
		c.queue_free()
	score_rows.add_child(_make_row("Player", "K", "D", true, Color(1, 0.8, 0.4)))
	var rows := Game.sorted_scoreboard()
	if Game.is_team_mode():
		# Group by team, with a coloured team header + total.
		var by_team := {}
		for r in rows:
			var t: int = r["team"]
			if not by_team.has(t):
				by_team[t] = []
			by_team[t].append(r)
		var order: Array = []
		for t in [Game.TEAM_PLAYERS, Game.TEAM_ENEMIES]:
			if by_team.has(t):
				order.append(t)
		for t in by_team:
			if not order.has(t):
				order.append(t)
		for t in order:
			var col: Color = Game.team_color(t)
			score_rows.add_child(_make_row("— %s (%d) —" % [_team_label(t), Game.team_score(t)], "", "", true, col))
			for r in by_team[t]:
				var label: String = ("🤖 " + r["name"]) if r.get("is_bot", false) else r["name"]
				score_rows.add_child(_make_row(label, str(r["kills"]), str(r["deaths"]), false, col.lerp(Color.WHITE, 0.35)))
	else:
		for r in rows:
			var label: String = ("🤖 " + r["name"]) if r.get("is_bot", false) else r["name"]
			score_rows.add_child(_make_row(label, str(r["kills"]), str(r["deaths"]), false, Color.WHITE))

func _team_label(t: int) -> String:
	if Game.is_team_deathmatch():
		return Game.team_name(t)
	return "Squad" if t == Game.TEAM_PLAYERS else "Hostiles"

func _make_row(a: String, b: String, c: String, header: bool, col: Color = Color.WHITE) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l1 := Label.new()
	l1.text = a
	l1.custom_minimum_size.x = 240
	var l2 := Label.new()
	l2.text = b
	l2.custom_minimum_size.x = 50
	var l3 := Label.new()
	l3.text = c
	l3.custom_minimum_size.x = 50
	for l in [l1, l2, l3]:
		l.add_theme_color_override("font_color", col)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		"domination":
			txt = "%s team wins Domination!" % Game.team_name(int(result.get("winner_team", 0)))
		"frag_limit":
			if result.has("winner_team"):
				txt = "%s team wins!" % Game.team_name(int(result["winner_team"]))
			else:
				var wid: int = int(result.get("winner", 0))
				var wname: String = Net.get_player_name(wid) if wid > 0 else String(Game.scores.get(wid, {}).get("name", "Bot"))
				txt = "%s wins!" % wname
		"survival_win":
			var outro := String(Game.story.get("outro", ""))
			if outro == "":
				outro = "Reached the goal with %d points." % int(result.get("points", 0))
			txt = "YOU SURVIVED\n%s" % outro
		"last_standing":
			var wid: int = int(result.get("winner", 0))
			if wid == 0:
				txt = "Nobody survived the storm…"
			else:
				var wname: String = Net.get_player_name(wid) if wid > 0 else String(Game.scores.get(wid, {}).get("name", "Bot"))
				txt = "%s wins the Battle Royale!" % wname
		"time":
			txt = "Time!"
	_result_base_text = txt
	_result_left = RESULT_COUNTDOWN
	_update_result_label()
	_refresh_scoreboard()

func _update_result_label() -> void:
	var secs := int(ceil(_result_left))
	if secs > 0:
		result_label.text = "%s\n\nReturning to menu in %d…" % [_result_base_text, secs]
	else:
		result_label.text = "%s\n\nReturning to menu…" % _result_base_text

func _toggle_pause() -> void:
	if result_panel.visible:
		return
	inventory_panel.visible = false  # don't overlap the pause menu
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
