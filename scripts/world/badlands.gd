extends MapBase
## Huge open badlands: rock-formation clusters, a central fort and long lanes —
## built for vehicles. Bots fight on foot.

func build_level() -> void:
	var s := 140.0
	add_floor(s, s, "Dark", 10)

	var h := 8.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Central fort: a building on a raised platform with a ramp.
	add_box(Vector3(24, 2, 24), Vector3(0, 1, 0), "Purple", 13)
	add_building(Vector3(0, 2, 0), 16, 16, 5.0, "south", "Light", 13)
	add_slope(Vector3(0, 0, 16), Vector3(0, 2, 11), 6.0)

	# Rock-formation clusters (stacked boxes) scattered as cover/landmarks.
	var rocks := [
		Vector3(-40, 0, -20), Vector3(38, 0, 24), Vector3(-24, 0, 40), Vector3(44, 0, -36),
		Vector3(-50, 0, 30), Vector3(20, 0, -48), Vector3(-30, 0, -44), Vector3(50, 0, 8),
	]
	for r in rocks:
		add_box(Vector3(5, 4, 5), r + Vector3(0, 2, 0), "Dark", 6)
		add_box(Vector3(3, 2.5, 3), r + Vector3(3, 1.25, 2), "Dark", 6)
		add_cover(r + Vector3(-3, 0, -2), "Green", 13)

	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-14, 0, 10), 1.8)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(16, 0, -12), 1.8)

	# Vehicles
	add_vehicle(Vector3(-16, 0, 16), 45)
	add_vehicle(Vector3(18, 0, -14), 200)
	add_vehicle(Vector3(-40, 0, -16), 90)
	add_vehicle(Vector3(40, 0, 20), 270)

	var pts := [
		Vector3(-60, 0, -60), Vector3(60, 0, 60), Vector3(-60, 0, 60), Vector3(60, 0, -60),
		Vector3(0, 0, -62), Vector3(0, 0, 62), Vector3(-62, 0, 0), Vector3(62, 0, 0),
	]
	for i in pts.size():
		add_spawn(pts[i], i % 2 == 0)

	add_pickup("weapon", Vector3(0, 2.1, 0), 0, "sniper")  # inside the fort
	add_pickup("health", Vector3(-40, 0, -20), 40)
	add_pickup("health", Vector3(38, 0, 24), 40)
	add_pickup("ammo", Vector3(-24, 0, 40))
	add_pickup("grenade", Vector3(44, 0, -36))
