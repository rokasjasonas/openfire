extends MapBase
## Procedurally-generated Survival terrain — fully deterministic from the run seed
## (so every co-op peer and every save rebuilds the identical world).
##
## Pipeline: seed FastNoiseLite -> heightmap (rolling hills) -> carve steep-banked
## lakes (the steep banks naturally fall off the navmesh, so NPCs can't path into
## water) -> flatten village/POI plots -> ArrayMesh with height-based biome vertex
## colours + a HeightMapShape3D collider -> water plane, scattered props, POI
## markers and spawns. Size + seed come from Game.config (set in the menu).

const STEP := 4.0          # grid spacing in metres
const AMP := 48.0          # hill amplitude

var _size: float = 640.0
var _water: float = 0.0
var _n: int = 0
var _heights: PackedFloat32Array = PackedFloat32Array()
var _sites: Array = []

func build_level() -> void:
	_size = _size_for(int(Game.config.get("map_size", 1)))
	var sd := int(Game.config.get("seed", 0))
	_water = AMP * 0.16
	_n = int(_size / STEP) + 1

	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	var noise := FastNoiseLite.new()
	noise.seed = sd
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.0035
	noise.fractal_octaves = 4

	# Coarser, size-scaled navmesh cells so the bake stays bounded on huge terrain.
	var cell := clampf(_size / 360.0, 1.0, 3.0)
	region.navigation_mesh.cell_size = cell      # coarse horizontal -> bounded bake
	region.navigation_mesh.cell_height = 0.3     # fine vertical so slopes stay walkable
	region.navigation_mesh.agent_max_slope = 48.0
	# Bake from static colliders (the heightmap shape, CPU-side) instead of the visual
	# ArrayMesh — the mesh path needs a GPU read-back that is empty in headless and
	# slow at runtime.
	region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	NavigationServer3D.map_set_cell_size(region.get_navigation_map(), cell)

	_sites = _pick_sites(rng, noise)

	# Build the heightmap once; reused by mesh + collision.
	_heights.resize(_n * _n)
	var half := (_n - 1) * STEP * 0.5
	for j in _n:
		for i in _n:
			_heights[j * _n + i] = _height(i * STEP - half, j * STEP - half, noise)

	_build_terrain_mesh()
	_build_collision()
	_add_water()
	_add_perimeter()
	_scatter_props(rng)
	_place_sites()

func _size_for(idx: int) -> float:
	match idx:
		0: return 384.0
		2: return 1024.0
		_: return 640.0

# ---------------------------------------------------------------- heightmap

func _base_height(wx: float, wz: float, noise: FastNoiseLite) -> float:
	return (noise.get_noise_2d(wx, wz) * 0.5 + 0.5) * AMP

func _height(wx: float, wz: float, noise: FastNoiseLite) -> float:
	var h := _base_height(wx, wz, noise)
	if h < _water:
		h = _water - STEP * 2.0   # steep lakebed -> banks exceed agent_max_slope
	for s in _sites:
		var d: float = Vector2(wx - s.x, wz - s.z).length()
		if d < s.r:
			var t := 1.0 - smoothstep(s.r * 0.55, s.r, d)  # 1 at centre, 0 at edge
			h = lerpf(h, s.h, t)
	return h

func _pick_sites(rng: RandomNumberGenerator, noise: FastNoiseLite) -> Array:
	var sites: Array = []
	var count := clampi(int(_size / 110.0), 5, 14)
	var span := _size * 0.40
	var attempts := 0
	while sites.size() < count and attempts < count * 40:
		attempts += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var ok := true
		for s in sites:
			if Vector2(x - s.x, z - s.z).length() < 72.0:
				ok = false
				break
		if not ok:
			continue
		var h := maxf(_water + 4.0, _base_height(x, z, noise))
		sites.append({"x": x, "z": z, "h": h, "r": rng.randf_range(20.0, 30.0)})
	return sites

# ---------------------------------------------------------------- mesh + collision

func _build_terrain_mesh() -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var normals := PackedVector3Array()
	verts.resize(_n * _n)
	colors.resize(_n * _n)
	normals.resize(_n * _n)
	var half := (_n - 1) * STEP * 0.5
	for j in _n:
		for i in _n:
			var idx := j * _n + i
			var h: float = _heights[idx]
			verts[idx] = Vector3(i * STEP - half, h, j * STEP - half)
			colors[idx] = _biome_color(h)
			var hl: float = _heights[j * _n + maxi(i - 1, 0)]
			var hr: float = _heights[j * _n + mini(i + 1, _n - 1)]
			var hd: float = _heights[maxi(j - 1, 0) * _n + i]
			var hu: float = _heights[mini(j + 1, _n - 1) * _n + i]
			normals[idx] = Vector3(hl - hr, 2.0 * STEP, hd - hu).normalized()

	var indices := PackedInt32Array()
	for j in _n - 1:
		for i in _n - 1:
			var v00 := j * _n + i
			var v10 := j * _n + i + 1
			var v01 := (j + 1) * _n + i
			var v11 := (j + 1) * _n + i + 1
			indices.append_array([v00, v01, v11, v00, v11, v10])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	region.add_child(mi)   # under the NavigationRegion so the navmesh bakes from it

func _biome_color(h: float) -> Color:
	if h <= _water + 0.3:
		return Color(0.18, 0.22, 0.28)   # lakebed (hidden under the water plane)
	var t := (h - _water) / maxf(AMP - _water, 1.0)
	if t < 0.06:
		return Color(0.80, 0.74, 0.5)    # sand
	elif t < 0.5:
		return Color(0.28, 0.52, 0.24)   # grass
	elif t < 0.78:
		return Color(0.44, 0.41, 0.39)   # rock
	return Color(0.92, 0.93, 0.96)       # snow

func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := HeightMapShape3D.new()
	shape.map_width = _n
	shape.map_depth = _n
	shape.map_data = _heights
	cs.shape = shape
	body.add_child(cs)
	body.scale = Vector3(STEP, 1.0, STEP)  # heightmap spans (n-1) units -> size metres
	region.add_child(body)   # under the region so the navmesh bakes from this collider

# ---------------------------------------------------------------- water / bounds / props

func _add_water() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.add_to_group("water")
	var pm := PlaneMesh.new()
	pm.size = Vector2(_size, _size)
	mi.mesh = pm
	mi.position.y = _water
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.4, 0.7, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.metallic = 0.2
	mat.roughness = 0.08
	mi.material_override = mat
	add_child(mi)   # not under the region, so it is never walkable

func _add_perimeter() -> void:
	var h := AMP + 30.0
	var t := 4.0
	var half := _size * 0.5
	add_wall(Vector3(_size, h, t), Vector3(0, h * 0.5 - 20.0, -half), "Dark", 13)
	add_wall(Vector3(_size, h, t), Vector3(0, h * 0.5 - 20.0, half), "Dark", 13)
	add_wall(Vector3(t, h, _size), Vector3(-half, h * 0.5 - 20.0, 0), "Dark", 13)
	add_wall(Vector3(t, h, _size), Vector3(half, h * 0.5 - 20.0, 0), "Dark", 13)

func _sample_height(wx: float, wz: float) -> float:
	var half := (_n - 1) * STEP * 0.5
	var i := clampi(int(round((wx + half) / STEP)), 0, _n - 1)
	var j := clampi(int(round((wz + half) / STEP)), 0, _n - 1)
	return _heights[j * _n + i]

func _scatter_props(rng: RandomNumberGenerator) -> void:
	var count := int(_size / 12.0)
	var span := _size * 0.46
	for k in count:
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		if h <= _water + 1.5:
			continue                       # no props in/near water
		var near_site := false
		for s in _sites:
			if Vector2(x - s.x, z - s.z).length() < s.r + 6.0:
				near_site = true
				break
		if near_site:
			continue
		if rng.randf() < 0.5:
			var rs := rng.randf_range(1.6, 3.6)
			add_box(Vector3(rs, rs * 0.8, rs), Vector3(x, h + rs * 0.3, z), "Dark", 6)
		else:
			var th := rng.randf_range(4.0, 7.0)
			add_box(Vector3(0.8, th, 0.8), Vector3(x, h + th * 0.5, z), "Orange", 5)
			add_box(Vector3(3.2, 3.0, 3.2), Vector3(x, h + th, z), "Green", 13)

func _place_sites() -> void:
	for k in _sites.size():
		var s: Dictionary = _sites[k]
		var marker := Node3D.new()
		marker.name = "POI_%d" % k
		marker.position = Vector3(s.x, s.h, s.z)
		marker.add_to_group("poi_site")
		marker.set_meta("radius", s.r)
		marker.set_meta("index", k)
		add_child(marker)
		# Faint beacon so village sites read from afar.
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.4
		cyl.bottom_radius = 0.4
		cyl.height = 22.0
		mi.mesh = cyl
		mi.position = Vector3(s.x, s.h + 11.0, s.z)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0.85, 0.3, 0.5)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(1, 0.8, 0.2)
		mi.material_override = mat
		add_child(mi)
		# Site 0 is the player start; the rest seed enemy spawns for now.
		var enemy := k != 0
		for a in 4:
			var ang := TAU * float(a) / 4.0
			add_spawn(Vector3(s.x + cos(ang) * 6.0, s.h + 0.5, s.z + sin(ang) * 6.0), enemy)
