extends Control
## Equipment panel shown left of the backpack: a column of armor (Head / Body /
## Legs), a row of three gun slots beneath it (mirroring the weapon loadout), and
## an Extra (throwable) slot in the top-right corner next to the backpack.
## Double-click a slot to unequip it. Equip from the grid (double-click an item, or
## drag it left onto this panel).

const SW := 60.0   # slot width
const SH := 48.0   # slot height

var player: Node = null

# Manual drag of a gun out of its slot (reorder between slots, or drop onto the
# backpack to unequip). "" when not dragging.
var _drag_slot: String = ""
var _drag_pos: Vector2 = Vector2.ZERO

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
		if player.weapons.slot_filled(i):
			# Build the same item dict the backpack uses so the weapon preview
			# image renders here too (icon lookup needs weapon_id).
			return ItemDB.make_weapon(String(player.weapons.loadout[i]))
		return {}
	return player.equip.get(slot, {})

func _slot_rect(s: Dictionary) -> Rect2:
	return Rect2(float(s["x"]), float(s["y"]), SW, SH)

## The gun slot (0-2) under a global-space point, or -1. Used by the backpack grid
## to drop a dragged weapon into a specific slot.
func gun_slot_at_global(gpos: Vector2) -> int:
	var local := gpos - global_position
	for s in SLOTS:
		var nm := String(s["slot"])
		if nm.begins_with("gun") and _slot_rect(s).has_point(local):
			return int(nm.substr(3)) - 1
	return -1

func _gun_slot_at(pos: Vector2) -> int:
	for s in SLOTS:
		var nm := String(s["slot"])
		if nm.begins_with("gun") and _slot_rect(s).has_point(pos):
			return int(nm.substr(3)) - 1
	return -1

func _gui_input(event: InputEvent) -> void:
	if player == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				for s in SLOTS:
					if _slot_rect(s).has_point(event.position):
						player.unequip(String(s["slot"]))
						return
				return
			# Begin dragging a gun out of a filled gun slot.
			var gi := _gun_slot_at(event.position)
			if gi >= 0 and player.weapons.slot_filled(gi):
				_drag_slot = "gun%d" % (gi + 1)
				_drag_pos = event.position
				queue_redraw()
		else:
			if _drag_slot != "":
				_end_drag(event.position)
				_drag_slot = ""
				queue_redraw()
		return
	elif event is InputEventMouseMotion and _drag_slot != "":
		_drag_pos = event.position
		queue_redraw()
		return

## Resolve where a dragged gun was dropped: onto another gun slot (reorder/swap),
## or out to the right onto the backpack (unequip).
func _end_drag(pos: Vector2) -> void:
	var from_i := int(_drag_slot.substr(3)) - 1
	var to_i := _gun_slot_at(pos)
	if to_i >= 0:
		if to_i != from_i:
			player.move_gun(from_i, to_i)
		return
	if pos.x > size.x:  # dropped onto the backpack -> unequip
		player.unequip(_drag_slot)

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
		# Hide the source slot's static icon while it's being dragged.
		if String(s["slot"]) == _drag_slot:
			continue
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

	# The gun being dragged follows the cursor.
	if _drag_slot != "":
		var di := _slot_item(_drag_slot)
		if not di.is_empty():
			var fr := Rect2(_drag_pos - Vector2(SW, SH) * 0.5, Vector2(SW, SH))
			draw_rect(fr, Color(0.12, 0.13, 0.16, 0.85), true)
			ItemIcon.draw(self, di, fr, 3.0)
