extends MapBase
## Huge open map: scattered buildings, raised mesas and lots of ground to cover —
## built for vehicles. Bots fight on foot; the navmesh spans the whole field.

func build_level() -> void:
	var s := 130.0
	add_floor(s, s, "Dark", 9)

	var h := 8.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Buildings (points of interest)
	add_building(Vector3(-30, 0, -30), 16, 14, 4.5, "east", "Light", 13)
	add_building(Vector3(35, 0, -28), 16, 14, 4.5, "west", "Light", 13)
	add_building(Vector3(0, 0, 32), 18, 16, 5.0, "south", "Light", 13)
	add_building(Vector3(-42, 0, 28), 14, 12, 4.0, "north", "Light", 13)

	# Raised mesas with ramps (vantage / cover)
	add_box(Vector3(20, 3, 20), Vector3(42, 1.5, 42), "Purple", 13)
	add_slope(Vector3(42, 0, 28), Vector3(42, 3, 33), 5.0)
	add_box(Vector3(16, 2.5, 16), Vector3(-46, 1.25, -46), "Purple", 13)
	add_slope(Vector3(-46, 0, -36), Vector3(-46, 2.5, -40), 5.0)

	# Scattered cover across the field
	var cover := [
		Vector3(-10, 0, 10), Vector3(12, 0, -8), Vector3(0, 0, 0), Vector3(20, 0, 20),
		Vector3(-20, 0, -8), Vector3(8, 0, 22), Vector3(-32, 0, 6), Vector3(28, 0, -42),
		Vector3(-12, 0, -40), Vector3(48, 0, -10), Vector3(-50, 0, 8), Vector3(18, 0, 48),
	]
	for c in cover:
		add_cover(c, "Green", 13)
	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-8, 0, -8), 1.8)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(10, 0, 10), 1.8)

	# Vehicles
	add_vehicle(Vector3(-12, 0, -12), 30)
	add_vehicle(Vector3(14, 0, 6), 120)
	add_vehicle(Vector3(2, 0, -38), 200)
	add_vehicle(Vector3(-38, 0, 38), 320)

	# Spawns spread far apart
	var pts := [
		Vector3(-55, 0, -55), Vector3(55, 0, 55), Vector3(-55, 0, 55), Vector3(55, 0, -55),
		Vector3(0, 0, -58), Vector3(0, 0, 58), Vector3(-58, 0, 0), Vector3(58, 0, 0),
	]
	for i in pts.size():
		add_spawn(pts[i], i % 2 == 0)

	# Pickups
	add_pickup("weapon", Vector3(42, 3.1, 42), 0, "sniper")  # mesa top
	add_pickup("health", Vector3(-30, 0, -30), 40)
	add_pickup("health", Vector3(35, 0, -28), 40)
	add_pickup("ammo", Vector3(0, 0, 32))
	add_pickup("grenade", Vector3(-42, 0, 28))
	add_pickup("weapon", Vector3(0, 0, 0), 0, "shotgun")
