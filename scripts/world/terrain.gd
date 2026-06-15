extends MapBase
## Procedurally-generated Survival terrain — fully deterministic from the run seed
## (so every co-op peer and every save rebuilds the identical world).
##
## Pipeline: seeded noise fields -> a layered, domain-warped heightmap (continental
## base + ridged mountain ranges + hills + detail, with an island edge-falloff so the
## world is ringed by sea) -> steep-banked water (the banks fall off the navmesh, so
## NPCs can't path into water) -> flatten village/POI plots -> ArrayMesh with
## climate-biome vertex colours (temperature/moisture choose desert/grassland/forest/
## tundra/alpine/snow, plus beaches and slope-driven cliffs) + a HeightMapShape3D
## collider -> water, biome-aware vegetation & boulders, village buildings, cave
## shelters, POI markers and spawns. Size + seed come from Game.config.

const STEP := 4.0          # grid spacing in metres

# Relief tuning (dramatic): land spans roughly [_water .. ~165 m] with sea below.
const SEA_FLOOR := -16.0
const PLAIN_HI := 42.0     # continental base ceiling (plains/foothills)
const HILL_AMP := 16.0
const MOUNTAIN_AMP := 122.0
const DETAIL_AMP := 2.6
const WARP_AMP := 55.0
const SNOWLINE := 104.0
const ALPINE := 74.0       # bare-rock highlands start here

var _size: float = 640.0
var _water: float = 6.0
var _n: int = 0
var _heights: PackedFloat32Array = PackedFloat32Array()
var _sites: Array = []
# Climate derived deterministically from the story theme — biases biomes, snowline,
# water level, vegetation and palette so the map reflects the prompt.
var _climate: Dictionary = {}

# Seeded noise fields (created in _make_noise).
var _nc: FastNoiseLite       # continentalness (very low freq)
var _nm: FastNoiseLite       # mountains (ridged via abs)
var _nh: FastNoiseLite       # hills
var _nd: FastNoiseLite       # fine detail + colour variation
var _nwx: FastNoiseLite      # domain-warp X
var _nwz: FastNoiseLite      # domain-warp Z
var _ntemp: FastNoiseLite    # temperature (biomes)
var _nmoist: FastNoiseLite   # moisture (biomes)
var _nforest: FastNoiseLite  # forest density

var _seed: int = 0

func build_level() -> void:
	_size = _size_for(int(Game.config.get("map_size", 1)))
	var sd := int(Game.config.get("seed", 0))
	_seed = sd
	_n = int(_size / STEP) + 1

	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	_make_noise(sd)
	_climate = _theme_climate(String(Game.config.get("theme", "")))
	_water = 6.0 + float(_climate.get("water", 0.0))
	# Expose the resolved climate for world systems (weather, ambience).
	for key in CLIMATES:
		if CLIMATES[key] == _climate:
			set_meta("climate_key", key)
			break

	# Coarser, size-scaled navmesh cells so the bake stays bounded on huge terrain.
	var cell := clampf(_size / 360.0, 1.0, 3.0)
	region.navigation_mesh.cell_size = cell      # coarse horizontal -> bounded bake
	region.navigation_mesh.cell_height = 0.3     # fine vertical so slopes stay walkable
	region.navigation_mesh.agent_max_slope = 48.0
	region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	NavigationServer3D.map_set_cell_size(region.get_navigation_map(), cell)

	_sites = _pick_sites(rng)

	# Build the heightmap once; reused by mesh + collision.
	_heights.resize(_n * _n)
	var half := (_n - 1) * STEP * 0.5
	for j in _n:
		for i in _n:
			_heights[j * _n + i] = _height(i * STEP - half, j * STEP - half)

	_build_terrain_mesh()
	_build_collision()
	_bake_map_image()
	_add_water()
	_add_perimeter()
	_scatter_vegetation(rng)
	_scatter_loot(rng)
	_build_villages(rng)
	_build_watchtowers(rng)
	_add_caves(rng)
	_maybe_tunnels(rng)
	_place_sites()
	# Vehicles are placed in post_bake() (after the navmesh bake) so their tops never
	# become walkable / a snap target — otherwise bots end up standing on them.

func _size_for(idx: int) -> float:
	match idx:
		0: return 224.0    # tiny
		1: return 384.0    # small
		3: return 1024.0   # large
		_: return 640.0    # medium

func _make_noise(sd: int) -> void:
	_nc = _mk(sd, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.00085, 2)
	_nm = _mk(sd + 101, FastNoiseLite.TYPE_SIMPLEX, 0.0022, 4)
	_nh = _mk(sd + 202, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.006, 3)
	_nd = _mk(sd + 303, FastNoiseLite.TYPE_SIMPLEX, 0.02, 2)
	_nwx = _mk(sd + 404, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0016, 2)
	_nwz = _mk(sd + 505, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0016, 2)
	_ntemp = _mk(sd + 606, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0011, 2)
	_nmoist = _mk(sd + 707, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0014, 2)
	_nforest = _mk(sd + 808, FastNoiseLite.TYPE_SIMPLEX, 0.012, 3)

func _mk(sd: int, type: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = sd
	n.noise_type = type
	n.frequency = freq
	n.fractal_octaves = octaves
	return n

# ---------------------------------------------------------------- heightmap

## Distort sample coordinates so features aren't grid-aligned (domain warping).
func _warp(wx: float, wz: float) -> Vector2:
	return Vector2(
		wx + _nwx.get_noise_2d(wx, wz) * WARP_AMP,
		wz + _nwz.get_noise_2d(wx, wz) * WARP_AMP)

## Raw land elevation before lake-carving and village flattening.
func _land_height(wx: float, wz: float) -> float:
	var w := _warp(wx, wz)
	var cont01: float = _nc.get_noise_2d(w.x, w.y) * 0.5 + 0.5          # 0..1
	var base := SEA_FLOOR + cont01 * (PLAIN_HI - SEA_FLOOR)             # sea .. foothills
	var land_mask := smoothstep(0.34, 0.50, cont01)                    # 0 sea .. 1 land
	var hills := (_nh.get_noise_2d(w.x, w.y) * 0.5 + 0.5) * HILL_AMP * land_mask
	var mtn_mask := smoothstep(0.58, 0.82, cont01)
	var ridge := pow(1.0 - absf(_nm.get_noise_2d(w.x, w.y)), 3.0)       # sharp ridgelines
	var mountains := mtn_mask * ridge * MOUNTAIN_AMP
	var detail := _nd.get_noise_2d(w.x, w.y) * DETAIL_AMP * land_mask
	var h := base + hills + mountains + detail
	# Island edge-falloff: sink the outer rim into the sea for a natural coastline.
	var edge: float = maxf(absf(wx), absf(wz)) / (_size * 0.5)
	h -= smoothstep(0.80, 1.0, edge) * 70.0
	return h

func _height(wx: float, wz: float) -> float:
	var h := _land_height(wx, wz)
	if h < _water:
		h = minf(h, _water - STEP * 2.0)   # steep banks exceed agent_max_slope -> nav stops at shore
	for s in _sites:
		var d: float = Vector2(wx - s.x, wz - s.z).length()
		if d < s.r:
			var t := 1.0 - smoothstep(s.r * 0.55, s.r, d)  # 1 at centre, 0 at edge
			h = lerpf(h, s.h, t)
	return h

func _pick_sites(rng: RandomNumberGenerator) -> Array:
	var sites: Array = []
	var count := clampi(int(_size / 110.0), 3, 14)   # tiny maps get as few as 3 villages
	var span := _size * 0.40
	var attempts := 0
	while sites.size() < count and attempts < count * 60:
		attempts += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var ok := true
		for s in sites:
			if Vector2(x - s.x, z - s.z).length() < 78.0:
				ok = false
				break
		if not ok:
			continue
		# Flatten to a buildable plateau: always above water, never on a snow peak.
		var lh := _land_height(x, z)
		var plot := clampf(maxf(lh, _water + 6.0), _water + 6.0, SNOWLINE - 14.0)
		sites.append({"x": x, "z": z, "h": plot, "r": rng.randf_range(22.0, 32.0)})
	return sites

func _near_site(x: float, z: float, margin: float) -> bool:
	for s in _sites:
		if Vector2(x - s.x, z - s.z).length() < float(s.r) + margin:
			return true
	return false

# ---------------------------------------------------------------- climate (theme)

# Climate presets keyed by name. Game.config["climate"] (set by the host's LLM
# classification) selects one directly; otherwise the theme is keyword-matched.
const CLIMATES := {
	"temperate": {"temp": 0.0, "moist": 0.0, "snow": 0.0, "water": 0.0, "veg": 1.0, "tint": Color(1, 1, 1)},
	"frozen":    {"temp": -0.42, "moist": 0.05, "snow": -55.0, "water": 0.0, "veg": 0.55, "tint": Color(0.92, 0.96, 1.06)},
	"desert":    {"temp": 0.4, "moist": -0.45, "snow": 60.0, "water": -3.5, "veg": 0.3, "tint": Color(1.1, 1.0, 0.82)},
	"verdant":   {"temp": 0.12, "moist": 0.45, "snow": 30.0, "water": 1.5, "veg": 1.9, "tint": Color(0.9, 1.06, 0.9)},
	"volcanic":  {"temp": 0.35, "moist": -0.3, "snow": 50.0, "water": -2.5, "veg": 0.35, "tint": Color(1.12, 0.82, 0.78)},
	"isles":     {"temp": 0.18, "moist": 0.25, "snow": 20.0, "water": 9.0, "veg": 1.3, "tint": Color(0.96, 1.0, 1.05)},
	"alpine":    {"temp": -0.12, "moist": 0.0, "snow": -25.0, "water": -1.0, "veg": 0.8, "tint": Color(1, 1, 1)},
}

## Pick the climate preset: the host's LLM classification (Game.config["climate"]) if
## present, else keyword-match the theme, else temperate. Pure function of config +
## theme string, so every co-op peer and every save resolves the same world.
func _theme_climate(theme: String) -> Dictionary:
	var key := String(Game.config.get("climate", ""))
	if CLIMATES.has(key):
		return CLIMATES[key]
	var t := theme.to_lower()
	if _kw(t, ["snow", "ice", "frozen", "frost", "tundra", "arctic", "winter", "glacier", "blizzard", "polar"]):
		return CLIMATES["frozen"]
	if _kw(t, ["desert", "sand", "arid", "dune", "scorch", "drought", "wasteland", "badland", "dust", "mojave", "sahara"]):
		return CLIMATES["desert"]
	if _kw(t, ["jungle", "rainforest", "forest", "lush", "verdant", "swamp", "overgrown", "bog", "marsh", "jurassic", "amazon"]):
		return CLIMATES["verdant"]
	if _kw(t, ["volcan", "lava", "ash", "inferno", "hell", "ember", "magma", "scorched", "demon", "doom"]):
		return CLIMATES["volcanic"]
	if _kw(t, ["ocean", "island", "sea", "coast", "flood", "sunken", "atoll", "archipelago", "tropic", "pirate", "naval"]):
		return CLIMATES["isles"]
	if _kw(t, ["mountain", "alpine", "highland", "peak", "summit", "crag", "ridge"]):
		return CLIMATES["alpine"]
	return CLIMATES["temperate"]

func _kw(t: String, words: Array) -> bool:
	for w in words:
		if t.find(String(w)) >= 0:
			return true
	return false

func _temp_at(wx: float, wz: float) -> float:
	return clampf(_ntemp.get_noise_2d(wx, wz) * 0.5 + 0.5 + float(_climate.get("temp", 0.0)), 0.0, 1.0)

func _moist_at(wx: float, wz: float) -> float:
	return clampf(_nmoist.get_noise_2d(wx, wz) * 0.5 + 0.5 + float(_climate.get("moist", 0.0)), 0.0, 1.0)

func _snowline() -> float:
	return SNOWLINE + float(_climate.get("snow", 0.0))

# ---------------------------------------------------------------- biomes

## A coarse biome id for prop placement (slope-independent).
func _biome_at(wx: float, wz: float, h: float) -> String:
	if h <= _water + 1.0:
		return "water"
	if h <= _water + 3.0:
		return "beach"
	var temp := _temp_at(wx, wz)
	var moist := _moist_at(wx, wz)
	if h > _snowline() + (temp - 0.5) * 30.0:
		return "snow"
	if h > ALPINE:
		return "rock"
	if temp > 0.62 and moist < 0.40:
		return "desert"
	if moist > 0.60:
		return "forest"
	if temp < 0.36:
		return "tundra"
	return "grass"

## Small per-position tint jitter to break up flat colour bands.
func _vary(c: Color, wx: float, wz: float, amt: float) -> Color:
	var v: float = _nd.get_noise_2d(wx * 2.5, wz * 2.5) * amt
	return Color(clampf(c.r + v, 0, 1), clampf(c.g + v, 0, 1), clampf(c.b + v, 0, 1))

func _biome_color(wx: float, wz: float, h: float, ny: float) -> Color:
	if h <= _water + 0.25:
		return Color(0.16, 0.20, 0.26)             # lakebed (under the water plane)
	if h <= _water + 3.0:
		return _tint(_vary(Color(0.82, 0.76, 0.55), wx, wz, 0.05))  # beach sand
	var slope := 1.0 - clampf(ny, 0.0, 1.0)        # 0 flat .. 1 vertical
	if slope > 0.60:
		return _tint(_vary(Color(0.40, 0.37, 0.35), wx, wz, 0.05))  # exposed cliff rock
	var temp := _temp_at(wx, wz)
	var moist := _moist_at(wx, wz)
	if h > _snowline() + (temp - 0.5) * 30.0:
		return _tint(_vary(Color(0.93, 0.94, 0.97), wx, wz, 0.03))  # snow
	if h > ALPINE:
		return _tint(_vary(Color(0.46, 0.43, 0.40), wx, wz, 0.05))  # alpine rock
	if temp > 0.62 and moist < 0.40:
		return _tint(_vary(Color(0.78, 0.70, 0.42), wx, wz, 0.05))  # desert
	if moist > 0.60:
		return _tint(_vary(Color(0.19, 0.41, 0.18), wx, wz, 0.05))  # lush forest
	if temp < 0.36:
		return _tint(_vary(Color(0.44, 0.52, 0.41), wx, wz, 0.04))  # tundra / taiga
	return _tint(_vary(Color(0.30, 0.52, 0.24), wx, wz, 0.05))      # grassland

## Multiply a biome colour by the theme's palette tint.
func _tint(c: Color) -> Color:
	var k: Color = _climate.get("tint", Color(1, 1, 1))
	return Color(clampf(c.r * k.r, 0, 1), clampf(c.g * k.g, 0, 1), clampf(c.b * k.b, 0, 1))

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
			var wx := i * STEP - half
			var wz := j * STEP - half
			verts[idx] = Vector3(wx, h, wz)
			var hl: float = _heights[j * _n + maxi(i - 1, 0)]
			var hr: float = _heights[j * _n + mini(i + 1, _n - 1)]
			var hd: float = _heights[maxi(j - 1, 0) * _n + i]
			var hu: float = _heights[mini(j + 1, _n - 1) * _n + i]
			var nrm := Vector3(hl - hr, 2.0 * STEP, hd - hu).normalized()
			normals[idx] = nrm
			colors[idx] = _biome_color(wx, wz, h, nrm.y)

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

# ---------------------------------------------------------------- world map bake

var _map_tex: ImageTexture = null

## Bake a top-down biome-colour image of the world for the full-screen map (M).
func _bake_map_image() -> void:
	var img := Image.create(_n, _n, false, Image.FORMAT_RGB8)
	var half := (_n - 1) * STEP * 0.5
	for j in _n:
		for i in _n:
			var wx := i * STEP - half
			var wz := j * STEP - half
			var h: float = _heights[j * _n + i]
			var c := _biome_color(wx, wz, h, 1.0)
			if h <= _water:
				c = Color(0.16, 0.3, 0.5)   # show water as water, not lakebed
			img.set_pixel(i, j, c)
	_map_tex = ImageTexture.create_from_image(img)

func map_texture() -> ImageTexture:
	return _map_tex

func world_size() -> float:
	return _size

# ---------------------------------------------------------------- prop helpers

## A solid-colour box that is BOTH visible geometry and a static collider (parsed
## into the navmesh, so bots route around it). For trunks, boulders, walls.
func _collider_box(size: Vector3, pos: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 1.0
	mi.material_override = m
	mi.position = pos
	region.add_child(mi)
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	sb.add_child(cs)
	mi.add_child(sb)

## Visual-only box (no collider -> NOT parsed into the navmesh, so it's free for the
## bake). For foliage canopies and decorative rock chips.
func _visual_box(size: Vector3, pos: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 1.0
	mi.material_override = m
	mi.position = pos
	add_child(mi)   # not under the region -> never collides or bakes

# ---------------------------------------------------------------- water / bounds

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
	var h := MOUNTAIN_AMP + 80.0
	var t := 4.0
	var half := _size * 0.5
	add_wall(Vector3(_size, h, t), Vector3(0, h * 0.5 - 40.0, -half), "Dark", 13)
	add_wall(Vector3(_size, h, t), Vector3(0, h * 0.5 - 40.0, half), "Dark", 13)
	add_wall(Vector3(t, h, _size), Vector3(-half, h * 0.5 - 40.0, 0), "Dark", 13)
	add_wall(Vector3(t, h, _size), Vector3(half, h * 0.5 - 40.0, 0), "Dark", 13)

func _sample_height(wx: float, wz: float) -> float:
	var half := (_n - 1) * STEP * 0.5
	var i := clampi(int(round((wx + half) / STEP)), 0, _n - 1)
	var j := clampi(int(round((wz + half) / STEP)), 0, _n - 1)
	return _heights[j * _n + i]

# ---------------------------------------------------------------- vegetation

func _scatter_vegetation(rng: RandomNumberGenerator) -> void:
	var area := _size * _size
	var veg: float = float(_climate.get("veg", 1.0))   # theme density (desert sparse, jungle dense)
	var tree_budget := clampi(int(area / 2600.0 * veg), 20, 700)
	var rock_budget := clampi(int(area / 9000.0), 20, 170)
	var span := _size * 0.47

	# Trees — clustered into forests by the forest-density field, gated by biome.
	var placed := 0
	var att := 0
	while placed < tree_budget and att < tree_budget * 6:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var b := _biome_at(x, z, h)
		if b == "water" or b == "beach":
			continue
		if b == "desert" and rng.randf() > 0.05:
			continue                       # only the odd cactus in the desert
		if b == "rock" or b == "snow":
			if rng.randf() > 0.10:
				continue                   # sparse, hardy trees up high
		var dens: float = _nforest.get_noise_2d(x, z) * 0.5 + 0.5
		var thresh := 0.55
		if b == "forest":
			thresh = 0.30
		elif b == "tundra":
			thresh = 0.62
		if dens < thresh and rng.randf() > 0.2:
			continue
		if _near_site(x, z, 6.0):
			continue
		_add_tree(rng, Vector3(x, h, z), b)
		placed += 1

	# Boulders / rock clusters — anywhere dry, denser in the highlands.
	placed = 0
	att = 0
	while placed < rock_budget and att < rock_budget * 8:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var b := _biome_at(x, z, h)
		if b == "water" or b == "beach":
			continue
		if (b == "grass" or b == "forest") and rng.randf() > 0.5:
			continue
		if _near_site(x, z, 6.0):
			continue
		_add_boulder(rng, Vector3(x, h, z))
		placed += 1

const PROP_SCRIPT := preload("res://scripts/world/tree.gd")
var _prop_counter: int = 0

## Create a harvestable prop node (group "destructible" + `group`) with a deterministic
## id so breaking/regrowth replicates. Returns the node for the caller to fill in.
func _new_prop(pos: Vector3, group: String, drop_item: String, regrow: float) -> StaticBody3D:
	var p: StaticBody3D = PROP_SCRIPT.new()
	p.collision_layer = 1
	p.collision_mask = 0
	p.add_to_group(group)
	p.add_to_group("destructible")
	p.prop_id = _prop_counter
	p.drop_item = drop_item
	p.regrow_secs = regrow
	p.set_meta("prop_id", _prop_counter)
	_prop_counter += 1
	region.add_child(p)
	p.position = pos
	return p

## Build a single choppable tree (trunk collider + canopy), dropping wood.
func _add_tree(rng: RandomNumberGenerator, pos: Vector3, biome: String) -> void:
	var th := rng.randf_range(3.6, 8.0)
	if biome == "tundra" or biome == "snow":
		th *= 0.7
	var trunk_w := clampf(th * 0.09, 0.35, 0.8)
	var tree := _new_prop(pos, "tree", "wood", rng.randf_range(90.0, 180.0))
	# Trunk: collider + visual (local coords, since the prop is positioned at `pos`).
	_prop_box(tree, Vector3(trunk_w, th, trunk_w), Vector3(0, th * 0.5, 0), Color(0.34, 0.24, 0.15), true)
	if biome == "desert":
		var cc := Color(0.24, 0.42, 0.22)
		_prop_box(tree, Vector3(0.7, th * 0.9, 0.7), Vector3(0, th * 0.45, 0), cc, false)
		_prop_box(tree, Vector3(0.5, 1.4, 0.5), Vector3(trunk_w + 0.4, th * 0.6, 0), cc, false)
		return
	if biome == "snow" or biome == "tundra":
		var fc := Color(0.16, 0.34, 0.20)
		_prop_box(tree, Vector3(th * 0.6, th * 0.5, th * 0.6), Vector3(0, th * 0.78, 0), fc, false)
		_prop_box(tree, Vector3(th * 0.4, th * 0.4, th * 0.4), Vector3(0, th * 1.08, 0), fc, false)
		return
	var fr := rng.randf_range(2.2, 3.8)
	var leaf := Color(0.20, 0.42, 0.18) if biome == "forest" else Color(0.26, 0.48, 0.22)
	leaf = _vary(leaf, pos.x, pos.z, 0.04)
	_prop_box(tree, Vector3(fr, fr * 0.85, fr), Vector3(0, th + fr * 0.2, 0), leaf, false)
	_prop_box(tree, Vector3(fr * 0.75, fr * 0.7, fr * 0.75), Vector3(fr * 0.2, th + fr * 0.55, 0), leaf.darkened(0.08), false)

## A box under a prop node: a mesh, plus a collider when `solid` (the trunk / boulder).
func _prop_box(prop: Node3D, size: Vector3, local_pos: Vector3, col: Color, solid: bool) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 1.0
	mi.material_override = m
	mi.position = local_pos
	prop.add_child(mi)
	if solid:
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		cs.position = local_pos
		prop.add_child(cs)

## Boulders are choppable props that drop stone (and regrow slowly).
func _add_boulder(rng: RandomNumberGenerator, pos: Vector3) -> void:
	var rs := rng.randf_range(1.4, 3.6)
	var col := _vary(Color(0.42, 0.40, 0.38), pos.x, pos.z, 0.05)
	var rock := _new_prop(pos, "rock", "stone", rng.randf_range(180.0, 300.0))
	_prop_box(rock, Vector3(rs, rs * 0.8, rs * rng.randf_range(0.8, 1.2)), Vector3(0, rs * 0.3, 0), col, true)
	# A couple of smaller chips for a cluster look (visual only).
	if rng.randf() < 0.6:
		var s2 := rs * 0.5
		_prop_box(rock, Vector3(s2, s2, s2), Vector3(rs * 0.6, s2 * 0.3, rs * 0.3), col.darkened(0.05), false)

# ---------------------------------------------------------------- loot

## Scatter survival loot around villages so the backpack and collect/deliver quests
## have something to interact with.
func _scatter_loot(rng: RandomNumberGenerator) -> void:
	var weapons := ["shotgun", "sniper", "smg", "pistol", "rifle"]
	for s in _sites:
		for k in rng.randi_range(4, 7):
			var ang := rng.randf() * TAU
			var rr := rng.randf_range(2.0, float(s.r))
			var pos := Vector3(s.x + cos(ang) * rr, float(s.h) + 0.6, s.z + sin(ang) * rr)
			match rng.randi() % 7:
				0:
					add_pickup("food", pos, 40)
				1:
					add_pickup("water", pos, 50)
				2:
					add_pickup("health", pos, 50)
				3:
					add_pickup("grenade", pos)
				4:
					add_pickup("weapon", pos, 0, weapons[rng.randi() % weapons.size()])
				5:
					add_pickup("armor", pos, 0, ItemDB.ARMOR_IDS[rng.randi() % ItemDB.ARMOR_IDS.size()])
				_:
					add_pickup("ammo", pos)

# ---------------------------------------------------------------- villages

## A ring of simple huts around each flattened site, so villages read as places.
func _build_villages(rng: RandomNumberGenerator) -> void:
	var palette := [
		Color(0.55, 0.45, 0.32),  # timber
		Color(0.60, 0.58, 0.54),  # stone
		Color(0.52, 0.38, 0.30),  # clay
		Color(0.66, 0.60, 0.48),  # sandstone
	]
	for s in _sites:
		var huts := rng.randi_range(3, 6)
		for b in huts:
			var ang := TAU * float(b) / float(huts) + rng.randf_range(-0.35, 0.35)
			var rr := float(s.r) * rng.randf_range(0.40, 0.82)
			var bx := float(s.x) + cos(ang) * rr
			var bz := float(s.z) + sin(ang) * rr
			var by := _sample_height(bx, bz)
			var col: Color = palette[rng.randi() % palette.size()]
			_add_hut(rng, Vector3(bx, by, bz), col, ang)

## A watchtower (with a climbable ladder) at roughly every other village — a vantage
## point and a clear use for the new ladder-climbing.
func _build_watchtowers(rng: RandomNumberGenerator) -> void:
	for k in _sites.size():
		if k % 2 != 0:
			continue
		var s: Dictionary = _sites[k]
		var bx := float(s.x) + rng.randf_range(-8.0, 8.0)
		var bz := float(s.z) + rng.randf_range(-8.0, 8.0)
		add_watchtower(Vector3(bx, _sample_height(bx, bz), bz), rng.randf_range(7.0, 10.0))

## One hut: four walls (a doorway gap facing the village centre) + a flat roof.
func _add_hut(rng: RandomNumberGenerator, c: Vector3, col: Color, face: float) -> void:
	var w := rng.randf_range(5.0, 8.0)
	var d := rng.randf_range(5.0, 8.0)
	var ht := rng.randf_range(3.0, 4.2)
	var t := 0.4
	var hw := w * 0.5
	var hd := d * 0.5
	var y0 := c.y
	var roof := col.darkened(0.25)
	# Doorway on the wall facing the centre (back toward `face`).
	var door_w := 2.4
	var seg := (w - door_w) * 0.5
	var off := door_w * 0.5 + seg * 0.5
	var door_dir := Vector2(cos(face + PI), sin(face + PI))  # toward centre
	# Pick the wall whose outward normal is closest to door_dir.
	var south := absf(door_dir.y) >= absf(door_dir.x) and door_dir.y < 0.0
	var north := absf(door_dir.y) >= absf(door_dir.x) and door_dir.y >= 0.0
	var west := absf(door_dir.x) > absf(door_dir.y) and door_dir.x < 0.0
	# South / North walls (run along X).
	_hut_wall_x(c, hd, w, ht, t, seg, off, door_w, south, false, col)
	_hut_wall_x(c, -hd, w, ht, t, seg, off, door_w, north, true, col)
	# West / East walls (run along Z).
	_hut_wall_z(c, -hw, d, ht, t, seg, off, door_w, west, col)
	_hut_wall_z(c, hw, d, ht, t, seg, off, door_w, not west and not north and not south, col)
	_collider_box(Vector3(w + t, 0.4, d + t), Vector3(c.x, y0 + ht + 0.2, c.z), roof)

func _hut_wall_x(c: Vector3, dz: float, w: float, ht: float, t: float, seg: float, off: float, door_w: float, door: bool, _north: bool, col: Color) -> void:
	var y0 := c.y
	var z := c.z + dz
	if not door:
		_collider_box(Vector3(w, ht, t), Vector3(c.x, y0 + ht * 0.5, z), col)
		return
	_collider_box(Vector3(seg, ht, t), Vector3(c.x - off, y0 + ht * 0.5, z), col)
	_collider_box(Vector3(seg, ht, t), Vector3(c.x + off, y0 + ht * 0.5, z), col)
	_collider_box(Vector3(door_w, ht - 2.4, t), Vector3(c.x, y0 + 2.4 + (ht - 2.4) * 0.5, z), col)

func _hut_wall_z(c: Vector3, dx: float, d: float, ht: float, t: float, seg: float, off: float, door_w: float, door: bool, col: Color) -> void:
	var y0 := c.y
	var x := c.x + dx
	if not door:
		_collider_box(Vector3(t, ht, d), Vector3(x, y0 + ht * 0.5, c.z), col)
		return
	_collider_box(Vector3(t, ht, seg), Vector3(x, y0 + ht * 0.5, c.z - off), col)
	_collider_box(Vector3(t, ht, seg), Vector3(x, y0 + ht * 0.5, c.z + off), col)
	_collider_box(Vector3(t, ht - 2.4, door_w), Vector3(x, y0 + 2.4 + (ht - 2.4) * 0.5, c.z), col)

# ---------------------------------------------------------------- caves

## Enclosable rock shelters at mountain bases (a heightmap can't carve true tunnels,
## so these are open-mouthed boulder rings with loot tucked inside).
func _add_caves(rng: RandomNumberGenerator) -> void:
	var want := clampi(int(_size / 360.0), 2, 5)
	var span := _size * 0.42
	var made := 0
	var att := 0
	while made < want and att < 300:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var b := _biome_at(x, z, h)
		if b != "rock" and b != "snow" and b != "grass":
			continue
		if h < _water + 10.0 or _near_site(x, z, 24.0):
			continue
		_build_cave(rng, Vector3(x, h, z))
		made += 1

func _build_cave(rng: RandomNumberGenerator, c: Vector3) -> void:
	var radius := rng.randf_range(5.0, 7.0)
	var ht := rng.randf_range(3.6, 5.0)
	var rock := Color(0.17, 0.16, 0.18)
	var gap := rng.randf() * TAU      # entrance faces a random direction
	var segs := 9
	for a in segs:
		var ang := TAU * float(a) / float(segs)
		if absf(wrapf(ang - gap, -PI, PI)) < 0.55:
			continue                  # leave the mouth open
		var px := c.x + cos(ang) * radius
		var pz := c.z + sin(ang) * radius
		var ph := _sample_height(px, pz)
		_collider_box(Vector3(2.8, ht, 2.8), Vector3(px, ph + ht * 0.5, pz), rock.lightened(rng.randf() * 0.06))
	# Capstone roof so it reads as enclosed from outside.
	_collider_box(Vector3(radius * 2.4, 1.4, radius * 2.4), Vector3(c.x, c.y + ht + 0.2, c.z), rock)
	# Reward for exploring.
	add_pickup("weapon", Vector3(c.x, c.y + 0.6, c.z), 0, ["sniper", "shotgun"][rng.randi() % 2])
	if rng.randf() < 0.6:
		add_pickup("armor", Vector3(c.x + 1.2, c.y + 0.6, c.z), 0, ItemDB.ARMOR_IDS[rng.randi() % ItemDB.ARMOR_IDS.size()])

# ---------------------------------------------------------------- tunnels
# Heightmaps can't be carved, so a "tunnel" is a built covered passage (walls + roof)
# along a cardinal direction, ending in a capped chamber with a loot stash. Sometimes
# generated on Small+ maps as a hidden shortcut/cache.
const TUNNEL_DIRS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]

func _maybe_tunnels(rng: RandomNumberGenerator) -> void:
	if _size < 500.0:
		return
	var want := clampi(int(_size / 600.0), 1, 3)
	var span := _size * 0.4
	var made := 0
	var att := 0
	while made < want and att < 200:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var b := _biome_at(x, z, h)
		if b == "water" or b == "beach" or h < _water + 4.0 or _near_site(x, z, 22.0):
			continue
		_build_tunnel(rng, Vector3(x, h, z), TUNNEL_DIRS[rng.randi() % TUNNEL_DIRS.size()])
		made += 1

func _build_tunnel(rng: RandomNumberGenerator, start: Vector3, fwd: Vector3) -> void:
	var right := Vector3(-fwd.z, 0, fwd.x)
	var inner := 3.2
	var ht := 3.0
	var rock := Color(0.16, 0.15, 0.18)
	var seg := 2.4
	var steps := int(rng.randf_range(6.0, 11.0))
	var along_x: bool = absf(fwd.x) > 0.5
	var wall_size := Vector3(seg, ht, 0.6) if along_x else Vector3(0.6, ht, seg)
	var roof_size := Vector3(inner + 1.4, 0.5, inner + 1.4)
	var end := start
	for i in steps:
		var c := start + fwd * (float(i) * seg)
		var fy := _sample_height(c.x, c.z)
		var woff := right * (inner * 0.5 + 0.3)
		_collider_box(wall_size, Vector3(c.x + woff.x, fy + ht * 0.5, c.z + woff.z), rock)
		_collider_box(wall_size, Vector3(c.x - woff.x, fy + ht * 0.5, c.z - woff.z), rock)
		_collider_box(roof_size, Vector3(c.x, fy + ht + 0.2, c.z), rock.lightened(0.03))
		end = Vector3(c.x, fy, c.z)
	# Cap the far end with a back wall, then stash loot in the chamber.
	var back_size := Vector3(0.6, ht, inner + 1.4) if along_x else Vector3(inner + 1.4, ht, 0.6)
	_collider_box(back_size, end + fwd * (seg * 0.5) + Vector3(0, ht * 0.5, 0), rock)
	add_pickup("weapon", Vector3(end.x, end.y + 0.6, end.z), 0, ["sniper", "rifle"][rng.randi() % 2])
	if rng.randf() < 0.7:
		add_pickup("armor", end + right * 1.0 + Vector3(0, 0.6, 0), 0, ItemDB.ARMOR_IDS[rng.randi() % ItemDB.ARMOR_IDS.size()])

# ---------------------------------------------------------------- vehicles

## Called by map_base after the navmesh is baked: place vehicles now so they aren't
## part of the navmesh (keeps bots off their roofs). Deterministic from the seed.
func post_bake() -> void:
	var vrng := RandomNumberGenerator.new()
	vrng.seed = _seed + 919
	_place_vehicles(vrng)

## Medium+ worlds get a buggy at every other village so crossing the map isn't a
## kilometre on foot. Parked on the flattened plot edge, so it sits level.
func _place_vehicles(rng: RandomNumberGenerator) -> void:
	if _size < 600.0:
		return   # tiny/small maps are walkable
	for k in _sites.size():
		if k % 2 != 0:
			continue
		var s: Dictionary = _sites[k]
		var ang := rng.randf() * TAU
		var rr := float(s.r) * 0.7
		add_vehicle(Vector3(float(s.x) + cos(ang) * rr, float(s.h), float(s.z) + sin(ang) * rr), rng.randf_range(0.0, 360.0))

# ---------------------------------------------------------------- sites / spawns

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
