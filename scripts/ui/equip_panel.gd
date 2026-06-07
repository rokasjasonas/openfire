extends Control
## Equipment doll shown left of the backpack, laid out like a body: head on top,
## body in the middle with a gun in each "hand", legs below, and a holster (Gun 3)
## and belt (Extra) at the bottom. The three gun slots mirror the weapon loadout.
## Double-click a slot to unequip it. Equip from the grid (double-click an item, or
## drag it left onto this panel).

const SW := 60.0   # slot width
const SH := 48.0   # slot height

var player: Node = null

# Body-shaped layout: each slot's top-left position.
const SLOTS := [
	{"slot": "head", "label": "Head", "x": 68, "y": 4},
	{"slot": "gun1", "label": "Gun 1", "x": 4, "y": 58},
	{"slot": "body", "label": "Body", "x": 68, "y": 58},
	{"slot": "gun2", "label": "Gun 2", "x": 132, "y": 58},
	{"slot": "pants", "label": "Legs", "x": 68, "y": 114},
	{"slot": "gun3", "label": "Gun 3", "x": 4, "y": 174},
	{"slot": "extra", "label": "Extra", "x": 132, "y": 174},
]

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

func set_player(p: Node) -> void:
	player = p
	refresh()

func refresh() -> void:
	queue_redraw()

func _slot_item(slot: String) -> Dictionary:
	if player == null:
		return {}
	if slot.begins_with("gun"):
		var i := int(slot.substr(3)) - 1
		var lo: Array = player.weapons.loadout
		if i >= 0 and i < lo.size():
			return {"name": String(WeaponDB.get_weapon(String(lo[i]))["name"]), "kind": "weapon"}
		return {}
	return player.equip.get(slot, {})

func _slot_rect(s: Dictionary) -> Rect2:
	return Rect2(float(s["x"]), float(s["y"]), SW, SH)

func _gui_input(event: InputEvent) -> void:
	if player == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and event.double_click:
		for s in SLOTS:
			if _slot_rect(s).has_point(event.position):
				player.unequip(String(s["slot"]))
				return

func _draw() -> void:
	if player == null:
		return
	# Faint body silhouette linking the slots (spine + arms).
	var c := Color(1, 1, 1, 0.10)
	var head_c := Vector2(68 + SW * 0.5, 4 + SH)
	var body_c := Vector2(68 + SW * 0.5, 58 + SH * 0.5)
	var legs_c := Vector2(68 + SW * 0.5, 114)
	draw_line(head_c, body_c, c, 2.0)
	draw_line(Vector2(68 + SW * 0.5, 58 + SH), legs_c + Vector2(0, SH), c, 2.0)
	draw_line(body_c, Vector2(4 + SW, 58 + SH * 0.5), c, 2.0)   # left arm
	draw_line(body_c, Vector2(132, 58 + SH * 0.5), c, 2.0)      # right arm

	var font := get_theme_default_font()
	for s in SLOTS:
		var rect := _slot_rect(s)
		draw_rect(rect, Color(0.10, 0.11, 0.14, 0.92), true)
		draw_rect(rect, Color(1, 1, 1, 0.16), false, 1.0)
		if font == null:
			continue
		draw_string(font, rect.position + Vector2(6, 14), String(s["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, SW - 8, 10, Color(1, 1, 1, 0.45))
		var item := _slot_item(String(s["slot"]))
		if item.is_empty():
			draw_string(font, rect.position + Vector2(6, 34), "—", HORIZONTAL_ALIGNMENT_LEFT, SW - 8, 13, Color(1, 1, 1, 0.28))
		else:
			draw_string(font, rect.position + Vector2(6, 35), String(item.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, SW - 8, 12, ItemDB.color_for(String(item.get("kind", ""))))
