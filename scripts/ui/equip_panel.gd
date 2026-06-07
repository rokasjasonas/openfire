extends Control
## Equipment doll shown left of the backpack: head / body / legs armor, three gun
## slots (mirroring the weapon loadout) and a throwable "extra" slot. Double-click a
## slot to unequip it back into the backpack. Items are equipped from the grid
## (double-click an item, or drag it left onto this panel).

const CELL := 50.0
const W := 178.0

var player: Node = null

const SLOTS := [
	{"slot": "head", "label": "Head"},
	{"slot": "body", "label": "Body"},
	{"slot": "pants", "label": "Legs"},
	{"slot": "gun1", "label": "Gun 1"},
	{"slot": "gun2", "label": "Gun 2"},
	{"slot": "gun3", "label": "Gun 3"},
	{"slot": "extra", "label": "Extra"},
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

func _gui_input(event: InputEvent) -> void:
	if player == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and event.double_click:
		var row := int(floor(event.position.y / CELL))
		if row >= 0 and row < SLOTS.size():
			player.unequip(String(SLOTS[row]["slot"]))

func _draw() -> void:
	if player == null:
		return
	var font := get_theme_default_font()
	for r in SLOTS.size():
		var y := r * CELL
		var rect := Rect2(0, y + 2, W, CELL - 4)
		draw_rect(rect, Color(0.10, 0.11, 0.14, 0.9), true)
		draw_rect(rect, Color(1, 1, 1, 0.15), false, 1.0)
		var item := _slot_item(String(SLOTS[r]["slot"]))
		if font == null:
			continue
		draw_string(font, Vector2(8, y + 15), String(SLOTS[r]["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, W - 10, 11, Color(1, 1, 1, 0.45))
		if item.is_empty():
			draw_string(font, Vector2(8, y + 37), "(empty)", HORIZONTAL_ALIGNMENT_LEFT, W - 10, 13, Color(1, 1, 1, 0.28))
		else:
			draw_string(font, Vector2(8, y + 38), String(item.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, W - 10, 14, ItemDB.color_for(String(item.get("kind", ""))))
