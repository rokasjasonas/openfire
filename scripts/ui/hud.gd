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
@onready var skills_list: VBoxContainer = %SkillsList
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
@onready var npc_scroll: ScrollContainer = %NpcScroll
@onready var quest_tracker: Label = %QuestTracker
@onready var generating_panel: Panel = %GeneratingPanel
@onready var trade_panel: Panel = %TradePanel
@onready var sell_list: VBoxContainer = %SellList
@onready var buy_list: VBoxContainer = %BuyList
@onready var coins_label: Label = %CoinsLabel
var _offer_quest_id: int = -1
var _npc_info: Dictionary = {}   # the NPC currently in the talk dialog
var _ask_pending: bool = false

# Quartermaster stock: item ids (ItemDB) and weapon ids, bought at full value.
const TRADE_ITEMS := ["medkit", "food", "water", "ammo", "grenade", "grenade_smoke", "grenade_flash",
	"grenade_incendiary", "grenade_impact", "grenade_shock", "grenade_void",
	"flashlight", "binoculars", "nvg", "scanner",
	"helmet", "vest", "leg_armor", "backpack_small"]
const TRADE_WEAPONS := ["pistol", "smg", "shotgun", "rifle"]

var _player: Node = null
var _last_health: float = -1.0
var _flash_tween: Tween = null
var _spawn_msec: int = 0   # for "time survived" in the Stats tab
const ADVENTURE_BRIEFING_SECS := 12   # how long the intro banner stays before fading

const RESULT_COUNTDOWN := 3.0
var _result_base_text: String = ""
var _result_left: float = 0.0

var _postfx: ColorRect = null
var _lowhp: ColorRect = null
var _lowhp_amt: float = 0.0
var _flashbang: ColorRect = null
var _nvg: ColorRect = null
var _gadget_label: Label = null

func _ready() -> void:
	add_to_group("hud")
	_setup_postfx()
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
	tabs.tab_changed.connect(func(_i): _refresh_stats(); _refresh_skills())
	npc_dialog.visible = false
	npc_prompt.text = ""
	quest_tracker.text = ""
	quest_tracker.visible = false
	generating_panel.visible = false
	%NpcClose.pressed.connect(_close_npc_dialog)
	%NpcAccept.pressed.connect(_on_accept_quest)
	trade_panel.visible = false
	%WorldMap.visible = false
	%NpcTrade.pressed.connect(_open_trade)
	%TradeClose.pressed.connect(_close_trade)
	%NpcAskBtn.pressed.connect(_on_npc_ask)
	%NpcAsk.text_submitted.connect(func(_t): _on_npc_ask())
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
	_update_gadget_label()
	# Animate the low-health blood vignette with a heartbeat pulse.
	if _lowhp != null and _lowhp.material is ShaderMaterial:
		var cur: float = float(_lowhp.material.get_shader_parameter("intensity"))
		_lowhp.material.set_shader_parameter("intensity", lerpf(cur, _lowhp_amt, clampf(6.0 * delta, 0.0, 1.0)))
		_lowhp.material.set_shader_parameter("pulse", 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006))
	# Adventure shows a loading overlay until the world is generated and you spawn in.
	var loading := Game.is_adventure() and Game.match_active and (_player == null or not is_instance_valid(_player))
	if generating_panel.visible != loading:
		generating_panel.visible = loading
	# Adventure: the story briefing is an intro — fade it out a while after you spawn so
	# the play screen stays clean (the quest tracker carries the live objectives).
	if Game.is_adventure() and objective_label.visible and _spawn_msec > 0 \
			and Time.get_ticks_msec() - _spawn_msec > ADVENTURE_BRIEFING_SECS * 1000:
		objective_label.visible = false
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
	if Game.is_adventure() and pk != null and is_instance_valid(pk) and not busy:
		npc_prompt.text = "[E] Pick up %s" % pk.label()
		return
	var n = _player.near_npc
	if Game.is_adventure() and n != null and is_instance_valid(n) and not busy:
		npc_prompt.text = "%s — %s (%s)    [E] Talk" % [String(n.display_name), String(n.role), String(n.faction)]
	else:
		npc_prompt.text = ""

func _on_talk(info: Dictionary) -> void:
	_npc_info = info
	%NpcTrade.visible = bool(info.get("can_trade", false))
	%NpcAsk.text = ""
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
	_scroll_dialogue_top()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_accept_quest() -> void:
	if _offer_quest_id >= 0:
		var w := get_tree().get_first_node_in_group("world")
		if w:
			w.accept_quest.rpc_id(1, _offer_quest_id)
	_offer_quest_id = -1
	_close_npc_dialog()

func _close_npc_dialog() -> void:
	%NpcAsk.release_focus()
	npc_dialog.visible = false
	if not pause_panel.visible and not inventory_panel.visible and not result_panel.visible \
			and not trade_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ---------------------------------------------------------------- live NPC dialogue

## Free-text question to the NPC, answered in-persona by the on-device LLM.
func _on_npc_ask() -> void:
	var q: String = %NpcAsk.text.strip_edges()
	if q == "" or _ask_pending:
		return
	%NpcAsk.text = ""
	var who := String(_npc_info.get("name", "Stranger"))
	npc_body.text += "\n\nYou: %s" % q
	_scroll_dialogue_bottom()
	var sys := ("You are %s, a %s of the %s faction. Persona: %s. World: %s\n"
		+ "Stay in character. Reply with 1-2 short spoken sentences only — no narration, no quotes.") % [
		who, String(_npc_info.get("role", "villager")), String(_npc_info.get("faction", "")),
		String(_npc_info.get("persona", "wary survivor")), String(Game.story.get("briefing", ""))]
	if LLM.embedded_ready() and LLM.chat(sys, q):
		_ask_pending = true
		%NpcAskBtn.disabled = true
		npc_body.text += "\n%s: …" % who
		LLM.chat_done.connect(_on_npc_answer, CONNECT_ONE_SHOT)
	else:
		npc_body.text += "\n%s: (just shrugs)" % who

func _on_npc_answer(text: String) -> void:
	_ask_pending = false
	%NpcAskBtn.disabled = false
	var who := String(_npc_info.get("name", "Stranger"))
	var reply := text.strip_edges()
	if reply == "":
		reply = "(says nothing)"
	# Replace the "…" placeholder line with the actual answer.
	var i := npc_body.text.rfind("\n%s: …" % who)
	if i >= 0:
		npc_body.text = npc_body.text.substr(0, i)
	npc_body.text += "\n%s: %s" % [who, reply]
	_scroll_dialogue_bottom()

## Keep the latest dialogue line in view (deferred a frame so the label has resized).
func _scroll_dialogue_bottom() -> void:
	await get_tree().process_frame
	if is_instance_valid(npc_scroll):
		npc_scroll.scroll_vertical = int(npc_scroll.get_v_scroll_bar().max_value)

func _scroll_dialogue_top() -> void:
	if is_instance_valid(npc_scroll):
		npc_scroll.scroll_vertical = 0

# ---------------------------------------------------------------- trading

func _open_trade() -> void:
	npc_dialog.visible = false
	trade_panel.visible = true
	%TradeTitle.text = "TRADE — %s" % String(_npc_info.get("name", "Quartermaster"))
	_refresh_trade()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close_trade() -> void:
	trade_panel.visible = false
	if not pause_panel.visible and not inventory_panel.visible and not result_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _refresh_trade() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	coins_label.text = "Coins: %d" % int(_player.coins)
	for c in sell_list.get_children():
		c.queue_free()
	for c in buy_list.get_children():
		c.queue_free()
	# Sell column: everything in the backpack, at half value.
	if _player.inventory.is_empty():
		var empty := Label.new()
		empty.text = "(backpack is empty)"
		empty.modulate = Color(1, 1, 1, 0.5)
		sell_list.add_child(empty)
	for i in _player.inventory.size():
		var it: Dictionary = _player.inventory[i]
		var b := Button.new()
		b.text = "%s   +%d c" % [String(it.get("name", "?")), ItemDB.sell_value(it)]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx: int = i
		b.pressed.connect(func(): _sell_item(idx))
		sell_list.add_child(b)
	# Buy column: fixed Quartermaster stock at full value.
	for id in TRADE_ITEMS:
		_add_buy_row(ItemDB.make(String(id)))
	for wid in TRADE_WEAPONS:
		_add_buy_row(ItemDB.make_weapon(String(wid)))

func _add_buy_row(item: Dictionary) -> void:
	if item.is_empty():
		return
	var cost := ItemDB.value_of(item)
	var b := Button.new()
	b.text = "%s   -%d c" % [String(item.get("name", "?")), cost]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.disabled = _player != null and int(_player.coins) < cost
	b.pressed.connect(func(): _buy_item(item, cost))
	buy_list.add_child(b)

func _sell_item(index: int) -> void:
	if _player == null or index < 0 or index >= _player.inventory.size():
		return
	var it: Dictionary = _player.inventory[index]
	_player.coins += ItemDB.sell_value(it)
	_player.inventory.remove_at(index)
	_player.inventory_changed.emit()
	Audio.play_ui("res://assets/audio/ui_click.ogg", -6.0)
	_refresh_trade()

func _buy_item(item: Dictionary, cost: int) -> void:
	if _player == null or int(_player.coins) < cost:
		return
	if not _player.inv_add(item.duplicate(true)):
		%TradeTitle.text = "TRADE — no room in your backpack!"
		return
	_player.coins -= cost
	_player.inventory_changed.emit()
	Audio.play_ui("res://assets/audio/ui_click.ogg", -6.0)
	_refresh_trade()

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
			# Hunger/thirst bars are only shown in Adventure mode.
			var surv := Game.is_adventure()
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

## Cinematic vignette + film grain overlay, behind all other HUD elements. Vignette
## from Medium quality up; grain only at High. Off entirely on Low.
func _setup_postfx() -> void:
	_postfx = ColorRect.new()
	_postfx.name = "PostFX"
	_postfx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_postfx.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sh := load("res://shaders/postfx.gdshader")
	if sh == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var q: int = Settings.quality
	mat.set_shader_parameter("vignette", 0.45 if q >= 1 else 0.0)
	mat.set_shader_parameter("grain", 0.05 if q >= 2 else 0.0)
	_postfx.material = mat
	_postfx.visible = q >= 1
	add_child(_postfx)
	move_child(_postfx, 0)   # draw beneath the real HUD widgets
	# Red low-health blood vignette (all quality levels).
	_lowhp = ColorRect.new()
	_lowhp.name = "LowHealth"
	_lowhp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lowhp.set_anchors_preset(Control.PRESET_FULL_RECT)
	var lsh := load("res://shaders/lowhealth.gdshader")
	if lsh != null:
		var lmat := ShaderMaterial.new()
		lmat.shader = lsh
		lmat.set_shader_parameter("intensity", 0.0)
		_lowhp.material = lmat
		add_child(_lowhp)
		move_child(_lowhp, 1)

const GADGET_NAMES := {"flashlight": "Flashlight", "binoculars": "Binoculars", "nvg": "Night Vision", "scanner": "Scanner"}

## Show the equipped gadget + its Q state above the weapon label (Adventure only).
func _update_gadget_label() -> void:
	if _gadget_label == null:
		_gadget_label = Label.new()
		_gadget_label.name = "GadgetLabel"
		_gadget_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		_gadget_label.offset_left = -284
		_gadget_label.offset_top = -160
		_gadget_label.offset_right = -24
		_gadget_label.offset_bottom = -132
		_gadget_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_gadget_label.modulate = Color(0.5, 0.9, 1.0)
		add_child(_gadget_label)
	var g := ""
	if _player != null and is_instance_valid(_player) and _player.has_method("equipped_gadget"):
		g = _player.equipped_gadget()
	if g == "" or Game.is_battle_royale():
		_gadget_label.visible = false
		return
	_gadget_label.visible = true
	var state := ""
	if g == "scanner":
		state = "  [Q ping]"
	elif _player.get("_gadget_on"):
		state = "  [ON]"
	else:
		state = "  [Q]"
	_gadget_label.text = "%s%s" % [GADGET_NAMES.get(g, g), state]

## Night-vision: a green additive overlay that brightens dark scenes into a green wash.
func set_nightvision(on: bool) -> void:
	if _nvg == null:
		_nvg = ColorRect.new()
		_nvg.name = "NVG"
		_nvg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_nvg.color = Color(0.25, 1.0, 0.35, 0.0)
		_nvg.set_anchors_preset(Control.PRESET_FULL_RECT)
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_nvg.material = m
		add_child(_nvg)
		move_child(_nvg, 0)
	_nvg.color.a = 0.28 if on else 0.0

## Flashbang white-out: a full-screen white flash that fades over a couple seconds.
func flashbang(intensity: float) -> void:
	if _flashbang == null:
		_flashbang = ColorRect.new()
		_flashbang.name = "Flashbang"
		_flashbang.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_flashbang.color = Color(1, 1, 1, 0)
		_flashbang.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(_flashbang)
	_flashbang.color = Color(1, 1, 1, clampf(intensity, 0.0, 1.0))
	var tw := create_tween()
	tw.tween_property(_flashbang, "color:a", 0.0, 1.2 + intensity)

func _on_grenades(count: int) -> void:
	var txt := "Grenades: %d" % count
	# Adventure: you can only throw one that's equipped in the Extra slot. If you're
	# carrying some but none is equipped, hint that they need equipping.
	if Game.is_adventure() and count > 0 and _player != null and is_instance_valid(_player) \
			and not _player._grenade_equipped():
		txt += "  (equip to throw)"
	grenade_label.text = txt

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

# ---------------------------------------------------------------- adventure backpack

func _is_inventory_key(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
		and (event as InputEventKey).keycode == Settings.inventory_keycode

func _toggle_inventory() -> void:
	if result_panel.visible or pause_panel.visible:
		return
	inventory_panel.visible = not inventory_panel.visible
	if inventory_panel.visible:
		tabs.current_tab = 0   # always open on the Inventory tab, not the last-used one
		_refresh_inventory()
		_refresh_stats()
		_refresh_skills()
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

# ---------------------------------------------------------------- skills tab

## Build the perk shop: 1 perk point per 3 lifetime quest points, one-time buys.
func _refresh_skills() -> void:
	if skills_list == null:
		return
	for c in skills_list.get_children():
		c.queue_free()
	if not Characters.has_current():
		var l := Label.new()
		l.text = "Create a character to earn and spend perk points."
		l.modulate = Color(1, 1, 1, 0.6)
		skills_list.add_child(l)
		return
	var pts := Characters.perk_points(Characters.current)
	var head := Label.new()
	head.text = "Perk points: %d   (earn 1 per 3 quest points)" % pts
	head.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	skills_list.add_child(head)
	for id in Characters.PERK_IDS:
		var perk: Dictionary = Characters.PERKS[id]
		var row := HBoxContainer.new()
		var name_l := Label.new()
		name_l.text = String(perk["name"])
		name_l.custom_minimum_size.x = 130
		var desc_l := Label.new()
		desc_l.text = String(perk["desc"])
		desc_l.custom_minimum_size.x = 230
		desc_l.modulate = Color(1, 1, 1, 0.7)
		row.add_child(name_l)
		row.add_child(desc_l)
		if Characters.has_perk(id):
			var owned := Label.new()
			owned.text = "OWNED"
			owned.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
			row.add_child(owned)
		else:
			var buy := Button.new()
			buy.text = "Buy (1)"
			buy.disabled = pts <= 0
			var pid := String(id)
			buy.pressed.connect(func(): _buy_perk(pid))
			row.add_child(buy)
		skills_list.add_child(row)

func _buy_perk(id: String) -> void:
	if Characters.buy_perk(id) and _player != null and is_instance_valid(_player):
		Characters.apply_perks(_player)   # takes effect immediately
	_refresh_skills()

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
	# Blood vignette ramps up below 40% health.
	var frac := cur / maxf(1.0, maxhp)
	_lowhp_amt = clampf((0.4 - frac) / 0.4, 0.0, 1.0) if cur > 0.0 else 0.0

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
	# While a text field has focus (e.g. asking an NPC), let it have the keyboard —
	# don't fire game shortcuts like M (map) or Tab (backpack) into the typed message.
	# Escape still passes through so it can close the dialog.
	if event is InputEventKey:
		var focus := get_viewport().gui_get_focus_owner()
		if (focus is LineEdit or focus is TextEdit) and not event.is_action_pressed("pause"):
			return
	# Adventure: the configurable inventory key opens/closes the backpack (and, when
	# it is Tab, takes precedence over the scoreboard).
	if Game.is_adventure() and _is_inventory_key(event):
		_toggle_inventory()
		get_viewport().set_input_as_handled()
		return
	# Full-screen world map on M (Adventure only, view-only overlay).
	if Game.is_adventure() and event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_M:
		%WorldMap.visible = not %WorldMap.visible
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
		# Escape closes whatever overlay is open first; only opens the pause menu
		# when nothing else is up.
		if trade_panel.visible:
			_close_trade()
		elif npc_dialog.visible:
			_close_npc_dialog()
		elif %WorldMap.visible:
			%WorldMap.visible = false
		elif inventory_panel.visible:
			_toggle_inventory()
		else:
			_toggle_pause()
		get_viewport().set_input_as_handled()

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
		"adventure_win":
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
	# Adventure: persist the character AND the world snapshot so the run can resume.
	if Game.is_adventure() and Characters.has_current() and _player != null and is_instance_valid(_player):
		var w := get_tree().get_first_node_in_group("world")
		if w and w.has_method("save_adventure"):
			w.save_adventure(_player)
		else:
			Characters.capture_from_player(_player)
	Net.disconnect_net()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
