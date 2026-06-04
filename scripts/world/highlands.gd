extends MapBase
## Vertical map: a central stepped ziggurat plus raised corner platforms and
## ramps, giving multiple elevations and sightlines (the opposite of the flat
## arena). Works for deathmatch and for missions that don't need named zones.

func build_level() -> void:
	var s := 60.0
	add_floor(s, s, "Dark", 10)

	var h := 7.0
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, -s * 0.5), "Orange", 13)
	add_wall(Vector3(s, h, 1), Vector3(0, h * 0.5, s * 0.5), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(-s * 0.5, h * 0.5, 0), "Orange", 13)
	add_wall(Vector3(1, h, s), Vector3(s * 0.5, h * 0.5, 0), "Orange", 13)

	# Central stepped ziggurat (three tiers): tops at y = 2, 4, 6.
	add_box(Vector3(20, 2, 20), Vector3(0, 1, 0), "Purple", 13)   # tier 1, edge +/-10
	add_box(Vector3(13, 2, 13), Vector3(0, 3, 0), "Purple", 13)   # tier 2, edge +/-6.5
	add_box(Vector3(7, 2, 7), Vector3(0, 5, 0), "Light", 13)      # tier 3, edge +/-3.5

	# Ramps winding up the tiers (each on a different side).
	add_slope(Vector3(0, 0, 16), Vector3(0, 2, 9), 5.0)     # floor -> tier 1 (south)
	add_slope(Vector3(9, 2, 0), Vector3(5, 4, 0), 4.0)      # tier 1 -> tier 2 (east)
	add_slope(Vector3(0, 4, -6), Vector3(0, 6, -2.5), 3.5)  # tier 2 -> tier 3 (north)

	# Raised corner platforms (top y = 3) as vantage points, with ramps.
	add_box(Vector3(10, 3, 10), Vector3(-20, 1.5, -20), "Light", 13)
	add_box(Vector3(10, 3, 10), Vector3(20, 1.5, 20), "Light", 13)
	add_slope(Vector3(-20, 0, -10), Vector3(-20, 3, -15.5), 4.0)
	add_slope(Vector3(20, 0, 10), Vector3(20, 3, 15.5), 4.0)

	# Floor cover + crates.
	for c in [Vector3(-16, 0, 8), Vector3(16, 0, -8), Vector3(-8, 0, -18), Vector3(8, 0, 18)]:
		add_cover(c, "Green", 13)
	add_crate("res://assets/models/weapons/crate-medium.glb", Vector3(-14, 0, -6), 1.6)
	add_crate("res://assets/models/weapons/crate-wide.glb", Vector3(13, 0, 6), 1.6)

	# Spawns spread across the floor and up on the platforms / ziggurat.
	var floor_spawns := [
		Vector3(-24, 0, 0), Vector3(24, 0, 0), Vector3(0, 0, -24), Vector3(0, 0, 24),
		Vector3(-22, 0, 22), Vector3(22, 0, -22),
	]
	for i in floor_spawns.size():
		add_spawn(floor_spawns[i], i % 2 == 0)
	add_spawn(Vector3(-20, 3.1, -20), true)   # corner platform
	add_spawn(Vector3(20, 3.1, 20), false)    # corner platform
	add_spawn(Vector3(0, 6.1, 0), true)       # ziggurat summit
