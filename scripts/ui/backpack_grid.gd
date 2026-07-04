extends Control
## Spatial drag-and-drop backpack grid. Renders the player's inventory as a grid of
## cells with multi-cell item footprints. Drag an item to rearrange it, drag it out
## of the grid to drop it into the world, double-click to use/equip, press R to rotate
## the item under the cursor (or the one being dragged). Talks to Player.inv_move /
## inv_rotate / inv_use / inv_drop.

const CELL := 50.0

var player: Node = null
var equip_panel: Control = null        # sibling panel, for slot-targeted weapon drops
var _drag: int = -1                    # index of the item being dragged, or -1
var _grab_off: Vector2 = Vector2.ZERO  # cursor offset within the grabbed item
var _mouse: Vector2 = Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

func set_player(p: Node) -> void:
	player = p
	refresh()

func refresh() -> void:
	if player != null:
		custom_minimum_size = Vector2(player.backpack_w * CELL, player.backpack_h * CELL)
	queue_redraw()

func _grid_size() -> Vector2:
	if player == null:
		return Vector2.ZERO
	return Vector2(player.backpack_w * CELL, player.backpack_h * CELL)

func _cell_at(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL)), int(floor(pos.y / CELL)))

## Index of the item whose footprint covers the cell under `pos`, or -1.
func _item_at(pos: Vector2) -> int:
	if player == null:
		return -1
	var c := _cell_at(pos)
	for i in player.inventory.size():
		var it: Dictionary = player.inventory[i]
		var gx := int(it.get("gx", 0))
		var gy := int(it.get("gy", 0))
		if c.x >= gx and c.x < gx + int(it.get("w", 1)) and c.y >= gy and c.y < gy + int(it.get("h", 1)):
			return i
	return -1

func _gui_input(event: InputEvent) -> void:
	if player == null:
		return
	# Only the press (start-drag / double-click) is handled here, since it always lands
	# on the grid. The release and drag-tracking live in _input so the drop works no
	# matter where the cursor ends up — GUI events stop reaching us once it leaves our rect.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.double_click:
			var di := _item_at(event.position)
			if di >= 0:
				player.equip_item(di)  # equip (or use, for consumables)
			_drag = -1
			return
		_drag = _item_at(event.position)
		if _drag >= 0:
			var it: Dictionary = player.inventory[_drag]
			_grab_off = event.position - Vector2(int(it.get("gx", 0)) * CELL, int(it.get("gy", 0)) * CELL)
		queue_redraw()

## While an item is held we track the mouse globally: the ghost follows the cursor
## anywhere on screen, and releasing the button outside our rect still drops the item.
func _input(event: InputEvent) -> void:
	if player == null:
		return
	# R rotates the item being dragged, or (when not dragging) the one under the cursor.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_R and is_visible_in_tree():
		var idx := _drag if _drag >= 0 else _item_at(get_local_mouse_position())
		if idx >= 0 and player.inv_rotate(idx):
			if _drag >= 0:
				# Keep the grabbed anchor inside the item's new footprint so the ghost
				# stays under the cursor after the swap.
				var it: Dictionary = player.inventory[_drag]
				_grab_off.x = clampf(_grab_off.x, 2.0, maxf(2.0, int(it.get("w", 1)) * CELL - 2.0))
				_grab_off.y = clampf(_grab_off.y, 2.0, maxf(2.0, int(it.get("h", 1)) * CELL - 2.0))
			queue_redraw()
			get_viewport().set_input_as_handled()
		return
	if _drag < 0:
		return
	if event is InputEventMouseMotion:
		_mouse = get_local_mouse_position()
		queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed:
		_release(get_local_mouse_position())
		_drag = -1
		queue_redraw()
		get_viewport().set_input_as_handled()

func _release(pos: Vector2) -> void:
	# Inside the grid -> rearrange. Over the equipment panel -> equip. Anywhere else
	# outside the backpack (in any direction) -> drop into the world.
	if Rect2(Vector2.ZERO, _grid_size()).grow(CELL * 0.5).has_point(pos):
		var target := _drop_cell(pos)
		player.inv_move(_drag, target.x, target.y)
		return
	var gpos := get_global_mouse_position()
	if equip_panel != null and is_instance_valid(equip_panel) \
			and equip_panel.get_global_rect().has_point(gpos):
		# Dropped onto the equipment panel: target a specific gun slot if the cursor
		# is over one, else equip into the first natural/free slot.
		var gslot := -1
		if equip_panel.has_method("gun_slot_at_global"):
			gslot = equip_panel.gun_slot_at_global(gpos)
		player.equip_item(_drag, gslot)
		return
	# Outside the grid and the equip panel. Only actually drop into the world when the
	# cursor is beyond the whole inventory window; releasing anywhere else over the
	# window (tab bar, padding, hint text) snaps the item back to avoid fumbled drops.
	var win := _window_rect()
	if win.has_area() and win.has_point(gpos):
		return
	player.inv_drop(_drag)

## Global rect of the enclosing inventory window, or an empty rect if it can't be found
## (in which case there's no window guard and any release outside the grid drops).
func _window_rect() -> Rect2:
	var n: Node = get_parent()
	while n != null:
		if n is Control and n.name == "InventoryPanel":
			return (n as Control).get_global_rect()
		n = n.get_parent()
	return Rect2()

func _drop_cell(pos: Vector2) -> Vector2i:
	var top_left := pos - _grab_off
	return Vector2i(int(round(top_left.x / CELL)), int(round(top_left.y / CELL)))

func _draw() -> void:
	if player == null:
		return
	var gw: int = player.backpack_w
	var gh: int = player.backpack_h
	draw_rect(Rect2(Vector2.ZERO, _grid_size()), Color(0.08, 0.09, 0.12, 0.9), true)
	for x in gw + 1:
		draw_line(Vector2(x * CELL, 0), Vector2(x * CELL, gh * CELL), Color(1, 1, 1, 0.12), 1.0)
	for y in gh + 1:
		draw_line(Vector2(0, y * CELL), Vector2(gw * CELL, y * CELL), Color(1, 1, 1, 0.12), 1.0)

	var font := get_theme_default_font()
	var fs := 13
	for i in player.inventory.size():
		if i == _drag:
			continue
		var it: Dictionary = player.inventory[i]
		_draw_item(it, Vector2(int(it.get("gx", 0)) * CELL, int(it.get("gy", 0)) * CELL), 1.0, font, fs)

	if _drag >= 0 and _drag < player.inventory.size():
		var it: Dictionary = player.inventory[_drag]
		var target := _drop_cell(_mouse)
		var grid: Array = player._occupancy(gw, gh, _drag)
		var ok: bool = player._fits(target.x, target.y, int(it.get("w", 1)), int(it.get("h", 1)), grid, gw, gh)
		var hl := Color(0.3, 1.0, 0.4, 0.25) if ok else Color(1.0, 0.3, 0.3, 0.25)
		draw_rect(Rect2(Vector2(target.x * CELL, target.y * CELL),
			Vector2(int(it.get("w", 1)) * CELL, int(it.get("h", 1)) * CELL)), hl, true)
		_draw_item(it, _mouse - _grab_off, 0.85, font, fs)

func _draw_item(it: Dictionary, top_left: Vector2, alpha: float, font: Font, _fs: int) -> void:
	var w := int(it.get("w", 1))
	var h := int(it.get("h", 1))
	var rect := Rect2(top_left + Vector2(2, 2), Vector2(w * CELL - 4, h * CELL - 4))
	var col: Color = ItemDB.item_color(it)
	draw_rect(rect, Color(0.12, 0.13, 0.16, 0.85 * alpha), true)
	ItemIcon.draw(self, it, rect)
	col.a = alpha
	draw_rect(rect, col, false, 2.0)
	if font:
		# name on a dark strip along the bottom so it stays readable over the icon
		var strip := Rect2(rect.position + Vector2(0, rect.size.y - 14), Vector2(rect.size.x, 14))
		draw_rect(strip, Color(0, 0, 0, 0.5 * alpha), true)
		draw_string(font, rect.position + Vector2(3, rect.size.y - 3), String(it.get("name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 4, 10, Color(1, 1, 1, 0.9 * alpha))
