extends Control
## Spatial drag-and-drop backpack grid. Renders the player's inventory as a grid of
## cells with multi-cell item footprints. Drag an item to rearrange it, drag it out
## of the grid to drop it into the world, double-click to use/equip. Talks to
## Player.inv_move / inv_use / inv_drop. Fixed item orientation (no rotation).

const CELL := 50.0

var player: Node = null
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
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				var di := _item_at(event.position)
				if di >= 0:
					player.inv_use(di)
				_drag = -1
				return
			_drag = _item_at(event.position)
			if _drag >= 0:
				var it: Dictionary = player.inventory[_drag]
				_grab_off = event.position - Vector2(int(it.get("gx", 0)) * CELL, int(it.get("gy", 0)) * CELL)
			queue_redraw()
		else:
			if _drag >= 0:
				_release(event.position)
			_drag = -1
			queue_redraw()
	elif event is InputEventMouseMotion:
		_mouse = event.position
		if _drag >= 0:
			queue_redraw()

func _release(pos: Vector2) -> void:
	# Released outside the grid -> drop into the world; otherwise move (if it fits).
	if not Rect2(Vector2.ZERO, _grid_size()).grow(CELL * 0.5).has_point(pos):
		player.inv_drop(_drag)
		return
	var target := _drop_cell(pos)
	player.inv_move(_drag, target.x, target.y)

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

func _draw_item(it: Dictionary, top_left: Vector2, alpha: float, font: Font, fs: int) -> void:
	var w := int(it.get("w", 1))
	var h := int(it.get("h", 1))
	var rect := Rect2(top_left + Vector2(2, 2), Vector2(w * CELL - 4, h * CELL - 4))
	var col: Color = ItemDB.color_for(String(it.get("kind", "")))
	var fill := col
	fill.a = 0.5 * alpha
	draw_rect(rect, fill, true)
	col.a = alpha
	draw_rect(rect, col, false, 2.0)
	if font:
		draw_string(font, top_left + Vector2(6, 18), String(it.get("name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, w * CELL - 8, fs, Color(1, 1, 1, alpha))
