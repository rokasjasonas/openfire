extends Control
## Player-centred top-down minimap. Rotates so the local player always faces up.
## Dots: self (white arrow), allies (team blue), enemies (red), control points
## (owner colour), vehicles (yellow), objective zones (cyan).

const RANGE := 60.0   # world metres shown from centre to edge
var _radius := 88.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	custom_minimum_size = Vector2(190, 190)
	position = Vector2(-206, 16)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)

func _process(_delta: float) -> void:
	queue_redraw()

func _local_player() -> Node3D:
	for p in get_tree().get_nodes_in_group("player"):
		if p.is_multiplayer_authority():
			return p
	return null

func _draw() -> void:
	var c := size * 0.5
	_radius = minf(size.x, size.y) * 0.5 - 4.0
	# Backdrop
	draw_circle(c, _radius, Color(0.05, 0.06, 0.08, 0.55))
	draw_arc(c, _radius, 0, TAU, 48, Color(0.5, 0.6, 0.7, 0.5), 1.5)

	var me := _local_player()
	if me == null:
		return
	var ppos: Vector3 = me.global_position
	var my_team: int = int(me.get("team"))
	var fwd := -me.global_transform.basis.z
	fwd = Vector3(fwd.x, 0, fwd.z).normalized()
	var right := Vector3(fwd.z, 0, -fwd.x)  # screen-right when facing up
	var scale := _radius / RANGE

	# Objective zones (reach/defend/etc.) + control points.
	for z in get_tree().get_nodes_in_group("zone"):
		_blip(c, z.global_position - ppos, fwd, right, scale, Color(0.3, 0.9, 1.0, 0.8), 2.5, true)
	for cp in get_tree().get_nodes_in_group("control_point"):
		var col := Game.team_color(cp.owner_team) if cp.get("owner_team") != null and cp.owner_team >= 0 else Color(0.7, 0.7, 0.7)
		_blip(c, cp.global_position - ppos, fwd, right, scale, col, 4.0, true)
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v.get("destroyed"):
			continue
		_blip(c, v.global_position - ppos, fwd, right, scale, Color(1, 0.9, 0.3), 2.5, false)
	# Co-op objective entities: destructible targets + the escort VIP.
	for t in get_tree().get_nodes_in_group("destructible"):
		if t.get("destroyed"):
			continue
		_blip(c, t.global_position - ppos, fwd, right, scale, Color(1, 0.3, 0.2), 4.0, true)
	for e in get_tree().get_nodes_in_group("escort"):
		_blip(c, e.global_position - ppos, fwd, right, scale, Color(0.4, 1.0, 0.55), 3.5, false)

	# Combatants.
	for cm in get_tree().get_nodes_in_group("combatant"):
		if cm == me or cm.get("dead") or cm.get("fully_dead"):
			continue
		var enemy := int(cm.get("team")) != my_team
		var col := Color(1, 0.35, 0.3) if enemy else Color(0.4, 0.7, 1.0)
		if cm.get("downed"):
			col = col.darkened(0.4)
		_blip(c, cm.global_position - ppos, fwd, right, scale, col, 3.0, false)

	# Self (arrow pointing up).
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -7), c + Vector2(-5, 5), c + Vector2(5, 5)]),
		Color(1, 1, 1, 0.95))

func _blip(c: Vector2, rel: Vector3, fwd: Vector3, right: Vector3, scale: float, col: Color, r: float, square: bool) -> void:
	var lx := rel.dot(right)
	var lz := rel.dot(fwd)
	var p := Vector2(lx, -lz) * scale
	if p.length() > _radius - 2.0:
		p = p.normalized() * (_radius - 2.0)  # clamp to edge
		col.a *= 0.6
	var sp := c + p
	if square:
		draw_rect(Rect2(sp - Vector2(r, r), Vector2(r * 2, r * 2)), col, true)
	else:
		draw_circle(sp, r, col)
