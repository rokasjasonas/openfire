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
var _terrain_mi: MeshInstance3D = null      # the live terrain mesh (rebuilt when dug)
var _height_shape: HeightMapShape3D = null  # the live collision heightmap (updated when dug)
var _sites: Array = []
# Climate derived deterministically from the story theme — biases biomes, snowline,
# water level, vegetation and palette so the map reflects the prompt.
var _climate: Dictionary = {}
# Landform archetype (terrain SHAPE + structures), orthogonal to climate (which is
# palette/temperature). Chosen from the theme so "flat lands", "city" and "dungeon"
# build visibly different worlds, not just re-tinted grassland.
var _landform: Dictionary = {}
var _landform_key: String = "rolling"
# Named features extracted from the prompt ("one big mountain", "heart-shaped lake",
# "crash site near X"), each resolved to a world position. Terrain-shaping features
# (mountain/lake/crater/…) modulate the heightmap; landmark/biome features are placed
# after the terrain builds. See _resolve_features / _feature_height / _place_features.
var _features: Array = []

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
	var theme_str := String(Game.config.get("theme", ""))
	_climate = _theme_climate(theme_str)
	_landform_key = _theme_landform(theme_str)
	_landform = LANDFORMS[_landform_key]
	set_meta("landform_key", _landform_key)
	_water = 6.0 + float(_climate.get("water", 0.0)) + float(_landform.get("water", 0.0))
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
	_features = _resolve_features(rng)   # prompt features (mountains, lakes, landmarks…)

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
	_scatter_trash(rng)
	_scatter_scrap(rng)       # rusty barrels + abandoned wrecks, for plentiful metal
	_build_scrapyard(rng)     # a junkyard landmark stocked with scrap + a weapon
	_place_features(rng)   # landmark clusters + local biomes (before props are batched)
	_finalize_props()   # batch all tree/rock visuals into one MultiMesh
	if not _landform.get("dungeon", false):
		_add_floating_islands(rng)   # sky islands make no sense under a dungeon roof
	if _landform.get("city", false):
		_build_city(rng)
	if _landform.get("dungeon", false):
		_build_dungeon(rng)
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
	# Landform multipliers reshape each relief band (defaults = the classic rolling look).
	var lf := _landform
	var m_hill := float(lf.get("hill", 1.0))
	var m_mtn := float(lf.get("mtn", 1.0))
	var m_det := float(lf.get("detail", 1.0))
	var hills := (_nh.get_noise_2d(w.x, w.y) * 0.5 + 0.5) * HILL_AMP * m_hill * land_mask
	var mtn_mask := smoothstep(0.58, 0.82, cont01)
	var ridge := pow(1.0 - absf(_nm.get_noise_2d(w.x, w.y)), 3.0)       # sharp ridgelines
	var mountains := mtn_mask * ridge * MOUNTAIN_AMP * m_mtn
	var detail := _nd.get_noise_2d(w.x, w.y) * DETAIL_AMP * m_det * land_mask
	# Dunes: regular wind-ribbed waves layered onto the sand.
	if lf.get("dunes", false):
		detail += sin(w.x * 0.06) * 5.0 * land_mask
	var h := base + hills + mountains + detail
	# Mesa/plateau: terrace the land into stepped tables with sheer sides.
	if lf.get("terrace", false):
		var band := 18.0
		h = round(h / band) * band + clampf((h - round(h / band) * band) * 3.0, -2.0, 2.0)
	# Flatten toward a level plain (flat lands / tundra / urban / dungeon floors).
	var flat := float(lf.get("flat", 0.0))
	if flat > 0.0:
		var plain := _water + 8.0
		h = lerpf(h, plain, flat * land_mask)
	# Island edge-falloff: sink the outer rim into the sea for a natural coastline.
	var edge: float = maxf(absf(wx), absf(wz)) / (_size * 0.5)
	h -= smoothstep(0.80, 1.0, edge) * 70.0
	return h

func _height(wx: float, wz: float) -> float:
	var h := _land_height(wx, wz)
	h = _feature_height(wx, wz, h)   # named prompt features reshape the land first
	if h < _water:
		h = minf(h, _water - STEP * 2.0)   # steep banks exceed agent_max_slope -> nav stops at shore
	for s in _sites:
		var d: float = Vector2(wx - s.x, wz - s.z).length()
		if d < s.r:
			var t := 1.0 - smoothstep(s.r * 0.55, s.r, d)  # 1 at centre, 0 at edge
			h = lerpf(h, s.h, t)
	return h

## Apply terrain-shaping features (mountain / lake / crater / plateau / valley) to the raw
## land height at (wx, wz). Landmark + biome features don't touch height (placed later).
func _feature_height(wx: float, wz: float, h: float) -> float:
	for f in _features:
		if String(f["cat"]) != "terrain":
			continue
		var r: float = float(f["r"])
		var dx := wx - float(f["x"])
		var dz := wz - float(f["z"])
		var d := Vector2(dx, dz).length()
		if d > r * 1.4:
			continue
		var t: float = 1.0 - smoothstep(0.0, r, d)     # 1 centre .. 0 edge
		var base: float = float(f["base"])
		match String(f["type"]):
			"mountain":
				var peak := 150.0 if float(f["r"]) > FEATURES["mountain"]["r"] else 95.0
				h += peak * pow(t, 1.7)
			"volcano":
				h += 120.0 * pow(t, 1.7)
				if d < r * 0.22:
					h -= 55.0 * (1.0 - smoothstep(0.0, r * 0.22, d))   # summit crater
			"crater", "sinkhole":
				h -= (44.0 if String(f["type"]) == "crater" else 30.0) * pow(t, 0.8)
			"plateau":
				h = lerpf(h, maxf(base + 42.0, _water + 22.0), smoothstep(0.0, 0.6, t))
			"valley":
				h -= 34.0 * t
			"lake":
				var m := _lake_inside(dx, dz, r, String(f["shape"]))
				if m > 0.0:
					h = minf(h, _water - 2.0 - 7.0 * m)   # carve below the water plane so it fills
	return h

## Inside-ness (0..1) of a lake footprint of radius `r` at local offset (lx, lz), by shape.
## Non-round shapes use their implicit curve so "heart-shaped lake" reads as a heart.
func _lake_inside(lx: float, lz: float, r: float, shape: String) -> float:
	match shape:
		"heart":
			# Classic heart implicit: (u²+v²-1)³ - u²v³ ≤ 0, oriented point-down.
			var u := lx / (r * 0.92)
			var v := -lz / (r * 0.92)
			var q := u * u + v * v - 1.0
			var val := q * q * q - u * u * v * v * v
			return clampf(1.0 - val * 3.0, 0.0, 1.0) if val <= 0.0 else 0.0
		"long":
			var uu := lx / r
			var vv := lz / (r * 0.42)
			return clampf(1.0 - (uu * uu + vv * vv), 0.0, 1.0)
		"crescent":
			var a := 1.0 - clampf((lx * lx + lz * lz) / (r * r), 0.0, 1.0)
			var bite := 1.0 - clampf(((lx - r * 0.5) * (lx - r * 0.5) + lz * lz) / (r * r * 0.64), 0.0, 1.0)
			return clampf(a - bite * 1.4, 0.0, 1.0)
		_:  # round (default)
			return clampf(1.0 - Vector2(lx, lz).length() / r, 0.0, 1.0)

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

# ---------------------------------------------------------------- landforms

## Landform presets: multipliers that reshape the relief plus flags that switch on
## special generators. `hill/mtn/detail` scale the noise bands, `flat` (0..1) pulls the
## land toward a level plain, `water` shifts the sea, `caves`/`builds` scale structure
## counts, and `city`/`dungeon`/`terrace`/`dunes` toggle bespoke generation.
const LANDFORMS := {
	"rolling":     {"hill": 1.0,  "mtn": 1.0,  "detail": 1.0, "flat": 0.0,  "water": 0.0, "caves": 1.0, "builds": 1.0},
	"plains":      {"hill": 0.35, "mtn": 0.05, "detail": 0.7, "flat": 0.72, "water": 0.0, "caves": 0.4, "builds": 1.1, "veg": 0.7, "rocks": 0.5},
	"highlands":   {"hill": 1.4,  "mtn": 1.95, "detail": 1.2, "flat": 0.0,  "water": -1.0,"caves": 1.4, "builds": 0.7, "rocks": 1.6},
	"mesa":        {"hill": 0.5,  "mtn": 1.15, "detail": 0.8, "flat": 0.35, "water": -2.5,"caves": 0.9, "builds": 0.8, "veg": 0.4, "rocks": 1.3, "terrace": true},
	"caverns":     {"hill": 0.9,  "mtn": 0.7,  "detail": 1.7, "flat": 0.1,  "water": -1.0,"caves": 3.6, "builds": 0.6, "rocks": 2.0},
	"dunes":       {"hill": 0.85, "mtn": 0.08, "detail": 1.25,"flat": 0.2,  "water": -3.0,"caves": 0.2, "builds": 0.6, "veg": 0.15,"rocks": 0.4, "dunes": true},
	"wetlands":    {"hill": 0.3,  "mtn": 0.04, "detail": 0.9, "flat": 0.75, "water": 3.5, "caves": 0.3, "builds": 0.9, "veg": 1.4},
	"archipelago": {"hill": 0.7,  "mtn": 0.5,  "detail": 1.0, "flat": 0.15, "water": 8.5, "caves": 0.5, "builds": 0.8},
	"badlands":    {"hill": 0.6,  "mtn": 0.95, "detail": 1.45,"flat": 0.3,  "water": -3.5,"caves": 1.1, "builds": 0.7, "veg": 0.25,"rocks": 1.8},
	"urban":       {"hill": 0.18, "mtn": 0.0,  "detail": 0.4, "flat": 0.88, "water": -1.0,"caves": 0.1, "builds": 0.0, "veg": 0.1, "rocks": 0.2, "city": true},
	"dungeon":     {"hill": 0.0,  "mtn": 0.0,  "detail": 0.0, "flat": 1.0,  "water": -40.0,"caves": 0.0, "builds": 0.0, "veg": 0.0, "rocks": 0.0, "dungeon": true},
}

## Pick the landform preset: the host's classification (Game.config["landform"]) if valid,
## else keyword-match the theme, else "rolling". Deterministic (config + theme only).
func _theme_landform(theme: String) -> String:
	var key := String(Game.config.get("landform", ""))
	if LANDFORMS.has(key):
		return key
	var t := theme.to_lower()
	# Order matters: most specific / most enclosing first.
	if _kw(t, ["dungeon", "crypt", "catacomb", "vault", "labyrinth", "sewer", "mine", "tomb", "bunker"]):
		return "dungeon"
	if _kw(t, ["city", "urban", "metropolis", "downtown", "street", "slum", "tokyo", "cyberpunk", "megacity", "town"]):
		return "urban"
	if _kw(t, ["cave", "cavern", "grotto", "hollow", "underground", "subterran"]):
		return "caverns"
	if _kw(t, ["mountain", "alpine", "highland", "peak", "summit", "crag", "ridge", "cliff"]):
		return "highlands"
	if _kw(t, ["mesa", "plateau", "canyon", "butte", "gorge"]):
		return "mesa"
	if _kw(t, ["swamp", "marsh", "bog", "wetland", "bayou", "fen", "mire", "delta"]):
		return "wetlands"
	if _kw(t, ["island", "archipelago", "atoll", "isles", "coast", "lagoon", "reef"]):
		return "archipelago"
	if _kw(t, ["dune", "sand sea", "erg", "sahara", "desert plain"]):
		return "dunes"
	if _kw(t, ["badland", "wasteland", "barren", "scorched earth", "eroded", "dust bowl"]):
		return "badlands"
	if _kw(t, ["flat", "plain", "prairie", "steppe", "tundra", "grassland", "savanna", "field", "meadow"]):
		return "plains"
	return "rolling"

# ---------------------------------------------------------------- named features

## Feature vocabulary. `cat`: "terrain" reshapes the heightmap, "landmark" drops a themed
## prop cluster, "biome" overrides local vegetation/ground. `r` is the base radius (metres).
const FEATURES := {
	"mountain":     {"cat": "terrain",  "r": 82.0},
	"volcano":      {"cat": "terrain",  "r": 86.0},
	"crater":       {"cat": "terrain",  "r": 46.0},
	"sinkhole":     {"cat": "terrain",  "r": 32.0},
	"plateau":      {"cat": "terrain",  "r": 62.0},
	"valley":       {"cat": "terrain",  "r": 72.0},
	"lake":         {"cat": "terrain",  "r": 56.0},
	"crash_site":   {"cat": "landmark", "r": 20.0},
	"ruins":        {"cat": "landmark", "r": 26.0},
	"monument":     {"cat": "landmark", "r": 16.0},
	"campsite":     {"cat": "landmark", "r": 14.0},
	"tower":        {"cat": "landmark", "r": 10.0},
	"graveyard":    {"cat": "landmark", "r": 20.0},
	"forest_grove": {"cat": "biome",    "r": 62.0},
	"oasis":        {"cat": "biome",    "r": 30.0},
	"swamp_patch":  {"cat": "biome",    "r": 56.0},
	"rocky_field":  {"cat": "biome",    "r": 54.0},
	"dead_forest":  {"cat": "biome",    "r": 56.0},
}

## Synonyms → canonical feature type, so free-text prompts (and the LLM) resolve loosely.
const FEATURE_ALIASES := {
	"mountain": "mountain", "peak": "mountain", "mount": "mountain", "summit": "mountain",
	"volcano": "volcano", "caldera": "volcano",
	"crater": "crater", "meteor": "crater", "impact": "crater",
	"sinkhole": "sinkhole", "pit": "sinkhole",
	"plateau": "plateau", "mesa": "plateau", "butte": "plateau",
	"valley": "valley", "basin": "valley", "gorge": "valley", "canyon": "valley", "ravine": "valley",
	"lake": "lake", "pond": "lake", "pool": "lake", "lagoon": "lake", "tarn": "lake", "reservoir": "lake",
	"crash": "crash_site", "wreck": "crash_site", "wreckage": "crash_site", "crashsite": "crash_site",
	"ruin": "ruins", "ruins": "ruins", "temple": "ruins", "fort": "ruins", "citadel": "ruins",
	"monument": "monument", "stonehenge": "monument", "obelisk": "monument", "statue": "monument", "henge": "monument", "shrine": "monument",
	"stone circle": "monument", "standing stone": "monument", "car crash": "crash_site", "crash site": "crash_site", "plane crash": "crash_site",
	"camp": "campsite", "campsite": "campsite", "tents": "campsite", "outpost": "campsite",
	"tower": "tower", "watchtower": "tower", "lighthouse": "tower",
	"graveyard": "graveyard", "cemetery": "graveyard", "graves": "graveyard", "necropolis": "graveyard",
	"forest": "forest_grove", "grove": "forest_grove", "woods": "forest_grove", "jungle": "forest_grove", "woodland": "forest_grove",
	"oasis": "oasis",
	"swamp": "swamp_patch", "marsh": "swamp_patch", "bog": "swamp_patch", "wetland": "swamp_patch",
	"boulders": "rocky_field", "rockfield": "rocky_field", "rocks": "rocky_field", "scree": "rocky_field",
	"deadwood": "dead_forest", "deadforest": "dead_forest",
}

func _canon_feature(s: String) -> String:
	var k := s.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	if FEATURES.has(k):
		return k
	return String(FEATURE_ALIASES.get(k, ""))

## Turn the prompt's feature specs (from the LLM, or keyword-extracted) into concrete
## placed instances with world positions, honouring "near" relations (anchors first).
func _resolve_features(rng: RandomNumberGenerator) -> Array:
	var specs: Array = Game.config.get("features", [])
	if specs.is_empty():
		specs = _extract_features_kw(String(Game.config.get("theme", "")))
	var out: Array = []
	var by_id: Dictionary = {}
	var span := _size * 0.36
	# Two passes: place anchors (no "near") first so dependents can attach to them.
	for anchors_pass in [true, false]:
		for spec in specs:
			if typeof(spec) != TYPE_DICTIONARY:
				continue
			var type := _canon_feature(String(spec.get("type", "")))
			if type == "":
				continue
			var near := String(spec.get("near", "")).strip_edges()
			if (near == "") != anchors_pass:
				continue
			var fdef: Dictionary = FEATURES[type]
			var size := String(spec.get("size", "")).to_lower()
			var scale := 1.0
			if size in ["big", "huge", "large", "giant", "massive"]:
				scale = 1.5
			elif size in ["small", "tiny", "little"]:
				scale = 0.6
			var r := minf(float(fdef["r"]) * scale, _size * 0.32)   # keep features on-map
			var count := clampi(int(spec.get("count", 1)), 1, 4)
			for k in count:
				if out.size() >= 12:
					break
				var pos := Vector2.ZERO
				var placed := false
				if near != "" and by_id.has(near):
					var anc: Dictionary = by_id[near]
					var ang := rng.randf() * TAU
					var dist := float(anc["r"]) + r * 0.65 + 10.0
					pos = Vector2(float(anc["x"]) + cos(ang) * dist, float(anc["z"]) + sin(ang) * dist)
					pos.x = clampf(pos.x, -span, span)
					pos.y = clampf(pos.y, -span, span)
					placed = true
				else:
					var att := 0
					while att < 50:
						att += 1
						var p := Vector2(rng.randf_range(-span, span), rng.randf_range(-span, span))
						if _feature_spot_ok(p, r, out):
							pos = p
							placed = true
							break
				if not placed:
					continue
				var inst := {
					"type": type, "cat": String(fdef["cat"]), "x": pos.x, "z": pos.y,
					"r": r, "size": size, "shape": String(spec.get("shape", "round")).to_lower(),
					"kind": String(spec.get("kind", "")), "id": String(spec.get("id", "")),
					"base": _land_height(pos.x, pos.y),
				}
				out.append(inst)
				if String(inst["id"]) != "":
					by_id[inst["id"]] = inst
	return out

## A candidate feature centre is OK if it clears the map edge, the village sites and any
## already-placed feature (so features don't stack on top of each other).
func _feature_spot_ok(p: Vector2, r: float, placed: Array) -> bool:
	if _near_site(p.x, p.y, r * 0.4 + 12.0):   # features may sit fairly near villages
		return false
	for f in placed:
		if Vector2(p.x - float(f["x"]), p.y - float(f["z"])).length() < r + float(f["r"]) + 12.0:
			return false
	return true

## Offline fallback: scan the prompt for feature words and build a simple spec list,
## picking up "big/small", lake shapes, and a crude "near" relation.
func _extract_features_kw(theme: String) -> Array:
	var t := theme.to_lower()
	var big := _kw(t, ["big", "huge", "large", "giant", "massive", "tall", "great"])
	var small := _kw(t, ["small", "tiny", "little"])
	var found: Array = []
	var seen: Dictionary = {}
	for word in FEATURE_ALIASES:
		if t.find(word) < 0:
			continue
		var type: String = FEATURE_ALIASES[word]
		if seen.has(type):
			continue
		seen[type] = true
		var spec := {"type": type}
		if FEATURES[type]["cat"] == "terrain":
			if big:
				spec["size"] = "big"
			elif small:
				spec["size"] = "small"
		if type == "lake":
			for shp in ["heart", "crescent", "star", "long", "round"]:
				if t.find(shp) >= 0:
					spec["shape"] = shp
		found.append(spec)
		if found.size() >= 6:
			break
	# Crude relation: "X near/by/beside Y" -> attach the later features to the first.
	if found.size() >= 2 and _kw(t, ["near", " by ", "beside", "next to", "at the foot"]):
		found[0]["id"] = "anchor"
		for i in range(1, found.size()):
			found[i]["near"] = "anchor"
	return found

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

## Build an ArrayMesh from the current heightmap. Reused for the initial build and for
## rebuilds after the shovel digs holes into the terrain.
const GROUND_UV_TILE := 14.0   # metres per repeat of the ground texture

func _terrain_mesh_from_heights() -> ArrayMesh:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(_n * _n)
	colors.resize(_n * _n)
	normals.resize(_n * _n)
	uvs.resize(_n * _n)
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
			uvs[idx] = Vector2(wx, wz) / GROUND_UV_TILE   # planar world UV for the ground texture

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
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

var _terrain_mat: StandardMaterial3D = null

func _build_terrain_mesh() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = _terrain_mesh_from_heights()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true   # biome colours tint the (later) ground texture
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	region.add_child(mi)   # under the NavigationRegion so the navmesh bakes from it
	_terrain_mi = mi
	_terrain_mat = mat

## Apply a themed AI ground texture across the whole terrain (tiled, multiplied by the biome
## vertex colours). Called when the ComfyUI texture for the world theme is ready.
func apply_ground_texture(tex: Texture2D) -> void:
	if _terrain_mat == null or tex == null:
		return
	# UVs run 0..world/tile, so the texture tiles (runtime ImageTextures repeat by default).
	_terrain_mat.albedo_texture = tex
	_terrain_mat.albedo_color = Color(1, 1, 1)

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
	_height_shape = shape
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

## Carve a bowl-shaped hole into the terrain heightmap at a world position, then refresh
## the collision shape and visual mesh. Deterministic (same args -> same result on every
## peer), and repeated digs at the same spot deepen the hole down to the sea floor.
func dig_hole(world_pos: Vector3, radius_m: float = 2.6, depth_m: float = 1.2) -> void:
	if _heights.is_empty() or _n <= 0:
		return
	var half := (_n - 1) * STEP * 0.5
	var ci := (world_pos.x + half) / STEP
	var cj := (world_pos.z + half) / STEP
	var rad: float = maxf(radius_m / STEP, 0.5)
	var floor_y := SEA_FLOOR + 1.0
	var i0 := maxi(0, int(floor(ci - rad)))
	var i1 := mini(_n - 1, int(ceil(ci + rad)))
	var j0 := maxi(0, int(floor(cj - rad)))
	var j1 := mini(_n - 1, int(ceil(cj + rad)))
	var changed := false
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var d := Vector2(i - ci, j - cj).length() / rad
			if d > 1.0:
				continue
			var falloff := 1.0 - d * d   # smooth bowl, deepest at the centre
			var idx := j * _n + i
			var nh: float = maxf(_heights[idx] - depth_m * falloff, floor_y)
			if nh < _heights[idx]:
				_heights[idx] = nh
				changed = true
	if not changed:
		return
	if _height_shape != null:
		_height_shape.map_data = _heights
	if _terrain_mi != null:
		_terrain_mi.mesh = _terrain_mesh_from_heights()

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
	_water_mat = mat

## Apply a themed water surface texture (kept translucent + reflective). The whole plane is
## one quad, so a single UV tiling reads across it.
var _water_mat: StandardMaterial3D = null
func apply_water_texture(tex: Texture2D) -> void:
	if _water_mat == null or tex == null:
		return
	_water_mat.albedo_texture = tex
	_water_mat.albedo_color = Color(1, 1, 1, 0.7)
	_water_mat.uv1_scale = Vector3(_size / 24.0, _size / 24.0, 1.0)   # tile across the plane

func _add_perimeter() -> void:
	var h := MOUNTAIN_AMP + 80.0
	var t := 4.0
	var half := _size * 0.5
	add_wall(Vector3(_size, h, t), Vector3(0, h * 0.5 - 40.0, -half), "Dark", 13)
	add_wall(Vector3(_size, h, t), Vector3(0, h * 0.5 - 40.0, half), "Dark", 13)
	add_wall(Vector3(t, h, _size), Vector3(-half, h * 0.5 - 40.0, 0), "Dark", 13)
	add_wall(Vector3(t, h, _size), Vector3(half, h * 0.5 - 40.0, 0), "Dark", 13)

## Bilinearly interpolate the surface height (matching the rendered mesh) so props and
## buildings sit flush — nearest-vertex sampling left them floating/sunk on slopes.
func _sample_height(wx: float, wz: float) -> float:
	var half := (_n - 1) * STEP * 0.5
	var fx := (wx + half) / STEP
	var fz := (wz + half) / STEP
	var i0 := clampi(int(floor(fx)), 0, _n - 1)
	var j0 := clampi(int(floor(fz)), 0, _n - 1)
	var i1 := mini(i0 + 1, _n - 1)
	var j1 := mini(j0 + 1, _n - 1)
	var tx := clampf(fx - float(i0), 0.0, 1.0)
	var tz := clampf(fz - float(j0), 0.0, 1.0)
	var h00: float = _heights[j0 * _n + i0]
	var h10: float = _heights[j0 * _n + i1]
	var h01: float = _heights[j1 * _n + i0]
	var h11: float = _heights[j1 * _n + i1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

# ---------------------------------------------------------------- vegetation

func _scatter_vegetation(rng: RandomNumberGenerator) -> void:
	var area := _size * _size
	var veg: float = float(_climate.get("veg", 1.0))   # theme density (desert sparse, jungle dense)
	var vmul: float = float(_landform.get("veg", 1.0))  # landform: urban/dungeon strip trees
	var tree_budget := clampi(int(area / 2600.0 * veg * vmul), 0, 700)
	var rock_budget := clampi(int(area / 9000.0 * float(_landform.get("rocks", 1.0))), 0, 220)
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
# All prop visuals (trunks/canopies/rocks) render from ONE MultiMesh of unit cubes with
# per-instance transform+colour — a single draw call instead of ~2000. Colliders stay
# per-prop so they're still shootable/destructible. Filled during scatter, built after.
var _prop_xf: Array = []        # Transform3D per visual box
var _prop_cols: Array = []      # Color per visual box
var _props_list: Array = []     # the prop StaticBody nodes, for wiring the MultiMesh

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
	_props_list.append(p)
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
	# Canopy/foliage boxes are solid too, so you can stand on the green part (and it
	# blocks shots/movement); set_felled() disables every collider when the tree breaks.
	if biome == "desert":
		var cc := Color(0.24, 0.42, 0.22)
		_prop_box(tree, Vector3(0.7, th * 0.9, 0.7), Vector3(0, th * 0.45, 0), cc, true)
		_prop_box(tree, Vector3(0.5, 1.4, 0.5), Vector3(trunk_w + 0.4, th * 0.6, 0), cc, true)
		return
	if biome == "snow" or biome == "tundra":
		var fc := Color(0.16, 0.34, 0.20)
		_prop_box(tree, Vector3(th * 0.6, th * 0.5, th * 0.6), Vector3(0, th * 0.78, 0), fc, true)
		_prop_box(tree, Vector3(th * 0.4, th * 0.4, th * 0.4), Vector3(0, th * 1.08, 0), fc, true)
		return
	var fr := rng.randf_range(2.2, 3.8)
	var leaf := Color(0.20, 0.42, 0.18) if biome == "forest" else Color(0.26, 0.48, 0.22)
	leaf = _vary(leaf, pos.x, pos.z, 0.04)
	_prop_box(tree, Vector3(fr, fr * 0.85, fr), Vector3(0, th + fr * 0.2, 0), leaf, true)
	_prop_box(tree, Vector3(fr * 0.75, fr * 0.7, fr * 0.75), Vector3(fr * 0.2, th + fr * 0.55, 0), leaf.darkened(0.08), true)

## A box under a prop node: a mesh, plus a collider when `solid` (the trunk / boulder).
func _prop_box(prop: Node3D, size: Vector3, local_pos: Vector3, col: Color, solid: bool) -> void:
	# Register the visual as a MultiMesh instance (unit cube scaled by `size`).
	var xf := Transform3D(Basis().scaled(size), prop.position + local_pos)
	var idx := _prop_xf.size()
	_prop_xf.append(xf)
	_prop_cols.append(col)
	prop.mm_items.append({"idx": idx, "xf": xf})
	# A collider stays on the prop for trunks/boulders so it blocks + can be shot.
	if solid:
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		cs.position = local_pos
		prop.add_child(cs)

## After all props are scattered, bake their visuals into one MultiMesh and hand each
## prop a reference so it can hide/show its instances when felled/regrown.
func _finalize_props() -> void:
	if _prop_xf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	bm.material = mat
	mm.mesh = bm
	mm.instance_count = _prop_xf.size()
	for i in _prop_xf.size():
		mm.set_instance_transform(i, _prop_xf[i])
		mm.set_instance_color(i, _prop_cols[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "PropVisuals"
	mmi.multimesh = mm
	add_child(mmi)   # under terrain (not the nav region) — visual only, never baked
	for p in _props_list:
		p.mm = mm

## Trash piles: flimsy destructible heaps that spill random salvage (incl. scrap metal).
## Scattered on dry ground (often near settlements). They restock after a while.
func _scatter_trash(rng: RandomNumberGenerator) -> void:
	var span := _size * 0.46
	var want := clampi(int(_size / 110.0), 8, 40)   # ~3x more common, salvage is plentiful
	var made := 0
	var att := 0
	while made < want and att < want * 8:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var b := _biome_at(x, z, h)
		if b == "water" or b == "beach" or h < _water + 1.0:
			continue
		var pile := _new_prop(Vector3(x, h, z), "trash", "scrap", rng.randf_range(150.0, 260.0))
		_prop_box(pile, Vector3(1.0, 0.6, 1.0), Vector3(0, 0.3, 0), Color(0.3, 0.28, 0.24), true)
		_prop_box(pile, Vector3(0.5, 0.4, 0.6), Vector3(0.35, 0.7, 0.1), Color(0.46, 0.4, 0.3), false)
		_prop_box(pile, Vector3(0.4, 0.3, 0.4), Vector3(-0.3, 0.58, -0.2), Color(0.5, 0.5, 0.55), false)
		made += 1

## Rusty barrels and abandoned car wrecks scattered across the wilds — the main
## environmental source of scrap metal. Both are destructible props that drop scrap
## directly (barrels pop in a couple hits; wrecks are a richer, tougher haul).
func _scatter_scrap(rng: RandomNumberGenerator) -> void:
	# Barrels & loose metal debris: common and obvious, spread over the whole map.
	var span := _size * 0.46
	var barrels := clampi(int(_size / 90.0), 10, 60)
	var att := 0
	var made := 0
	while made < barrels and att < barrels * 8:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var b := _biome_at(x, z, h)
		if b == "water" or b == "beach" or h < _water + 1.0:
			continue
		_make_barrel(Vector3(x, h, z), rng)
		made += 1
	# Abandoned wrecks: rarer, chunkier, 2-3 scrap each.
	var wrecks := clampi(int(_size / 300.0), 3, 14)
	att = 0
	made = 0
	while made < wrecks and att < wrecks * 8:
		att += 1
		var x := rng.randf_range(-span, span)
		var z := rng.randf_range(-span, span)
		var h := _sample_height(x, z)
		var bi := _biome_at(x, z, h)
		if bi == "water" or bi == "beach" or h < _water + 1.0:
			continue
		_make_wreck(Vector3(x, h, z), rng.randf_range(0.0, TAU), rng)
		made += 1

func _make_barrel(pos: Vector3, rng: RandomNumberGenerator) -> void:
	var barrel := _new_prop(pos, "barrel", "scrap", rng.randf_range(120.0, 220.0))
	var rust := _vary(Color(0.55, 0.32, 0.18), pos.x, pos.z, 0.06)
	var band := rust.darkened(0.2)
	_prop_box(barrel, Vector3(0.7, 1.0, 0.7), Vector3(0, 0.5, 0), rust, true)        # drum body
	_prop_box(barrel, Vector3(0.78, 0.12, 0.78), Vector3(0, 0.18, 0), band, false)   # lower band
	_prop_box(barrel, Vector3(0.78, 0.12, 0.78), Vector3(0, 0.82, 0), band, false)   # upper band
	_prop_box(barrel, Vector3(0.72, 0.08, 0.72), Vector3(0, 1.02, 0), Color(0.4, 0.42, 0.45), false)  # metal lid

## Note: prop visuals are axis-aligned (the MultiMesh batch ignores node rotation), so
## wrecks aren't rotated — `_yaw` is accepted for call-site readability but unused.
func _make_wreck(pos: Vector3, _yaw: float, rng: RandomNumberGenerator) -> void:
	var wreck := _new_prop(pos, "wreck", "scrap", rng.randf_range(220.0, 360.0))
	var rust := _vary(Color(0.5, 0.34, 0.26), pos.x, pos.z, 0.05)
	var rust2 := rust.darkened(0.12)
	_prop_box(wreck, Vector3(2.0, 0.7, 4.2), Vector3(0, 0.5, 0), rust, true)          # chassis
	_prop_box(wreck, Vector3(1.8, 0.8, 1.9), Vector3(0, 1.15, -0.3), rust2, false)    # cabin
	_prop_box(wreck, Vector3(1.6, 0.5, 1.2), Vector3(0, 1.05, 1.4), rust2, false)     # hood
	# Stripped, rusted-out wheels.
	for sx in [-0.95, 0.95]:
		for sz in [-1.4, 1.4]:
			_prop_box(wreck, Vector3(0.25, 0.7, 0.7), Vector3(sx, 0.35, sz), Color(0.12, 0.12, 0.13), false)

## A junkyard landmark: a dense cluster of wrecks and barrels around a clearing,
## reliably rich in scrap, with a weapon and some ammo as a find-it reward.
func _build_scrapyard(rng: RandomNumberGenerator) -> void:
	# Pick a dry spot at mid radius, away from the map centre/start.
	var cx := 0.0
	var cz := 0.0
	var ok := false
	for _try in 40:
		var ang := rng.randf() * TAU
		var rad := _size * rng.randf_range(0.18, 0.36)
		cx = cos(ang) * rad
		cz = sin(ang) * rad
		var h := _sample_height(cx, cz)
		var b := _biome_at(cx, cz, h)
		if b != "water" and b != "beach" and h >= _water + 1.5:
			ok = true
			break
	if not ok:
		return
	var cy := _sample_height(cx, cz)
	var center := Vector3(cx, cy, cz)
	# Ring of wrecks + barrels.
	var wrecks := rng.randi_range(3, 5)
	for i in wrecks:
		var a := TAU * float(i) / float(wrecks) + rng.randf_range(-0.3, 0.3)
		var r := rng.randf_range(3.5, 7.0)
		var p := Vector3(cx + cos(a) * r, _sample_height(cx + cos(a) * r, cz + sin(a) * r), cz + sin(a) * r)
		_make_wreck(p, rng.randf_range(0.0, TAU), rng)
	for i in rng.randi_range(6, 10):
		var a := rng.randf() * TAU
		var r := rng.randf_range(1.5, 8.0)
		var p := Vector3(cx + cos(a) * r, _sample_height(cx + cos(a) * r, cz + sin(a) * r), cz + sin(a) * r)
		_make_barrel(p, rng)
	# A worthwhile reward for finding the yard.
	add_pickup("weapon", center + Vector3(0, 0.6, 0), 0, ["rifle", "shotgun", "smg"][rng.randi() % 3])
	add_pickup("ammo", center + Vector3(1.2, 0.5, 0.6), 60)
	# A tall crane-ish marker so the yard is spotted from a distance.
	_visual_box(Vector3(0.4, 9.0, 0.4), center + Vector3(0, 4.5, 0), Color(0.8, 0.7, 0.15))
	_visual_box(Vector3(4.0, 0.4, 0.4), center + Vector3(1.8, 8.6, 0), Color(0.8, 0.7, 0.15))

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

# ---------------------------------------------------------------- feature placement

## Place the landmark-cluster and local-biome features (terrain-shaping ones already
## reshaped the heightmap). Uses the same prop helpers as the rest of the world so
## everything is destructible / consistent, and samples the finished heightmap for Y.
func _place_features(rng: RandomNumberGenerator) -> void:
	for f in _features:
		var cat := String(f["cat"])
		if cat == "terrain":
			continue
		var cx := float(f["x"])
		var cz := float(f["z"])
		var r := float(f["r"])
		match String(f["type"]):
			"crash_site":
				for i in rng.randi_range(2, 4):
					var p := _feat_pt(cx, cz, r * 0.7, rng)
					_make_wreck(p, rng.randf() * TAU, rng)
				for i in rng.randi_range(2, 5):
					_make_barrel(_feat_pt(cx, cz, r * 0.85, rng), rng)
			"ruins":
				for i in rng.randi_range(3, 6):
					var a := rng.randf() * TAU
					var p := _feat_pt2(cx, cz, a, rng.randf_range(2.0, r * 0.7))
					p.y -= 0.3
					_building(rng, p, Color(0.52, 0.50, 0.47), Vector2(cos(a + PI), sin(a + PI)),
						rng.randf_range(5.0, 9.0), rng.randf_range(5.0, 9.0), rng.randf_range(2.4, 3.6), "none", true)
			"monument":
				var stones := rng.randi_range(6, 10)
				for i in stones:
					var a := TAU * float(i) / float(stones)
					var p := _feat_pt2(cx, cz, a, r * 0.7)
					_visual_box(Vector3(1.3, rng.randf_range(3.6, 5.6), 0.9), p + Vector3(0, 2.4, 0), Color(0.5, 0.5, 0.53))
			"campsite":
				for i in rng.randi_range(2, 4):
					var p := _feat_pt(cx, cz, r * 0.7, rng)
					_visual_box(Vector3(2.4, 1.7, 2.8), p + Vector3(0, 0.85, 0), Color(0.55, 0.48, 0.36))
				_visual_box(Vector3(1.4, 0.5, 1.4), Vector3(cx, _sample_height(cx, cz) + 0.25, cz), Color(0.18, 0.14, 0.1))
			"tower":
				add_watchtower(Vector3(cx, _sample_height(cx, cz) - 0.3, cz), rng.randf_range(9.0, 13.0))
			"graveyard":
				for gxi in 4:
					for gzi in 4:
						var p := _feat_pt2(cx, cz, 0.0, 0.0)
						p.x = cx + (float(gxi) - 1.5) * 3.2
						p.z = cz + (float(gzi) - 1.5) * 3.2
						p.y = _sample_height(p.x, p.z)
						_visual_box(Vector3(0.9, 1.1, 0.25), p + Vector3(0, 0.55, 0), Color(0.5, 0.5, 0.52))
			"forest_grove":
				for i in int(r * 0.9):
					var p := _feat_pt(cx, cz, r, rng)
					if p.y > _water + 1.0:
						_add_tree(rng, p, "forest")
			"oasis":
				for i in rng.randi_range(5, 9):
					var p := _feat_pt2(cx, cz, rng.randf() * TAU, rng.randf_range(r * 0.4, r))
					if p.y > _water + 1.0:
						_add_tree(rng, p, "forest")
			"swamp_patch":
				for i in int(r * 0.5):
					var p := _feat_pt(cx, cz, r, rng)
					if p.y > _water:
						_visual_box(Vector3(0.2, rng.randf_range(1.5, 2.6), 0.2), p + Vector3(0, 1.0, 0), Color(0.3, 0.4, 0.2))
			"rocky_field":
				for i in int(r * 0.4):
					var p := _feat_pt(cx, cz, r, rng)
					if p.y > _water:
						_add_boulder(rng, p)
			"dead_forest":
				for i in int(r * 0.6):
					var p := _feat_pt(cx, cz, r, rng)
					if p.y > _water:
						_add_tree(rng, p, "snow")

## A random point within `rad` of a feature centre, snapped to the finished heightmap.
func _feat_pt(cx: float, cz: float, rad: float, rng: RandomNumberGenerator) -> Vector3:
	var a := rng.randf() * TAU
	var d := rad * sqrt(rng.randf())   # uniform over the disc, not clustered at centre
	return _feat_pt2(cx, cz, a, d)

func _feat_pt2(cx: float, cz: float, ang: float, dist: float) -> Vector3:
	var x := cx + cos(ang) * dist
	var z := cz + sin(ang) * dist
	return Vector3(x, _sample_height(x, z), z)

# ---------------------------------------------------------------- villages

## A ring of simple huts around each flattened site, so villages read as places.
func _build_villages(rng: RandomNumberGenerator) -> void:
	var palette := [
		Color(0.55, 0.45, 0.32),  # timber
		Color(0.60, 0.58, 0.54),  # stone
		Color(0.52, 0.38, 0.30),  # clay
		Color(0.66, 0.60, 0.48),  # sandstone
	]
	var bmul := float(_landform.get("builds", 1.0))
	for s in _sites:
		var n := int(round(rng.randi_range(4, 7) * bmul))
		if n <= 0:
			continue   # urban / dungeon landforms build their own structures instead
		for b in n:
			var ang := TAU * float(b) / float(n) + rng.randf_range(-0.3, 0.3)
			# Stay inside the fully-flattened core (< 0.55 r) so buildings sit level.
			var rr := float(s.r) * rng.randf_range(0.26, 0.5)
			var bx := float(s.x) + cos(ang) * rr
			var bz := float(s.z) + sin(ang) * rr
			var by := _sample_height(bx, bz) - 0.3   # sink the foundation a touch
			_add_building(rng, Vector3(bx, by, bz), palette[rng.randi() % palette.size()], ang)

# ---------------------------------------------------------------- city (urban landform)

## Lay a street grid of blocky concrete buildings across the (flattened) map so an "urban"
## theme reads as a real city — dense multi-storey blocks with gaps for streets/plazas.
func _build_city(rng: RandomNumberGenerator) -> void:
	var span := _size * 0.42
	var block := 26.0   # lot + street pitch
	var pal := [Color(0.50, 0.50, 0.53), Color(0.44, 0.45, 0.48), Color(0.56, 0.54, 0.5),
		Color(0.40, 0.42, 0.46), Color(0.48, 0.47, 0.44)]
	var gx := -span
	while gx < span:
		var gz := -span
		while gz < span:
			var cx := gx + block * 0.5 + rng.randf_range(-2.0, 2.0)
			var cz := gz + block * 0.5 + rng.randf_range(-2.0, 2.0)
			gz += block
			if _near_site(cx, cz, 15.0) or rng.randf() < 0.18:
				continue   # keep village plots clear + the odd empty lot / plaza
			var gy := _sample_height(cx, cz)
			if gy < _water + 1.0:
				continue
			var w := block * rng.randf_range(0.5, 0.72)
			var d := block * rng.randf_range(0.5, 0.72)
			var storeys := rng.randi_range(1, 4)
			var col: Color = pal[rng.randi() % pal.size()]
			var face := rng.randf() * TAU
			_building(rng, Vector3(cx, gy - 0.3, cz), col, Vector2(cos(face), sin(face)),
				w, d, 3.4 * storeys, "flat", rng.randf() < 0.12)
		gx += block

# ---------------------------------------------------------------- dungeon landform

## Enclose the (fully-flattened) floor in a roofed stone labyrinth: perimeter walls, a
## ceiling slab, a grid of room walls pierced by doorways, and scattered torches. Reads as
## a dungeon, not open country. Marks the map "dark" so the environment can dim for it.
func _build_dungeon(rng: RandomNumberGenerator) -> void:
	set_meta("dark", true)
	var span := _size * 0.42
	var floor_y := _sample_height(0.0, 0.0)
	var wall_h := 8.0
	var t := 1.2
	var stone := Color(0.32, 0.31, 0.34)
	var span2 := span * 2.0
	# Perimeter walls + a ceiling slab so you're boxed in.
	_collider_box(Vector3(span2, wall_h, t), Vector3(0, floor_y + wall_h * 0.5, -span), stone)
	_collider_box(Vector3(span2, wall_h, t), Vector3(0, floor_y + wall_h * 0.5, span), stone)
	_collider_box(Vector3(t, wall_h, span2), Vector3(-span, floor_y + wall_h * 0.5, 0), stone)
	_collider_box(Vector3(t, wall_h, span2), Vector3(span, floor_y + wall_h * 0.5, 0), stone)
	_collider_box(Vector3(span2, t, span2), Vector3(0, floor_y + wall_h, 0), stone.darkened(0.35))
	# Interior walls on a grid, each broken by a doorway gap so rooms interconnect.
	var cell := 34.0
	var lines := int((span2 - cell) / cell)
	for a in range(1, lines + 1):
		var gx := -span + a * cell
		if gx > span - 4.0:
			break
		_dungeon_wall_line(rng, true, gx, span, floor_y, wall_h, t, stone)
		var gz := -span + a * cell
		if gz <= span - 4.0:
			_dungeon_wall_line(rng, false, gz, span, floor_y, wall_h, t, stone)
	# Torches: emissive posts with a warm point light, along the perimeter.
	var torches := clampi(int(span2 / 18.0), 6, 40)
	for i in torches:
		var edge := i % 4
		var f := rng.randf_range(-span + 6.0, span - 6.0)
		var pos := Vector3(f, floor_y + 3.2, -span + 1.6)
		if edge == 1: pos = Vector3(f, floor_y + 3.2, span - 1.6)
		elif edge == 2: pos = Vector3(-span + 1.6, floor_y + 3.2, f)
		elif edge == 3: pos = Vector3(span - 1.6, floor_y + 3.2, f)
		_dungeon_torch(pos, floor_y)

## One interior wall running the width/depth of the dungeon with a random doorway gap.
func _dungeon_wall_line(rng: RandomNumberGenerator, vertical: bool, at: float, span: float,
		floor_y: float, wall_h: float, t: float, col: Color) -> void:
	var seg := 30.0
	var gap := rng.randf_range(-span + seg, span - seg)   # doorway centre
	var p := -span
	while p < span:
		var length := minf(seg, span - p)
		var c := p + length * 0.5
		p += seg
		if absf(c - gap) < 6.0:
			continue   # leave a doorway
		if vertical:
			_collider_box(Vector3(t, wall_h, length), Vector3(at, floor_y + wall_h * 0.5, c), col)
		else:
			_collider_box(Vector3(length, wall_h, t), Vector3(c, floor_y + wall_h * 0.5, at), col)

## A wall torch: a small emissive block plus a warm omni light for the torch-lit look.
func _dungeon_torch(pos: Vector3, _floor_y: float) -> void:
	_visual_box(Vector3(0.3, 0.6, 0.3), pos, Color(1.0, 0.6, 0.25))
	var light := OmniLight3D.new()
	light.omni_range = 12.0
	light.light_energy = 2.6
	light.light_color = Color(1.0, 0.62, 0.32)
	light.position = pos + Vector3(0, 0.6, 0)
	region.add_child(light)

## A watchtower (with a climbable ladder) at roughly every other village — a vantage
## point and a clear use for the new ladder-climbing.
func _build_watchtowers(rng: RandomNumberGenerator) -> void:
	for k in _sites.size():
		if k % 2 != 0:
			continue
		var s: Dictionary = _sites[k]
		var bx := float(s.x) + rng.randf_range(-8.0, 8.0)
		var bz := float(s.z) + rng.randf_range(-8.0, 8.0)
		add_watchtower(Vector3(bx, _sample_height(bx, bz) - 0.3, bz), rng.randf_range(7.0, 10.0))

## Pick a building variant for variety: small hut, long house (peaked roof), watch
## tower (tall, crenellated), or a roofless ruin.
func _add_building(rng: RandomNumberGenerator, c: Vector3, col: Color, face: float) -> void:
	var door_dir := Vector2(cos(face + PI), sin(face + PI))  # toward the village centre
	match rng.randi() % 6:
		0, 1:  # hut
			_building(rng, c, col, door_dir, rng.randf_range(5.0, 8.0), rng.randf_range(5.0, 8.0), rng.randf_range(3.0, 4.2), "flat", false)
		2:     # long house
			_building(rng, c, col, door_dir, rng.randf_range(10.0, 14.0), rng.randf_range(6.0, 9.0), rng.randf_range(3.4, 4.4), "peak", false)
		3:     # stone tower
			_building(rng, c, col, door_dir, rng.randf_range(3.6, 4.6), rng.randf_range(3.6, 4.6), rng.randf_range(7.0, 10.0), "rim", false)
		_:     # ruin
			_building(rng, c, col, door_dir, rng.randf_range(5.0, 8.0), rng.randf_range(5.0, 8.0), rng.randf_range(2.4, 3.2), "none", true)

func _building(rng: RandomNumberGenerator, c: Vector3, col: Color, door_dir: Vector2, w: float, d: float, ht: float, roof: String, ruin: bool) -> void:
	var t := 0.4
	_walls_box(rng, c, w, d, ht, t, col, door_dir, ruin)
	match roof:
		"flat":
			_collider_box(Vector3(w + t, 0.4, d + t), Vector3(c.x, c.y + ht + 0.2, c.z), col.darkened(0.25))
		"peak":
			_peaked_roof(c, w + t, d + t, c.y + ht, col.darkened(0.3))
		"rim":  # tower crown: a slab + corner merlons
			_collider_box(Vector3(w + t, 0.4, d + t), Vector3(c.x, c.y + ht + 0.2, c.z), col.darkened(0.25))
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					_collider_box(Vector3(0.5, 0.9, 0.5), Vector3(c.x + sx * w * 0.5, c.y + ht + 0.65, c.z + sz * d * 0.5), col)
		"none":
			pass  # ruins are open to the sky

## Four walls with a doorway on the wall facing `door_dir`. Ruins are shorter and may
## be missing walls.
func _walls_box(rng: RandomNumberGenerator, c: Vector3, w: float, d: float, ht: float, t: float, col: Color, door_dir: Vector2, ruin: bool) -> void:
	var hw := w * 0.5
	var hd := d * 0.5
	var south := absf(door_dir.y) >= absf(door_dir.x) and door_dir.y < 0.0
	var north := absf(door_dir.y) >= absf(door_dir.x) and door_dir.y >= 0.0
	var west := absf(door_dir.x) > absf(door_dir.y) and door_dir.x < 0.0
	var east := absf(door_dir.x) > absf(door_dir.y) and door_dir.x >= 0.0
	_wall_run(rng, Vector3(c.x, c.y, c.z + hd), true, w, ht, t, south, col, ruin)
	_wall_run(rng, Vector3(c.x, c.y, c.z - hd), true, w, ht, t, north, col, ruin)
	_wall_run(rng, Vector3(c.x - hw, c.y, c.z), false, d, ht, t, west, col, ruin)
	_wall_run(rng, Vector3(c.x + hw, c.y, c.z), false, d, ht, t, east, col, ruin)

## One wall along X or Z, optionally with a centred doorway gap.
func _wall_run(rng: RandomNumberGenerator, pos: Vector3, along_x: bool, length: float, ht: float, t: float, door: bool, col: Color, ruin: bool) -> void:
	var wh := ht
	if ruin:
		if rng.randf() < 0.3:
			return                              # collapsed wall
		wh = ht * rng.randf_range(0.35, 0.8)    # crumbled to varying heights
	var y0 := pos.y
	var dw := 2.4
	if not door or length <= dw + 1.2:
		if along_x:
			_collider_box(Vector3(length, wh, t), Vector3(pos.x, y0 + wh * 0.5, pos.z), col)
		else:
			_collider_box(Vector3(t, wh, length), Vector3(pos.x, y0 + wh * 0.5, pos.z), col)
		return
	var seg := (length - dw) * 0.5
	var off := dw * 0.5 + seg * 0.5
	var lintel := maxf(0.0, wh - 2.4)
	if along_x:
		_collider_box(Vector3(seg, wh, t), Vector3(pos.x - off, y0 + wh * 0.5, pos.z), col)
		_collider_box(Vector3(seg, wh, t), Vector3(pos.x + off, y0 + wh * 0.5, pos.z), col)
		if lintel > 0.1:
			_collider_box(Vector3(dw, lintel, t), Vector3(pos.x, y0 + 2.4 + lintel * 0.5, pos.z), col)
	else:
		_collider_box(Vector3(t, wh, seg), Vector3(pos.x, y0 + wh * 0.5, pos.z - off), col)
		_collider_box(Vector3(t, wh, seg), Vector3(pos.x, y0 + wh * 0.5, pos.z + off), col)
		if lintel > 0.1:
			_collider_box(Vector3(t, lintel, dw), Vector3(pos.x, y0 + 2.4 + lintel * 0.5, pos.z), col)

## A stepped pyramid roof (a few diminishing slabs) for peaked-roof buildings.
func _peaked_roof(c: Vector3, w: float, d: float, top_y: float, col: Color) -> void:
	for i in 3:
		var f := 1.0 - float(i) * 0.3
		_collider_box(Vector3(w * f, 0.5, d * f), Vector3(c.x, top_y + 0.2 + float(i) * 0.5, c.z), col.darkened(float(i) * 0.04))

# ---------------------------------------------------------------- caves

## Enclosable rock shelters at mountain bases (a heightmap can't carve true tunnels,
## so these are open-mouthed boulder rings with loot tucked inside).
func _add_caves(rng: RandomNumberGenerator) -> void:
	var want := clampi(int(_size / 360.0 * float(_landform.get("caves", 1.0))), 0, 12)
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
	_place_boats(vrng)
	# Adventure: one helicopter near the first village so the sky-islands are reachable.
	if Game.is_adventure() and not _sites.is_empty():
		var s: Dictionary = _sites[0]
		add_helicopter(Vector3(float(s.x) + float(s.r) * 0.8, float(s.h), float(s.z)), vrng.randf_range(0.0, 360.0))

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

## A few amphibious boats moored in shallow water near the shoreline. Found by probing
## random points for the waterline (land just below the water plane), so they only
## appear on maps that actually have coast. Deterministic from the seed.
func _place_boats(rng: RandomNumberGenerator) -> void:
	var want := clampi(int(_size / 320.0), 1, 4)
	var placed := 0
	var half := _size * 0.5 - 12.0
	for _attempt in 240:
		if placed >= want:
			break
		var x := rng.randf_range(-half, half)
		var z := rng.randf_range(-half, half)
		var lh := _land_height(x, z)
		# Shallow water just off a beach: sea bed a touch below the surface.
		if lh < _water - 4.0 or lh > _water - 0.5:
			continue
		# Face the boat toward deeper water (down the height gradient).
		var gx := _land_height(x + 4.0, z) - _land_height(x - 4.0, z)
		var gz := _land_height(x, z + 4.0) - _land_height(x, z - 4.0)
		var yaw := rad_to_deg(atan2(gx, gz))   # +Z nose points downhill (toward sea)
		add_boat(Vector3(x, _water, z), yaw)
		placed += 1

# ---------------------------------------------------------------- floating islands

## Decorative sky-islands floating high above the map, each with a flat walkable top
## carrying a loot cache. Reachable by helicopter. Visual cone underside + solid top
## collider (layer 1, parented to the map so it's never baked into the navmesh).
func _add_floating_islands(rng: RandomNumberGenerator) -> void:
	var count := clampi(int(_size / 300.0), 1, 4)
	var half := _size * 0.5 - 60.0
	if half < 40.0:
		return
	var loot_weapons := ["rifle", "shotgun", "smg", "sniper"]
	var loot_armor := ["helmet", "vest", "leg_armor"]
	for k in count:
		var cx := rng.randf_range(-half, half)
		var cz := rng.randf_range(-half, half)
		# Kept within the helicopter's climb ceiling (~70 m above its low spawn) so the
		# islands are actually reachable, while still reading as high sky-islands.
		var cy := _water + rng.randf_range(45.0, 66.0)
		var radius := rng.randf_range(11.0, 17.0)
		_build_floating_island(Vector3(cx, cy, cz), radius, rng)
		# Loot on top: a weapon, a piece of armor, a cash pile, and a medkit.
		var top := Vector3(cx, cy + 1.6, cz)
		add_pickup("weapon", top + Vector3(2.0, 0, 0), 0, loot_weapons[k % loot_weapons.size()])
		add_pickup("armor", top + Vector3(-2.0, 0, 1.0), 0, loot_armor[k % loot_armor.size()])
		add_pickup("money", top + Vector3(0, 0, -2.0), rng.randi_range(60, 140))
		add_pickup("health", top + Vector3(0, 0, 2.5), 50)

func _build_floating_island(center: Vector3, radius: float, rng: RandomNumberGenerator) -> void:
	var grass := Color(0.34, 0.55, 0.28)
	var rock := Color(0.42, 0.36, 0.3)
	# Flat top platform (walkable) with a cylinder collider.
	var top := StaticBody3D.new()
	top.collision_layer = 1
	top.collision_mask = 0
	top.position = center
	add_child(top)   # parented to the map, NOT the nav region -> not baked
	var top_mi := MeshInstance3D.new()
	var top_cyl := CylinderMesh.new()
	top_cyl.top_radius = radius
	top_cyl.bottom_radius = radius
	top_cyl.height = 3.0
	top_mi.mesh = top_cyl
	var gm := StandardMaterial3D.new()
	gm.albedo_color = grass
	gm.roughness = 1.0
	top_mi.material_override = gm
	top.add_child(top_mi)
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = radius
	sh.height = 3.0
	cs.shape = sh
	top.add_child(cs)
	# Tapered rocky underside (visual only) hanging below the platform.
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius * 0.95
	cm.bottom_radius = 0.6
	cm.height = radius * 1.4
	cone.mesh = cm
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = rock
	rmat.roughness = 1.0
	cone.material_override = rmat
	cone.position = Vector3(0, -(radius * 0.7 + 1.5), 0)
	top.add_child(cone)
	# A couple of decorative boulders on top so it reads as terrain, not a disc.
	for _i in 3:
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var bs := rng.randf_range(1.2, 2.6)
		bm.size = Vector3(bs, bs * 0.8, bs)
		b.mesh = bm
		b.material_override = rmat
		var a := rng.randf() * TAU
		var rr := rng.randf_range(0.0, radius * 0.7)
		b.position = Vector3(cos(a) * rr, 1.8, sin(a) * rr)
		top.add_child(b)

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
