extends MapBase
## Linear compound with rooms and corridors — primary co-op mission map.
## Provides named zones used by missions: "alpha", "bravo", "extraction", "defend".

func build_level() -> void:
	add_floor(70, 50, "Dark", 9)

	var h := 5.0
	# Outer walls
	add_wall(Vector3(70, h, 1), Vector3(0, h * 0.5, -25), "Orange", 13)
	add_wall(Vector3(70, h, 1), Vector3(0, h * 0.5, 25), "Orange", 13)
	add_wall(Vector3(1, h, 50), Vector3(-35, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, 50), Vector3(35, h * 0.5, 0), "Orange", 13)

	# Interior dividers forming three zones with gaps to pass through
	add_wall(Vector3(1, h, 30), Vector3(-12, h * 0.5, -10), "Light", 13)
	add_wall(Vector3(1, h, 18), Vector3(12, h * 0.5, 8), "Light", 13)
	add_wall(Vector3(24, h, 1), Vector3(0, h * 0.5, -6), "Light", 13)

	# Cover clusters per room
	for c in [Vector3(-25, 0, 15), Vector3(-20, 0, 5), Vector3(-28, 0, -10)]:
		add_cover(c, "Green", 13)
	for c in [Vector3(0, 0, 12), Vector3(5, 0, 0), Vector3(-4, 0, 16)]:
		add_cover(c, "Green", 13)
	for c in [Vector3(24, 0, -14), Vector3(28, 0, 0), Vector3(20, 0, -18)]:
		add_cover(c, "Green", 13)

	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-26, 0, 10), 1.6)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(2, 0, 6), 1.6)
	add_crate("res://assets/models/weapons/crate-small.glb", Vector3(26, 0, -10), 1.6)

	# Player insertion (left room)
	for p in [Vector3(-30, 0, 18), Vector3(-28, 0, 20), Vector3(-32, 0, 16), Vector3(-30, 0, 14)]:
		add_spawn(p, false)

	# Enemy spawn points distributed across the middle and right rooms
	for e in [Vector3(0, 0, 18), Vector3(6, 0, -18), Vector3(-2, 0, -16),
			Vector3(26, 0, 14), Vector3(30, 0, -16), Vector3(22, 0, 4),
			Vector3(10, 0, 20), Vector3(18, 0, -10)]:
		add_spawn(e, true)

	# Pickups along the route
	add_pickup("health", Vector3(-26, 0, 16), 40)
	add_pickup("ammo", Vector3(0, 0, 10))
	add_pickup("grenade", Vector3(24, 0, -12))
	add_pickup("weapon", Vector3(26, 0, 2), 0, "sniper")
	add_pickup("health", Vector3(30, 0, 16), 40)

	# Objective zones
	add_zone("alpha", Vector3(0, 0.05, 12), Vector3(6, 4, 6))
	add_zone("bravo", Vector3(26, 0.05, 0), Vector3(6, 4, 6))
	add_zone("defend", Vector3(-28, 0.05, 18), Vector3(8, 4, 8))
	add_zone("extraction", Vector3(30, 0.05, 18), Vector3(6, 4, 6))
