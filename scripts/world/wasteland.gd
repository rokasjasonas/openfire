extends MapBase
## "Wasteland" — a massive 440x440 open map (~100x the Arena's footprint), built for
## Battle Royale. Clusters of building compounds, rock formations, long sightlines,
## widely-scattered vehicles/helicopters and loot in every quadrant. Bots fight on
## foot. The navmesh uses coarser 0.5 m cells so the enormous floor bakes quickly.

const VALID_WEAPONS := ["shotgun", "sniper", "smg"]

func build_level() -> void:
	# Coarsen BOTH the baked navmesh and the navigation map so they stay matched
	# (mismatched cell sizes break polygon merging) yet bake fast on a huge floor.
	region.navigation_mesh.cell_size = 0.5
	region.navigation_mesh.cell_height = 0.5
	NavigationServer3D.map_set_cell_size(region.get_navigation_map(), 0.5)

	var s := 440.0
	add_floor(s, s, "Dark", 10)

	var h := 12.0
	add_wall(Vector3(s, h, 2), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 2), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(2, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(2, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Central raised fort with an overwatch sniper perch.
	add_box(Vector3(40, 3, 40), Vector3(0, 1.5, 0), "Purple", 13)
	add_building(Vector3(0, 3, 0), 22, 22, 6.0, "south", "Light", 13)
	add_slope(Vector3(0, 0, 26), Vector3(0, 3, 18), 8.0)
	add_pickup("weapon", Vector3(0, 3.3, 0), 0, "sniper")

	# Ring of building compounds in every direction.
	var compounds := [
		Vector3(-120, 0, -120), Vector3(120, 0, 120), Vector3(-120, 0, 120), Vector3(120, 0, -120),
		Vector3(0, 0, -150), Vector3(0, 0, 150), Vector3(-150, 0, 0), Vector3(150, 0, 0),
	]
	var doors := ["south", "north", "east", "west", "south", "north", "east", "west"]
	for i in compounds.size():
		_compound(compounds[i], doors[i], i)

	# Rock-formation clusters as cover / landmarks across the open ground.
	var rocks := [
		Vector3(-60, 0, -30), Vector3(70, 0, 40), Vector3(-40, 0, 80), Vector3(80, 0, -70),
		Vector3(-90, 0, 60), Vector3(50, 0, -120), Vector3(-70, 0, -90), Vector3(100, 0, 20),
		Vector3(30, 0, 110), Vector3(-30, 0, -160), Vector3(170, 0, -40), Vector3(-170, 0, 50),
	]
	for r in rocks:
		add_box(Vector3(7, 5, 7), r + Vector3(0, 2.5, 0), "Dark", 6)
		add_box(Vector3(4, 3, 4), r + Vector3(4, 1.5, 3), "Dark", 6)
		add_cover(r + Vector3(-4, 0, -3), "Green", 13)

	# Scattered low cover on a coarse grid (skip the centre + the perimeter).
	for gx in range(-7, 8):
		for gz in range(-7, 8):
			if (gx + gz) % 3 != 0:
				continue
			var p := Vector3(gx * 28.0, 0, gz * 28.0)
			if p.length() < 32.0 or absf(p.x) > 200.0 or absf(p.z) > 200.0:
				continue
			add_cover(p, "Green", 13)

	# Vehicles + helicopters spread widely (you'll want wheels on a map this big).
	var cars := [
		Vector3(-50, 0, 50), Vector3(50, 0, -50), Vector3(-110, 0, -40), Vector3(110, 0, 40),
		Vector3(-40, 0, 140), Vector3(40, 0, -140), Vector3(150, 0, -110), Vector3(-150, 0, 110),
	]
	for i in cars.size():
		add_vehicle(cars[i], i * 45)
	add_helicopter(Vector3(-80, 0, 0), 0)
	add_helicopter(Vector3(80, 0, 0), 180)
	add_helicopter(Vector3(0, 0, 90), 90)

	# Spawn ring, clear of the compounds and inside the storm's opening radius.
	var n := 20
	for i in n:
		var ang := TAU * float(i) / float(n)
		var rad := 165.0 + (30.0 if i % 2 == 0 else 0.0)  # 165 / 195
		add_spawn(Vector3(cos(ang) * rad, 0, sin(ang) * rad), i % 2 == 0)

	# Loot in every quadrant.
	var loot := ["health", "ammo", "grenade", "weapon"]
	var idx := 0
	for gx in range(-6, 7):
		for gz in range(-6, 7):
			if (gx * 3 + gz) % 4 != 0:
				continue
			var p := Vector3(gx * 32.0, 0, gz * 32.0)
			if p.length() < 26.0 or absf(p.x) > 200.0 or absf(p.z) > 200.0:
				continue
			var kind: String = loot[idx % loot.size()]
			idx += 1
			if kind == "weapon":
				add_pickup("weapon", p, 0, VALID_WEAPONS[idx % VALID_WEAPONS.size()])
			else:
				add_pickup(kind, p, 40 if kind == "health" else 25)

func _compound(center: Vector3, door: String, _seed: int) -> void:
	add_building(center, 16, 14, 5.0, door, "Light", 13)
	add_building(center + Vector3(22, 0, 8), 12, 12, 4.0, "south", "Light", 13)
	add_cover(center + Vector3(-9, 0, 9), "Green", 13)
	add_crate("res://assets/models/weapons/crate-medium.glb", center + Vector3(9, 0, -9), 1.8)
	add_pickup("health", center, 40)
	add_pickup("ammo", center + Vector3(22, 0, 8))
