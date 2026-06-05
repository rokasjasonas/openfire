extends MapBase
## Open ruins: a raised central platform with ramps, broken wall segments for
## cover, and sightlines across the field. Good for all modes.

func build_level() -> void:
	var s := 56.0
	add_floor(s, s, "Dark", 10)

	var h := 6.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Central raised platform with ramps on two sides.
	add_box(Vector3(14, 2.5, 14), Vector3(0, 1.25, 0), "Purple", 13)
	add_slope(Vector3(0, 0, 15), Vector3(0, 2.5, 8), 5.0)
	add_slope(Vector3(0, 0, -15), Vector3(0, 2.5, -8), 5.0)

	# Broken wall segments scattered as cover (partial walls with gaps).
	add_wall(Vector3(9, 3, 1), Vector3(-16, 1.5, 8), "Light", 13)
	add_wall(Vector3(1, 3, 9), Vector3(-10, 1.5, -14), "Light", 13)
	add_wall(Vector3(9, 3, 1), Vector3(16, 1.5, -8), "Light", 13)
	add_wall(Vector3(1, 3, 9), Vector3(12, 1.5, 14), "Light", 13)
	add_wall(Vector3(7, 3, 1), Vector3(-18, 1.5, -10), "Light", 13)

	for c in [Vector3(-8, 0, 0), Vector3(8, 0, 0), Vector3(0, 0, 20), Vector3(0, 0, -20), Vector3(-20, 0, 18), Vector3(20, 0, -18)]:
		add_cover(c, "Green", 13)
	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-14, 0, -4), 1.6)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(14, 0, 4), 1.6)

	var pts := [
		Vector3(-22, 0, -22), Vector3(22, 0, 22), Vector3(-22, 0, 22), Vector3(22, 0, -22),
		Vector3(0, 0, -24), Vector3(0, 0, 24), Vector3(-24, 0, 0), Vector3(24, 0, 0),
	]
	for i in pts.size():
		add_spawn(pts[i], i % 2 == 0)

	# Pickups (sniper rewards holding the centre platform)
	add_pickup("weapon", Vector3(0, 2.6, 0), 0, "sniper")
	add_pickup("health", Vector3(-20, 0, 6), 40)
	add_pickup("health", Vector3(20, 0, -6), 40)
	add_pickup("ammo", Vector3(-6, 0, -16))
	add_pickup("grenade", Vector3(6, 0, 16))
