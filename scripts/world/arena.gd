extends MapBase
## Symmetrical bounded arena — primary deathmatch map (also usable for co-op).

func build_level() -> void:
	var s := 44.0
	add_floor(s, s, "Dark", 13)

	# Perimeter walls
	var h := 5.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Central raised platform with ramps
	add_box(Vector3(10, 2, 10), Vector3(0, 1, 0), "Purple", 13)
	add_ramp(Vector3(4, 0.5, 6), Vector3(0, 1.0, 8), -22, "Purple", 13)
	add_ramp(Vector3(4, 0.5, 6), Vector3(0, 1.0, -8), 22, "Purple", 13)

	# Scattered cover
	var cover_spots := [
		Vector3(-12, 0, -12), Vector3(12, 0, -12), Vector3(-12, 0, 12), Vector3(12, 0, 12),
		Vector3(-16, 0, 0), Vector3(16, 0, 0), Vector3(0, 0, -16), Vector3(0, 0, 16),
		Vector3(-7, 0, 6), Vector3(7, 0, -6),
	]
	for c in cover_spots:
		add_cover(c, "Green", 13)

	# Decorative crates
	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-10, 0, 8), 1.6)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(9, 0, 9), 1.6)
	add_crate("res://assets/models/weapons/crate-small.glb", Vector3(14, 0, -3), 1.6)

	# Spawns around the ring (used for both teams / FFA)
	var ring := [
		Vector3(-18, 0, -18), Vector3(18, 0, -18), Vector3(-18, 0, 18), Vector3(18, 0, 18),
		Vector3(0, 0, -19), Vector3(0, 0, 19), Vector3(-19, 0, 0), Vector3(19, 0, 0),
	]
	# Alternate player / enemy spawns around the ring so they sit at distinct points.
	for i in ring.size():
		add_spawn(ring[i], i % 2 == 0)

	# Pickups
	add_pickup("weapon", Vector3(0, 2.1, 0), 0, "sniper")   # central platform top
	add_pickup("health", Vector3(0, 0, 16), 40)
	add_pickup("health", Vector3(0, 0, -16), 40)
	add_pickup("grenade", Vector3(-16, 0, 16))
	add_pickup("grenade", Vector3(16, 0, -16))
	add_pickup("ammo", Vector3(-16, 0, 0))
	add_pickup("ammo", Vector3(16, 0, 0))
	add_pickup("weapon", Vector3(-12, 0, -12), 0, "shotgun")
