extends MapBase
## Tight close-quarters map: a grid of crate-stack pillars forming aisles. Favours
## SMG/shotgun play. Flat, so good for deathmatch / team deathmatch.

func build_level() -> void:
	var s := 50.0
	add_floor(s, s, "Dark", 8)

	var h := 6.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Grid of tall crate-stack pillars in a checker pattern -> aisles between them.
	for gx in range(-2, 3):
		for gz in range(-2, 3):
			if (gx + gz) % 2 == 0:
				add_box(Vector3(4, 4, 4), Vector3(gx * 9.0, 2, gz * 9.0), "Light", 13)

	# Low cover + decorative crates in the open aisles.
	for c in [Vector3(-4, 0, 0), Vector3(4, 0, 0), Vector3(0, 0, -9), Vector3(0, 0, 9)]:
		add_cover(c, "Green", 13)
	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-9, 0, 4), 1.6)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(9, 0, -4), 1.6)
	add_crate("res://assets/models/weapons/crate-small.glb", Vector3(4, 0, 9), 1.6)

	# Spawns around the edges.
	var pts := [
		Vector3(-20, 0, -20), Vector3(20, 0, 20), Vector3(-20, 0, 20), Vector3(20, 0, -20),
		Vector3(0, 0, -21), Vector3(0, 0, 21), Vector3(-21, 0, 0), Vector3(21, 0, 0),
	]
	for i in pts.size():
		add_spawn(pts[i], i % 2 == 0)

	# Pickups
	add_pickup("weapon", Vector3(0, 0, 0), 0, "shotgun")
	add_pickup("health", Vector3(-18, 0, 0), 40)
	add_pickup("health", Vector3(18, 0, 0), 40)
	add_pickup("ammo", Vector3(0, 0, -18))
	add_pickup("grenade", Vector3(0, 0, 18))
