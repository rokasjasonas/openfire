extends MapBase
## A walled compound of enclosed buildings (each with a doorway and a roof) around
## a central plaza. Interiors are navigable; one building's roof is reachable by a
## ramp for a vantage point. Mixed CQB + sightlines; good for all modes.

func build_level() -> void:
	var s := 64.0
	add_floor(s, s, "Dark", 9)

	var h := 7.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Four corner buildings, doorways facing the central plaza.
	add_building(Vector3(-18, 0, -18), 14, 12, 4.0, "east", "Light", 13)
	add_building(Vector3(18, 0, -18), 14, 12, 4.0, "west", "Light", 13)
	add_building(Vector3(-18, 0, 18), 14, 12, 4.0, "north", "Light", 13)
	add_building(Vector3(18, 0, 18), 14, 12, 4.0, "south", "Light", 13)

	# Central building (taller) with a ramp up to its roof for an overwatch spot.
	add_building(Vector3(0, 0, 0), 12, 12, 5.0, "south", "Purple", 13)
	add_slope(Vector3(8.5, 0, 6), Vector3(6.5, 5.2, 6), 3.0)   # ground -> central roof

	# Street cover + crates between the buildings.
	for c in [Vector3(0, 0, -20), Vector3(0, 0, 20), Vector3(-20, 0, 0), Vector3(20, 0, 0)]:
		add_cover(c, "Green", 13)
	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-8, 0, -8), 1.6)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(8, 0, 8), 1.6)
	add_crate("res://assets/models/weapons/crate-small.glb", Vector3(-9, 0, 10), 1.6)

	# Spawns: street corners + inside a couple of buildings.
	var pts := [
		Vector3(-26, 0, -26), Vector3(26, 0, 26), Vector3(-26, 0, 26), Vector3(26, 0, -26),
		Vector3(0, 0, -27), Vector3(0, 0, 27),
		Vector3(-18, 0, -18), Vector3(18, 0, 18),
	]
	for i in pts.size():
		add_spawn(pts[i], i % 2 == 0)

	# Pickups — sniper on the reachable central roof, gear in the buildings.
	add_pickup("weapon", Vector3(0, 5.4, 0), 0, "sniper")
	add_pickup("health", Vector3(-18, 0, -18), 40)
	add_pickup("health", Vector3(18, 0, 18), 40)
	add_pickup("ammo", Vector3(-18, 0, 18))
	add_pickup("grenade", Vector3(18, 0, -18))
	add_pickup("weapon", Vector3(0, 0, 18), 0, "shotgun")

	# Domination control points
	add_control_point("A", Vector3(0, 0, 0))       # central plaza
	add_control_point("B", Vector3(-18, 0, -18))
	add_control_point("C", Vector3(18, 0, 18))
