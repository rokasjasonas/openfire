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
@onready var craft_list: VBoxContainer = %CraftList
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
const TRADE_ITEMS := ["medkit", "food", "water", "raw_meat", "ammo", "grenade", "grenade_smoke", "grenade_flash",
	"grenade_incendiary", "grenade_impact", "grenade_shock", "grenade_void",
	"flashlight", "binoculars", "nvg", "scanner", "torch", "jetpack", "shovel",
	"wood", "scrap", "helmet", "vest", "leg_armor", "backpack_small"]
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
var _nvg_mat: ShaderMaterial = null
var _gadget_label: Label = null

# Solo debug menu ([0]) — built lazily the first time it's opened.
var _debug_panel: Control = null
var _dbg_values: Dictionary = {}       # "health"/"thirst"/"hunger" -> value Label
var _dbg_noclip: CheckButton = null
var _dbg_item: OptionButton = null
var _dbg_item_ids: Array = []
var _dbg_ai_prompt: LineEdit = null
var _dbg_ai_status: Label = null
var _dbg_ai_3d: CheckButton = null

# Loading-screen 3D preview: a spinning random game model in the bottom-right; Space cycles.
# Rendered at high res in an offscreen SubViewport and downscaled into a TextureRect
# (supersampling) so it's crisp and anti-aliased.
var _load_preview: TextureRect = null
var _load_vp: SubViewport = null
var _load_pivot: Node3D = null
var _load_hint: Label = null
var _load_models: Array = []
var _load_idx: int = 0

## Night-vision image intensifier: read the rendered scene, amplify low light into a
## visible range, and tint it green (phosphor tube). Unlike a flat overlay this actually
## brightens dark areas so you can see in them. `amount` (0..1) fades the effect in/out.
const NVG_SHADER := "shader_type canvas_item;
render_mode blend_mix;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount = 0.0;
void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	// Gain curve: lift the darks hard, roll off the highlights so bright spots bloom.
	float g = pow(clamp(lum * 4.0 + 0.06, 0.0, 1.0), 0.45);
	vec3 nv = vec3(0.20, 1.0, 0.35) * g;
	// Subtle scanlines + vignette sell the tube look without hurting readability.
	nv *= 0.85 + 0.15 * sin(SCREEN_UV.y * 900.0);
	vec2 d = SCREEN_UV - vec2(0.5);
	nv *= 1.0 - dot(d, d) * 0.9;
	COLOR = vec4(mix(c, nv, amount), 1.0);
}"

func _ready() -> void:
	add_to_group("hud")
	_setup_postfx()
	_init_comfy_status()
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
	tabs.tab_changed.connect(func(_i): _refresh_stats(); _refresh_skills(); _refresh_crafting())
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
	%NpcHire.pressed.connect(_on_hire)
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
	_update_fps()
	if _debug_panel != null and _debug_panel.visible:
		_refresh_debug()   # keep the live stat readouts current while the menu is open
	# Animate the low-health blood vignette with a heartbeat pulse.
	if _lowhp != null and _lowhp.material is ShaderMaterial:
		var cur: float = float(_lowhp.material.get_shader_parameter("intensity"))
		_lowhp.material.set_shader_parameter("intensity", lerpf(cur, _lowhp_amt, clampf(6.0 * delta, 0.0, 1.0)))
		_lowhp.material.set_shader_parameter("pulse", 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006))
	# Adventure shows a loading overlay until the world is generated and you spawn in.
	var loading := Game.is_adventure() and Game.match_active and (_player == null or not is_instance_valid(_player))
	if generating_panel.visible != loading:
		generating_panel.visible = loading
		_show_gameplay_hud(not loading)   # hide the minimap/health/etc. while loading
		if loading:
			_show_loading_preview()
		elif _load_preview != null:
			_load_preview.visible = false
			if _load_hint != null:
				_load_hint.visible = false
			_load_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Spin the loading-screen model preview.
	if _load_preview != null and _load_preview.visible and _load_pivot != null:
		_load_pivot.rotation.y += delta * 1.1
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
	elif Game.is_adventure() and not busy and _player.has_method("near_campfire") and _player.near_campfire():
		npc_prompt.text = "[E] Cook / craft at the fire"
	else:
		npc_prompt.text = ""

func _on_talk(info: Dictionary) -> void:
	_npc_info = info
	%NpcTrade.visible = bool(info.get("can_trade", false))
	%NpcHire.visible = bool(info.get("can_hire", false))
	if %NpcHire.visible:
		%NpcHire.text = "Hire follower ($%d)" % int(info.get("hire_cost", 25))
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
	_npc_pending_intent = ""
	_npc_pending_action = ""
	if _npc_accept_btn != null:
		_npc_accept_btn.visible = false
	_scroll_dialogue_top()
	_show_npc_portrait(info)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# ---------------------------------------------------------------- AI NPC portrait

@onready var _npc_portrait: TextureRect = %NpcPortrait
var _npc_portrait_key: String = ""

## Show a ComfyUI-generated head-and-shoulders portrait of the NPC (cached per name+faction
## so it's instant on re-talk). The portrait sits in a header row beside the name so it never
## overlaps the dialog text. Silent no-op if ComfyUI isn't reachable.
func _show_npc_portrait(info: Dictionary) -> void:
	# "face_" prefix (vs the old "npc_") so earlier full-body portraits in the cache are bypassed.
	var key := "face_%s_%s" % [String(info.get("faction", "")), String(info.get("name", ""))]
	_npc_portrait_key = key
	var tex := ComfyUI.asset_texture(key)
	if tex != null:
		_npc_portrait.texture = tex
		_npc_portrait.visible = true
		return
	_npc_portrait.texture = null
	_npc_portrait.visible = false
	if not ComfyUI.asset_ready.is_connected(_on_npc_portrait_ready):
		ComfyUI.asset_ready.connect(_on_npc_portrait_ready)
	var theme := String(Game.config.get("theme", "")).strip_edges()
	# Force a tight head-only headshot — SD reads "character/portrait" as full body otherwise.
	var prompt := "extreme close-up headshot, only the face and head, front-facing face of a %s of the %s%s, centered face, plain background, no body, no torso" % [
		String(info.get("role", "wanderer")), String(info.get("faction", "wilds")),
		(", " + theme) if theme != "" else ""]
	ComfyUI.ensure_server()
	ComfyUI.bake(prompt, key, "image")

func _on_npc_portrait_ready(key: String, path: String) -> void:
	if key != _npc_portrait_key or _npc_portrait == null or not path.to_lower().ends_with(".png"):
		return
	var img := Image.new()
	if img.load(path) == OK:
		_npc_portrait.texture = ImageTexture.create_from_image(img)
		_npc_portrait.visible = npc_dialog.visible

func _on_accept_quest() -> void:
	if _offer_quest_id >= 0:
		var w := get_tree().get_first_node_in_group("world")
		if w:
			w.accept_quest.rpc_id(1, _offer_quest_id)
	_offer_quest_id = -1
	_close_npc_dialog()

func _on_hire() -> void:
	if _player != null and is_instance_valid(_player) and _player.has_method("hire_npc") and _player.hire_npc():
		add_event("◆ Hired a follower.")
		Audio.play_ui("res://assets/audio/ui_click.ogg", -4.0)
	_close_npc_dialog()

# ---------------------------------------------------------------- dynamic NPC actions
# No always-on command buttons. Actions surface from the conversation: when what you say
# to an NPC implies something they can do (heal/follow/wait/give/…), a single contextual
# "accept" button appears; taking it runs the action.

var _npc_accept_btn: Button = null
var _npc_pending_action: String = ""
var _npc_pending_intent: String = ""

## Detect an actionable intent in the player's free-text line to an NPC.
func _npc_intent(text: String) -> String:
	var t := text.to_lower()
	for pair in [
		["heal", ["heal", "patch", "wound", "hurt", "medic", "bandage", "fix me"]],
		["follow", ["follow", "join me", "come with", "fight with", "join us", "recruit"]],
		["give", ["supplies", "give me", "spare", "share", "food", "water", "ammo", "some gear"]],
		["wait", ["wait here", "stay here", "hold position", "hold up", "stay put"]],
		["regroup", ["regroup", "come back", "on me", "with me now", "form up"]],
		["goto", ["go there", "move out", "over there", "go to", "head there"]],
	]:
		for kw in pair[1]:
			if t.find(String(kw)) >= 0:
				return String(pair[0])
	return ""

## After the NPC replies, show/hide the contextual accept button based on the detected
## intent and whether the NPC would actually do it (stance/state, decided player-side).
func _update_npc_accept() -> void:
	if _npc_accept_btn == null:
		_npc_accept_btn = Button.new()
		_npc_accept_btn.name = "NpcActionAccept"
		_npc_accept_btn.visible = false
		_npc_accept_btn.pressed.connect(_on_npc_accept_action)
		var host: Node = %NpcHire.get_parent()
		host.add_child(_npc_accept_btn)
		host.move_child(_npc_accept_btn, %NpcHire.get_index())
	var label := ""
	if _npc_pending_intent != "" and _player != null and is_instance_valid(_player):
		label = String(_player.npc_can(_npc_pending_intent))
	if label != "":
		_npc_pending_action = _npc_pending_intent
		_npc_accept_btn.text = "✓ %s" % label
		_npc_accept_btn.visible = true
	else:
		_npc_pending_action = ""
		_npc_accept_btn.visible = false

func _on_npc_accept_action() -> void:
	if _player == null or not is_instance_valid(_player) or _npc_pending_action == "":
		return
	var pos := Vector3.INF
	if _npc_pending_action == "goto":
		var fwd: Vector3 = -_player.global_transform.basis.z
		fwd.y = 0.0
		pos = _player.global_position + fwd.normalized() * 12.0
	var msg := String(_player.npc_request(_npc_pending_action, pos))
	if msg != "":
		npc_body.text += "\n\n» " + msg
		_scroll_dialogue_bottom()
	Audio.play_ui("res://assets/audio/ui_click.ogg", -6.0)
	_npc_pending_action = ""
	_npc_pending_intent = ""
	_npc_accept_btn.visible = false

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
	_npc_pending_intent = _npc_intent(q)   # what the player is asking for, if anything
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
		_update_npc_accept()   # no LLM — still offer the action if the ask maps to one

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
	_update_npc_accept()   # offer an accept button if the ask maps to a doable action

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
	var v = _player.driving
	if v != null and is_instance_valid(v):
		# Prompts match each vehicle class's actual controls: aircraft fly (no flip /
		# handbrake), boats steer + brake on the water, only ground cars flip / handbrake.
		if v.is_in_group("aircraft"):
			vehicle_prompt.text = "[W/S] Throttle   [A/D] Turn   [Space/Ctrl] Up/Down   [LMB] Fire   [E] Exit"
		elif v.is_in_group("boat"):
			vehicle_prompt.text = "[W/S] Throttle   [A/D] Steer   [Space] Brake   [E] Exit"
		elif v.has_method("is_overturned") and v.is_overturned():
			vehicle_prompt.text = "[R] Flip car    [E] Exit"
		else:
			vehicle_prompt.text = "[W/S] Drive   [A/D] Steer   [Space] Handbrake   [R] Flip   [E] Exit"
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
	Audio.play_ui("res://assets/audio/quest_complete.wav", -5.0)
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
var _fps_label: Label = null
var _coins_label: Label = null

## Coin wallet readout (Adventure), top-left under the FPS counter.
func _update_coins() -> void:
	if _coins_label == null:
		_coins_label = Label.new()
		_coins_label.name = "CoinsLabel"
		_coins_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_coins_label.position = Vector2(8, 26)
		_coins_label.modulate = Color(1.0, 0.85, 0.3)
		add_child(_coins_label)
	var show := Game.is_adventure() and _player != null and is_instance_valid(_player)
	_coins_label.visible = show
	if show:
		_coins_label.text = "⛁ %d" % int(_player.coins)

## Small always-on FPS readout in the top-left.
## Bottom-centre banner showing ComfyUI first-run setup progress (bundle download, model
## downloads, "starting…"), so the several-minute silent first run is visible. Hidden when idle.
var _comfy_status_label: Label = null

func _init_comfy_status() -> void:
	_comfy_status_label = Label.new()
	_comfy_status_label.name = "ComfyStatus"
	_comfy_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_comfy_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_comfy_status_label.anchor_left = 0.0
	_comfy_status_label.anchor_right = 1.0
	_comfy_status_label.anchor_top = 1.0
	_comfy_status_label.anchor_bottom = 1.0
	_comfy_status_label.offset_top = -52.0
	_comfy_status_label.offset_bottom = -30.0
	_comfy_status_label.modulate = Color(1, 1, 1, 0.85)
	_comfy_status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_comfy_status_label.add_theme_constant_override("outline_size", 4)
	_comfy_status_label.visible = false
	add_child(_comfy_status_label)
	ComfyUI.setup_status.connect(_on_comfy_setup)
	if ComfyUI.setup_message != "":
		_on_comfy_setup(ComfyUI.setup_message, ComfyUI.setup_fraction)

func _on_comfy_setup(message: String, fraction: float) -> void:
	if _comfy_status_label == null:
		return
	if message == "":
		_comfy_status_label.visible = false
		return
	var bar := ""
	if fraction >= 0.0:
		var filled := int(round(fraction * 16.0))
		bar = "  [%s%s]" % ["█".repeat(filled), "░".repeat(16 - filled)]
	_comfy_status_label.text = "AI setup: %s%s" % [message, bar]
	_comfy_status_label.visible = true

func _update_fps() -> void:
	if _fps_label == null:
		_fps_label = Label.new()
		_fps_label.name = "FPSLabel"
		_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fps_label.position = Vector2(8, 6)
		_fps_label.modulate = Color(0.7, 1.0, 0.7, 0.7)
		add_child(_fps_label)
	_fps_label.text = "%d FPS" % Engine.get_frames_per_second()

# The always-on gameplay HUD widgets (restored to visible when play begins) and the
# event/conditional ones (their own logic decides when they show). Hidden during the
# Adventure loading screen so only the generating overlay is on screen.
const _HUD_ALWAYS := ["Minimap", "Crosshair", "HealthBar", "HealthLabel", "AmmoLabel",
	"WeaponLabel", "GrenadeLabel", "EventLog", "QuestTracker", "HungerBar", "HungerLabel",
	"ThirstBar", "ThirstLabel"]
const _HUD_CONDITIONAL := ["OxygenBar", "OxygenLabel", "CarHealthBar", "CarHealthLabel",
	"VehiclePrompt", "NpcPrompt", "ObjectiveLabel", "DamageDirection", "LivesLabel",
	"TeamScoreLabel", "DeathLabel", "Celebration"]

## Show/hide the in-game HUD. While a world is loading, everything is hidden so only the
## generating overlay shows; when play begins the always-on widgets come back and the
## conditional ones are left for their own update logic (briefing shows only if it has text).
func _show_gameplay_hud(show: bool) -> void:
	for n in _HUD_ALWAYS:
		var node: Node = get_node_or_null(NodePath(n))
		if node != null:
			(node as CanvasItem).visible = show
	if _fps_label != null:
		_fps_label.visible = show
	if _gadget_label != null:
		_gadget_label.visible = show
	if not show:
		for n in _HUD_CONDITIONAL:
			var node: Node = get_node_or_null(NodePath(n))
			if node != null:
				(node as CanvasItem).visible = false
	else:
		objective_label.visible = objective_label.text.strip_edges() != ""

# ---------------------------------------------------------------- loading preview

## Fallback model list (works in exported builds where DirAccess can't scan res://).
const _PREVIEW_FALLBACK := [
	"res://assets/models/vehicles/sedan.glb", "res://assets/models/vehicles/suv.glb",
	"res://assets/models/vehicles/hatchback-sports.glb", "res://assets/models/vehicles/race-future.glb",
	"res://assets/models/weapons/blaster-a.glb", "res://assets/models/weapons/blaster-h.glb",
	"res://assets/models/weapons/blaster-r.glb", "res://assets/models/weapons/blaster-c.glb",
	"res://assets/models/weapons/grenade-b.glb", "res://assets/models/weapons/crate-medium.glb",
	"res://assets/models/weapons/scope-large-a.glb", "res://assets/models/weapons/target-small.glb",
	"res://assets/models/characters/character-a.glb", "res://assets/models/characters/character-f.glb",
	"res://assets/models/characters/character-k.glb", "res://assets/models/characters/character-p.glb",
]

## Show the spinning bottom-right model preview during loading (built on first use).
func _show_loading_preview() -> void:
	if _load_preview == null:
		_build_loading_preview()
	_load_preview.visible = true
	if _load_hint != null:
		_load_hint.visible = true
	_load_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if not _load_models.is_empty():
		_load_idx = randi() % _load_models.size()
		_load_show_current()

func _build_loading_preview() -> void:
	_load_models = _scan_preview_models()
	# Offscreen SubViewport rendered at 4x the display size, with MSAA — downscaled into
	# the TextureRect below for crisp, anti-aliased models.
	_load_vp = SubViewport.new()
	_load_vp.name = "LoadVP"
	_load_vp.transparent_bg = true
	_load_vp.own_world_3d = true
	_load_vp.msaa_3d = Viewport.MSAA_4X
	_load_vp.size = Vector2i(1024, 1024)
	_load_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_load_vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.35, 2.6)
	cam.rotation_degrees.x = -8.0
	_load_vp.add_child(cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	key.light_energy = 1.3
	_load_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(20.0, 140.0, 0.0)
	fill.light_energy = 0.5
	_load_vp.add_child(fill)
	_load_pivot = Node3D.new()
	_load_vp.add_child(_load_pivot)
	# Display: the viewport texture downscaled into a ~260 px box (supersampling = crisp).
	_load_preview = TextureRect.new()
	_load_preview.name = "LoadPreview"
	_load_preview.texture = _load_vp.get_texture()
	_load_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_load_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_load_preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_load_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_preview.anchor_left = 1.0
	_load_preview.anchor_top = 1.0
	_load_preview.anchor_right = 1.0
	_load_preview.anchor_bottom = 1.0
	_load_preview.offset_left = -284.0
	_load_preview.offset_top = -308.0
	_load_preview.offset_right = -24.0
	_load_preview.offset_bottom = -48.0
	add_child(_load_preview)
	# A little "[Space] next" hint under the preview (child so it toggles with it).
	var hint := Label.new()
	hint.name = "PreviewHint"
	hint.text = "[Space] next"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.6)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_left = 0.0
	hint.anchor_top = 1.0
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.offset_top = 2.0
	hint.offset_bottom = 20.0
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_preview.add_child(hint)
	_load_hint = hint

## Scan the model folders (editor), falling back to the baked list (export).
func _scan_preview_models() -> Array:
	var out: Array = []
	for dir in ["res://assets/models/weapons/", "res://assets/models/vehicles/", "res://assets/models/characters/"]:
		var da := DirAccess.open(dir)
		if da == null:
			continue
		for f in da.get_files():
			if f.to_lower().ends_with(".glb"):
				out.append(dir + f)
	if out.size() < 4:
		out = _PREVIEW_FALLBACK.duplicate()
	out.shuffle()
	return out

func _load_next_model() -> void:
	if _load_models.is_empty():
		return
	_load_idx = (_load_idx + 1) % _load_models.size()
	_load_show_current()

## Instance the current model into the pivot, centred and scaled to fit the little view.
func _load_show_current() -> void:
	if _load_pivot == null or _load_models.is_empty():
		return
	for c in _load_pivot.get_children():
		c.queue_free()
	_load_pivot.rotation = Vector3.ZERO
	var scene = load(String(_load_models[_load_idx]))
	if scene == null or not (scene is PackedScene):
		return
	var inst := (scene as PackedScene).instantiate()
	_load_pivot.add_child(inst)
	var aabb := _model_aabb(inst)
	if aabb.size.length() > 0.001:
		var s := 1.5 / maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
		inst.scale = Vector3.ONE * s
		inst.position = -(aabb.position + aabb.size * 0.5) * s   # centre on the pivot

## Merged AABB of every MeshInstance3D under `node` (in node-local space).
func _model_aabb(node: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var t: Transform3D = node.global_transform.affine_inverse() * m.global_transform
		var a := t * m.mesh.get_aabb()
		if first:
			box = a
			first = false
		else:
			box = box.merge(a)
	return box

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

const GADGET_NAMES := {"flashlight": "Flashlight", "binoculars": "Binoculars", "nvg": "Night Vision", "scanner": "Scanner", "torch": "Torch", "jetpack": "Jetpack", "shovel": "Shovel"}

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
	var piece: Dictionary = _player.equip.get("gadget", {})
	if g == "jetpack":
		var f := int(round(float(piece.get("cur_fuel", 0)) / maxf(1.0, float(piece.get("fuel", 100))) * 100.0))
		state = "  [hold jump]  %d%%" % f
	elif g == "torch":
		state = "  [Q]  %ds" % int(ceil(float(piece.get("cur_fuel", 0))))
	elif g == "scanner":
		state = "  [Q ping]"
	elif g == "shovel":
		state = "  [Q dig]"
	elif _player.get("_gadget_on"):
		state = "  [ON]"
	else:
		state = "  [Q]"
	_gadget_label.text = "%s%s" % [GADGET_NAMES.get(g, g), state]

## Night-vision: an image-intensifier shader that amplifies the scene's low light into a
## visible green picture. Sits behind the rest of the HUD so readouts stay legible on top.
func set_nightvision(on: bool) -> void:
	if _nvg == null:
		_nvg = ColorRect.new()
		_nvg.name = "NVG"
		_nvg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_nvg.color = Color(1, 1, 1, 1)
		_nvg.set_anchors_preset(Control.PRESET_FULL_RECT)
		var sh := Shader.new()
		sh.code = NVG_SHADER
		_nvg_mat = ShaderMaterial.new()
		_nvg_mat.shader = sh
		_nvg.material = _nvg_mat
		_nvg_mat.set_shader_parameter("amount", 0.0)
		add_child(_nvg)
		move_child(_nvg, 0)
	var from: float = float(_nvg_mat.get_shader_parameter("amount"))
	if on:
		_nvg.visible = true
	var tw := create_tween()
	tw.tween_method(func(a: float): _nvg_mat.set_shader_parameter("amount", a),
		from, 1.0 if on else 0.0, 0.25)
	if not on:
		tw.tween_callback(func(): _nvg.visible = false)

# ---------------------------------------------------------------- debug menu (solo)

## Toggle the [0] debug/cheat menu. Guarded to solo adventures with debug mode enabled
## so it can never touch a co-op session.
func _toggle_debug_menu() -> void:
	if not Settings.debug_mode or not Game.is_adventure() or _player == null:
		return
	if not (Net.is_host() and Net.players.size() <= 1):
		add_event("⚙ Debug menu is available in solo games only.")
		return
	if _debug_panel == null:
		_build_debug_panel()
	_debug_panel.visible = not _debug_panel.visible
	if _debug_panel.visible:
		_refresh_debug()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not inventory_panel.visible and not npc_dialog.visible and not pause_panel.visible \
			and not result_panel.visible and not trade_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _build_debug_panel() -> void:
	# A full-screen CenterContainer centres the panel; a PanelContainer auto-sizes to its
	# content, so the menu stays centred no matter how tall it grows.
	var holder := CenterContainer.new()
	holder.name = "DebugHolder"
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE   # only the panel catches clicks
	add_child(holder)
	var panel := PanelContainer.new()
	panel.name = "DebugPanel"
	panel.custom_minimum_size = Vector2(360, 0)
	holder.add_child(panel)
	_debug_panel = panel
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)
	var title := Label.new()
	title.text = "DEBUG  ·  [0] to close"
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)
	# Stat rows: -25 / +25 / Max, with a live value readout.
	for stat in ["health", "thirst", "hunger"]:
		vb.add_child(_dbg_stat_row(stat))
	vb.add_child(HSeparator.new())
	# Item spawner.
	var irow := HBoxContainer.new()
	irow.add_theme_constant_override("separation", 6)
	_dbg_item = OptionButton.new()
	_dbg_item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dbg_item_ids.clear()
	for id in ItemDB.DEFS.keys():
		_dbg_item.add_item(String(ItemDB.DEFS[id].get("name", id)))
		_dbg_item_ids.append(String(id))
	for wid in WeaponDB.all_ids():
		_dbg_item.add_item("%s (weapon)" % String(WeaponDB.get_weapon(wid).get("name", wid)))
		_dbg_item_ids.append(String(wid))
	irow.add_child(_dbg_item)
	var spawn_btn := Button.new()
	spawn_btn.text = "Spawn"
	spawn_btn.pressed.connect(_on_debug_spawn)
	irow.add_child(spawn_btn)
	vb.add_child(irow)
	vb.add_child(HSeparator.new())
	# No-clip toggle.
	_dbg_noclip = CheckButton.new()
	_dbg_noclip.text = "No-clip (fly through walls)"
	_dbg_noclip.button_pressed = bool(_player.get("noclip"))
	_dbg_noclip.toggled.connect(func(on): if _player != null: _player.debug_set_noclip(on))
	vb.add_child(_dbg_noclip)
	vb.add_child(HSeparator.new())
	# AI generate: type a prompt -> ComfyUI -> spawn it in front of you (3D mesh or billboard).
	var ailbl := Label.new()
	ailbl.text = "AI generate (ComfyUI) — spawns in front"
	vb.add_child(ailbl)
	_dbg_ai_prompt = LineEdit.new()
	_dbg_ai_prompt.placeholder_text = "describe an object…"
	_dbg_ai_prompt.text_submitted.connect(func(_t): _on_debug_generate())
	vb.add_child(_dbg_ai_prompt)
	_dbg_ai_3d = CheckButton.new()
	var has_3d: bool = ComfyUI.has_workflow("model")
	_dbg_ai_3d.text = "3D model (textured)" if has_3d else "3D model (unavailable — no bundle)"
	_dbg_ai_3d.button_pressed = has_3d   # default to 3D when the bundle provides it
	_dbg_ai_3d.disabled = not has_3d
	vb.add_child(_dbg_ai_3d)
	var gen := Button.new()
	gen.text = "Generate & spawn"
	gen.pressed.connect(_on_debug_generate)
	vb.add_child(gen)
	_dbg_ai_status = Label.new()
	_dbg_ai_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dbg_ai_status.custom_minimum_size.x = 330
	vb.add_child(_dbg_ai_status)

## One stat row: label + value + [-25] [+25] [Max] wired to the player's debug setters.
func _dbg_stat_row(stat: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var name_lbl := Label.new()
	name_lbl.text = stat.capitalize()
	name_lbl.custom_minimum_size.x = 72
	row.add_child(name_lbl)
	var val := Label.new()
	val.custom_minimum_size.x = 44
	row.add_child(val)
	_dbg_values[stat] = val
	for d in [-25.0, 25.0]:
		var b := Button.new()
		b.text = "%+d" % int(d)
		b.pressed.connect(func(): _debug_stat(stat, d))
		row.add_child(b)
	var mx := Button.new()
	mx.text = "Max"
	mx.pressed.connect(func(): _debug_stat(stat, 9999.0))
	row.add_child(mx)
	return row

func _debug_stat(stat: String, delta: float) -> void:
	if _player == null:
		return
	match stat:
		"health": _player.debug_add_health(delta)
		"thirst": _player.debug_add_thirst(delta)
		"hunger": _player.debug_add_hunger(delta)
	_refresh_debug()

func _on_debug_spawn() -> void:
	if _player == null or _dbg_item == null:
		return
	var idx := _dbg_item.selected
	if idx < 0 or idx >= _dbg_item_ids.size():
		return
	var id := String(_dbg_item_ids[idx])
	if _player.debug_spawn_item(id):
		add_event("⚙ Spawned %s" % id)
	else:
		add_event("⚙ Couldn't spawn %s (pack full?)" % id)

## Ask ComfyUI to generate from the typed prompt; _on_debug_asset spawns the result in front
## of the player. The 3D toggle requests a GLB mesh (needs a 3D workflow at
## user://comfyui/workflow_model.json); off requests an image spawned as a billboard.
func _on_debug_generate() -> void:
	if _player == null or _dbg_ai_prompt == null:
		return
	var prompt := _dbg_ai_prompt.text.strip_edges()
	if prompt == "":
		return
	if not ComfyUI.asset_ready.is_connected(_on_debug_asset):
		ComfyUI.asset_ready.connect(_on_debug_asset)
		ComfyUI.asset_failed.connect(_on_debug_asset_failed)
	var want_3d := _dbg_ai_3d != null and _dbg_ai_3d.button_pressed
	if want_3d and not ComfyUI.has_workflow("model"):
		_dbg_ai_status.text = "3D isn't bundled in this build. Reinstall the ComfyUI bundle, or drop a workflow_model.json in the comfyui folder."
		return
	var kind := "model" if want_3d else "image"
	var key := "dbg_%s_%s" % [kind, prompt]
	_dbg_ai_status.text = "Generating %s '%s'… (watch ComfyUI; this can take a while)" % [kind, prompt]
	ComfyUI.ensure_server()
	ComfyUI.bake(prompt + ", single object, plain background", key, kind)

func _on_debug_asset_failed(key: String) -> void:
	if key.begins_with("dbg_") and _dbg_ai_status != null:
		var why := String(ComfyUI.last_error)
		_dbg_ai_status.text = why if why != "" else "Generation failed (no detail). Is ComfyUI running at the endpoint?"

## Minimal runtime OBJ loader for TripoSR output: parses `v x y z [r g b]` (optional per-vertex
## colour, as trimesh exports) and triangulated faces into a vertex-coloured ArrayMesh. Godot has
## no runtime .obj importer, and TripoSR's mesh is small, so a tiny parser is enough.
func _mesh_from_obj(file_path: String) -> ArrayMesh:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return null
	var verts: PackedVector3Array = []
	var cols: PackedColorArray = []
	var has_color := false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	while not f.eof_reached():
		var parts := f.get_line().strip_edges().split(" ", false)
		if parts.size() == 0:
			continue
		if parts[0] == "v" and parts.size() >= 4:
			verts.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
			if parts.size() >= 7:
				has_color = true
				var r := parts[4].to_float()
				var g := parts[5].to_float()
				var b := parts[6].to_float()
				if r > 1.0 or g > 1.0 or b > 1.0:   # some exporters write 0-255
					r /= 255.0; g /= 255.0; b /= 255.0
				cols.append(Color(r, g, b))
			else:
				cols.append(Color(1, 1, 1))
		elif parts[0] == "f" and parts.size() >= 4:
			# Face indices (1-based, possibly "v/vt/vn"); fan-triangulate polygons.
			var idx: PackedInt32Array = []
			for i in range(1, parts.size()):
				var tok := parts[i].split("/")[0]
				var vi := tok.to_int()
				if vi < 0:
					vi = verts.size() + vi + 1   # negative = relative index
				idx.append(vi - 1)
			for t in range(1, idx.size() - 1):
				for vi in [idx[0], idx[t], idx[t + 1]]:
					if vi < 0 or vi >= verts.size():
						continue
					if has_color:
						st.set_color(cols[vi])
					st.add_vertex(verts[vi])
	f.close()
	if verts.is_empty():
		return null
	st.generate_normals()
	var mesh := st.commit()
	if has_color and mesh.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.9
		mesh.surface_set_material(0, mat)
	return mesh

## In front of the player, ground-snapped, for spawning a generated asset.
func _debug_spawn_pos() -> Vector3:
	var fwd: Vector3 = -_player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var pos: Vector3 = _player.global_position + fwd * 3.0
	var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 5.0, pos - Vector3.UP * 20.0)
	q.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(q)
	if not hit.is_empty():
		pos.y = float(hit.position.y)
	return pos

func _on_debug_asset(key: String, path: String) -> void:
	if not key.begins_with("dbg_") or _player == null:
		return
	var pos := _debug_spawn_pos()
	var lower := path.to_lower()
	if lower.ends_with(".glb"):
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) != OK:
			_dbg_ai_status.text = "Couldn't load the generated GLB."
			return
		var node := doc.generate_scene(state)
		if node == null:
			_dbg_ai_status.text = "GLB produced no scene."
			return
		node.position = pos
		get_tree().current_scene.add_child(node)
		_dbg_ai_status.text = "Spawned model '%s'." % key.trim_prefix("dbg_")
	elif lower.ends_with(".obj"):
		# TripoSR (text→3D) exports a vertex-coloured OBJ; parse it into a mesh and spawn it.
		var mesh := _mesh_from_obj(path)
		if mesh == null:
			_dbg_ai_status.text = "Couldn't parse the generated 3D mesh."
			return
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = pos + Vector3.UP * 0.5
		get_tree().current_scene.add_child(mi)
		_dbg_ai_status.text = "Spawned model '%s'." % key.trim_prefix("dbg_")
	else:
		# Image asset -> a billboard sprite standing in front of you.
		var tex := ComfyUI.asset_texture(key)
		if tex == null:
			_dbg_ai_status.text = "Generated an image but couldn't load it."
			return
		var spr := Sprite3D.new()
		spr.texture = tex
		spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		spr.pixel_size = 2.0 / maxf(float(tex.get_height()), 1.0)   # ~2 m tall
		spr.position = pos + Vector3.UP * 1.2
		get_tree().current_scene.add_child(spr)
		_dbg_ai_status.text = "Spawned image billboard '%s'." % key.trim_prefix("dbg_")

## Refresh the live stat readouts + noclip state.
func _refresh_debug() -> void:
	if _player == null or _debug_panel == null:
		return
	if _dbg_values.has("health"):
		_dbg_values["health"].text = "%d" % int(round(_player.sync_health))
	if _dbg_values.has("thirst"):
		_dbg_values["thirst"].text = "%d" % int(round(_player.thirst))
	if _dbg_values.has("hunger"):
		_dbg_values["hunger"].text = "%d" % int(round(_player.hunger))
	if _dbg_noclip != null:
		_dbg_noclip.button_pressed = bool(_player.get("noclip"))

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
		_size_inventory_panel()   # fit the panel to the backpack so the frame wraps it
		tabs.current_tab = 0   # always open on the Inventory tab, not the last-used one
		_refresh_inventory()
		_refresh_stats()
		_refresh_skills()
		_refresh_crafting()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Open the backpack straight to the Crafting tab (used by E on a campfire).
func open_crafting() -> void:
	if result_panel.visible or pause_panel.visible:
		return
	inventory_panel.visible = true
	_size_inventory_panel()
	tabs.current_tab = 2   # Crafting tab
	_refresh_inventory()
	_refresh_crafting()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## Resize + recentre the backpack window so its frame always wraps the grid (which grows
## with the backpack), clamped to the screen. The VBox fills the panel minus a margin.
func _size_inventory_panel() -> void:
	var vp := get_viewport().get_visible_rect().size
	var gw := 200.0
	var gh := 200.0
	if _player != null and is_instance_valid(_player):
		gw = maxf(200.0, float(_player.backpack_w) * 50.0)
		gh = maxf(200.0, float(_player.backpack_h) * 50.0)
	# equip column + separation + grid + side margins ; tabs header + capacity + rows + hint
	var content_w := clampf(196.0 + 14.0 + gw + 40.0, 480.0, vp.x - 40.0)
	var content_h := clampf(44.0 + 24.0 + maxf(256.0, gh) + 30.0 + 24.0, 360.0, vp.y - 40.0)
	inventory_panel.anchor_left = 0.5
	inventory_panel.anchor_top = 0.5
	inventory_panel.anchor_right = 0.5
	inventory_panel.anchor_bottom = 0.5
	inventory_panel.offset_left = -content_w * 0.5
	inventory_panel.offset_right = content_w * 0.5
	inventory_panel.offset_top = -content_h * 0.5
	inventory_panel.offset_bottom = content_h * 0.5
	var vb := inventory_panel.get_node_or_null("VBox")
	if vb is Control:
		var c := vb as Control
		c.anchor_left = 0.0
		c.anchor_top = 0.0
		c.anchor_right = 1.0
		c.anchor_bottom = 1.0
		c.offset_left = 16.0
		c.offset_top = 12.0
		c.offset_right = -16.0
		c.offset_bottom = -12.0

func _refresh_inventory() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	backpack_grid.set_player(_player)
	backpack_grid.equip_panel = equip_panel
	inv_capacity.text = "Space  %d / %d        ⛁ %d coins" % [_player.inv_used(), _player.inv_cell_count(), int(_player.coins)]

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

# ---------------------------------------------------------------- crafting tab

## List crafting recipes with their cost; Craft button enabled when you can make it.
func _refresh_crafting() -> void:
	if craft_list == null:
		return
	for c in craft_list.get_children():
		c.queue_free()
	var near_fire: bool = _player != null and is_instance_valid(_player) and _player.near_campfire()
	var hint := Label.new()
	hint.text = "Cooking needs a campfire nearby.  " + ("(campfire in range)" if near_fire else "(no campfire)")
	hint.modulate = Color(1, 1, 1, 0.6)
	craft_list.add_child(hint)
	# Feed the nearby campfire to keep it burning (1 wood -> +90 s).
	if near_fire:
		var feed_row := HBoxContainer.new()
		var fl := Label.new()
		fl.text = "Feed Fire"
		fl.custom_minimum_size.x = 120
		var fc := Label.new()
		fc.text = "1x Wood  ->  +90s burn"
		fc.custom_minimum_size.x = 230
		fc.modulate = Color(1, 1, 1, 0.7)
		feed_row.add_child(fl)
		feed_row.add_child(fc)
		var fb := Button.new()
		fb.text = "Feed"
		fb.disabled = not (_player.has_method("_count_material") and _player._count_material("wood") > 0)
		fb.pressed.connect(_feed_fire)
		feed_row.add_child(fb)
		craft_list.add_child(feed_row)
	for recipe in ItemDB.RECIPES:
		var row := HBoxContainer.new()
		var cost := PackedStringArray()
		for id in (recipe["in"] as Dictionary):
			cost.append("%dx %s" % [int(recipe["in"][id]), ItemDB.DEFS.get(id, {}).get("name", id)])
		var name_l := Label.new()
		name_l.text = String(recipe["name"])
		name_l.custom_minimum_size.x = 120
		var cost_l := Label.new()
		cost_l.text = " ".join(cost) + (" + fire" if recipe.get("fire", false) else "")
		cost_l.custom_minimum_size.x = 230
		cost_l.modulate = Color(1, 1, 1, 0.7)
		row.add_child(name_l)
		row.add_child(cost_l)
		var btn := Button.new()
		btn.text = "Craft"
		btn.disabled = not (_player != null and is_instance_valid(_player) and _player.can_craft(recipe))
		var rec: Dictionary = recipe
		btn.pressed.connect(func(): _do_craft(rec))
		row.add_child(btn)
		craft_list.add_child(row)

func _do_craft(recipe: Dictionary) -> void:
	if _player != null and is_instance_valid(_player) and _player.craft(recipe):
		Audio.play_ui("res://assets/audio/ui_click.ogg", -4.0)
	_refresh_crafting()
	_refresh_inventory()

## Spend one wood to extend the nearest campfire's burn.
func _feed_fire() -> void:
	if _player != null and is_instance_valid(_player) and _player.has_method("feed_campfire") and _player.feed_campfire():
		Audio.play_ui("res://assets/audio/ui_click.ogg", -4.0)
	_refresh_crafting()
	_refresh_inventory()

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
	ammo_label.text = "%d / ∞" % mag if reserve < 0 else "%d / %d" % [mag, reserve]

func _on_weapon(wname: String) -> void:
	weapon_label.text = wname

func set_objective(t: String) -> void:
	objective_label.text = t
	objective_label.visible = t != ""

# ---------------------------------------------------------------- scoreboard

func _input(event: InputEvent) -> void:
	# While the world is loading, Space cycles the spinning preview model.
	if _load_preview != null and _load_preview.visible and event is InputEventKey \
			and event.pressed and not event.echo and (event as InputEventKey).keycode == KEY_SPACE:
		_load_next_model()
		get_viewport().set_input_as_handled()
		return
	# Debug menu ([0]): only when debug mode is enabled and this is a solo adventure.
	# Skip while a text field has focus so typing "0" (e.g. asking an NPC) isn't eaten.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_0:
		var fo := get_viewport().gui_get_focus_owner()
		if not (fo is LineEdit or fo is TextEdit):
			_toggle_debug_menu()
			get_viewport().set_input_as_handled()
			return
	# Adventure: the configurable inventory key opens/closes the backpack (and, when
	# it is Tab, takes precedence over the scoreboard). When an NPC talk dialog is
	# open it closes the dialog and swaps straight to the backpack — this runs before
	# the text-field guard below so it works even while the "ask" field has focus.
	if Game.is_adventure() and _is_inventory_key(event):
		if _debug_panel != null and _debug_panel.visible:
			_debug_panel.visible = false   # Tab from the debug menu -> straight to backpack
		if npc_dialog.visible:
			_close_npc_dialog()
		_toggle_inventory()
		get_viewport().set_input_as_handled()
		return
	# While a text field has focus (e.g. asking an NPC), let it have the keyboard —
	# don't fire game shortcuts like M (map) into the typed message.
	# Escape still passes through so it can close the dialog.
	if event is InputEventKey:
		var focus := get_viewport().gui_get_focus_owner()
		if (focus is LineEdit or focus is TextEdit) and not event.is_action_pressed("pause"):
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
		if _debug_panel != null and _debug_panel.visible:
			_toggle_debug_menu()   # Esc closes the debug menu (restores mouse capture)
		elif trade_panel.visible:
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
	Music.stop()
	Net.disconnect_net()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
