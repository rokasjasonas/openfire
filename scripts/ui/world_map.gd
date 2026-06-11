extends Control
## Full-screen Adventure world map (toggled with M). Shows the baked terrain image
## with villages, active quest objectives, and players overlaid. View-only.

var _map_node: Node = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()

func _find_map() -> Node:
	if _map_node != null and is_instance_valid(_map_node):
		return _map_node
	for m in get_tree().get_nodes_in_group("map"):
		if m.has_method("map_texture"):
			_map_node = m
			return m
	return null

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.06, 0.92), true)
	var map := _find_map()
	if map == null or map.map_texture() == null:
		var f := get_theme_default_font()
		if f:
			draw_string(f, size * 0.5 + Vector2(-60, 0), "No map available", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, 0.6))
		return
	var tex: Texture2D = map.map_texture()
	var ws: float = map.world_size()
	# Contain-fit the square world image with a margin.
	var s: float = minf(size.x, size.y) - 60.0
	var origin := (size - Vector2(s, s)) * 0.5
	draw_texture_rect(tex, Rect2(origin, Vector2(s, s)), false)
	draw_rect(Rect2(origin, Vector2(s, s)), Color(1, 1, 1, 0.25), false, 1.0)

	var to_screen := func(world: Vector3) -> Vector2:
		return origin + (Vector2(world.x, world.z) / ws + Vector2(0.5, 0.5)) * s

	var font := get_theme_default_font()
	# Villages.
	for poi in get_tree().get_nodes_in_group("poi_site"):
		var sp: Vector2 = to_screen.call(poi.global_position)
		draw_rect(Rect2(sp - Vector2(3, 3), Vector2(6, 6)), Color(0.85, 0.75, 0.35), true)
	# Active quest objectives (host only — clients see villages + themselves).
	var qm := get_tree().get_first_node_in_group("quest_manager")
	if qm != null:
		for q in qm.quests:
			if q.get("state", "") != "active":
				continue
			for key in ["poi", "dest"]:
				if q.has(key) and is_instance_valid(q.get(key)):
					var sp2: Vector2 = to_screen.call((q.get(key) as Node3D).global_position)
					draw_arc(sp2, 8.0, 0, TAU, 20, Color(1.0, 0.85, 0.3), 2.0)
					if font:
						draw_string(font, sp2 + Vector2(10, 4), String(q.get("title", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.9, 0.5))
	# Players (you = white triangle pointing your way; allies = blue dots).
	for p in get_tree().get_nodes_in_group("player"):
		if p.get("dead") or p.get("fully_dead"):
			continue
		var sp3: Vector2 = to_screen.call(p.global_position)
		if p.is_multiplayer_authority():
			var fwd: Vector3 = -p.global_transform.basis.z
			var dir := Vector2(fwd.x, fwd.z).normalized()
			var side := Vector2(-dir.y, dir.x)
			draw_colored_polygon(PackedVector2Array([sp3 + dir * 9.0, sp3 - dir * 4.0 + side * 5.0, sp3 - dir * 4.0 - side * 5.0]), Color(1, 1, 1))
		else:
			draw_circle(sp3, 4.0, Color(0.4, 0.7, 1.0))
	if font:
		draw_string(font, origin + Vector2(0, -10), "WORLD MAP   [M] close", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.7))
