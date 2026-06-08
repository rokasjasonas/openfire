extends Control
## Equipment panel shown left of the backpack: a column of armor (Head / Body /
## Legs), a row of three gun slots beneath it (mirroring the weapon loadout), and
## an Extra (throwable) slot in the top-right corner next to the backpack.
## Double-click a slot to unequip it. Equip from the grid (double-click an item, or
## drag it left onto this panel).

const SW := 60.0   # slot width
const SH := 48.0   # slot height

var player: Node = null

const SLOTS := [
	{"slot": "head", "label": "Head", "x": 4, "y": 4},
	{"slot": "body", "label": "Body", "x": 4, "y": 58},
	{"slot": "pants", "label": "Legs", "x": 4, "y": 112},
	# Gun row sits well below the armor column (bigger gap).
	{"slot": "gun1", "label": "Gun 1", "x": 4, "y": 204},
	{"slot": "gun2", "label": "Gun 2", "x": 68, "y": 204},
	{"slot": "gun3", "label": "Gun 3", "x": 132, "y": 204},
	{"slot": "extra", "label": "Extra", "x": 132, "y": 4},
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
	var font := get_theme_default_font()
	for s in SLOTS:
		var rect := _slot_rect(s)
		draw_rect(rect, Color(0.10, 0.11, 0.14, 0.92), true)
		draw_rect(rect, Color(1, 1, 1, 0.16), false, 1.0)
		if font == null:
			continue
		draw_string(font, rect.position + Vector2(5, 11), String(s["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, SW - 6, 9, Color(1, 1, 1, 0.42))
		var item := _slot_item(String(s["slot"]))
		if item.is_empty():
			draw_string(font, rect.position + Vector2(0, SH * 0.62), "—",
				HORIZONTAL_ALIGNMENT_CENTER, SW, 13, Color(1, 1, 1, 0.25))
			continue
		ItemIcon.draw(self, item, Rect2(rect.position + Vector2(0, 12), Vector2(SW, SH - 12)), 3.0)
		var strip := Rect2(rect.position + Vector2(0, SH - 12), Vector2(SW, 12))
		draw_rect(strip, Color(0, 0, 0, 0.5), true)
		draw_string(font, rect.position + Vector2(3, SH - 3), String(item.get("name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, SW - 4, 9, Color(1, 1, 1, 0.9))
