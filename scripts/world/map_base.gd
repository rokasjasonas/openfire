extends Node3D
class_name MapBase
## Base class for maps. Subclasses override build_level() to place geometry,
## spawns and objective zones using the helpers below. Geometry is built in code
## and the navmesh is baked at runtime, so maps stay tiny and data-light.

const TEX_DIR := "res://assets/kenney/prototype-textures/PNG/"

const PICKUP_SCENE := preload("res://scenes/pickup.tscn")

var region: NavigationRegion3D
var _tex_cache: Dictionary = {}
var _pickup_count: int = 0

func _ready() -> void:
	add_to_group("map")
	_build_environment()
	region = NavigationRegion3D.new()
	region.name = "NavRegion"
	region.add_to_group("nav_region")
	var nm := NavigationMesh.new()
	# Match the NavigationServer map defaults (0.25) to avoid rasterization mismatch.
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.agent_radius = 0.5
	nm.agent_height = 1.8
	nm.agent_max_climb = 0.6
	nm.agent_max_slope = 50.0
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	region.navigation_mesh = nm
	add_child(region)
	build_level()
	region.bake_navigation_mesh(false)

func build_level() -> void:
	pass  # override in subclass

# ---------------------------------------------------------------- environment

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	we.environment = load("res://resources/default_env.tres")
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -45, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

# ---------------------------------------------------------------- geometry

func _material(color: String, idx: int, density: float = 0.5) -> StandardMaterial3D:
	var key := "%s_%d" % [color, idx]
	if _tex_cache.has(key):
		var cached: StandardMaterial3D = _tex_cache[key]
		var m := cached.duplicate()
		m.uv1_scale = Vector3(density, density, density)
		return m
	var path := "%s%s/texture_%02d.png" % [TEX_DIR, color, idx]
	var mat := StandardMaterial3D.new()
	if ResourceLoader.exists(path):
		mat.albedo_texture = load(path)
	else:
		mat.albedo_color = Color(0.5, 0.5, 0.55)
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(density, density, density)
	_tex_cache[key] = mat
	return mat

## Add a textured box that is BOTH visible geometry and a static collider, and is
## parsed into the navmesh (so bots route around it).
func add_box(size: Vector3, pos: Vector3, color: String = "Dark", idx: int = 13) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _material(color, idx)
	mi.position = pos
	region.add_child(mi)
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	mi.add_child(sb)
	return mi

func add_floor(sx: float, sz: float, color: String = "Dark", idx: int = 13) -> void:
	add_box(Vector3(sx, 1.0, sz), Vector3(0, -0.5, 0), color, idx)

func add_wall(size: Vector3, pos: Vector3, color: String = "Orange", idx: int = 13) -> void:
	add_box(size, pos, color, idx)

func add_cover(pos: Vector3, color: String = "Green", idx: int = 13) -> void:
	add_box(Vector3(2, 1.4, 2), pos + Vector3(0, 0.7, 0), color, idx)

func add_ramp(size: Vector3, pos: Vector3, angle_deg: float, color: String = "Purple", idx: int = 13) -> void:
	var mi := add_box(size, Vector3.ZERO, color, idx)
	mi.position = pos
	mi.rotation_degrees = Vector3(angle_deg, 0, 0)
	# Re-orient the child collider with the mesh (it inherits the transform).

## Add a walkable ramp slab bridging two world points (bottom -> top). The slab's
## top surface lets players and bots travel between two heights; keep the slope
## under ~45° so the navmesh treats it as walkable.
func add_slope(bottom: Vector3, top: Vector3, width: float = 4.0, color: String = "Purple", idx: int = 13) -> void:
	var delta := top - bottom
	var horiz := Vector2(delta.x, delta.z).length()
	var run := sqrt(horiz * horiz + delta.y * delta.y)
	if run < 0.01:
		return
	var mi := add_box(Vector3(width, 0.5, run), Vector3.ZERO, color, idx)
	var fwd := delta.normalized()
	var right := Vector3.UP.cross(fwd)
	if right.length() < 0.001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := fwd.cross(right).normalized()
	var t := Transform3D(Basis(right, up, fwd), (bottom + top) * 0.5)
	mi.transform = t

## Decorative crate prop (small collider, not added to navmesh).
func add_crate(glb: String, pos: Vector3, scale: float = 1.0) -> void:
	if not ResourceLoader.exists(glb):
		return
	var packed: PackedScene = load(glb)
	var inst := packed.instantiate()
	inst.position = pos
	inst.scale = Vector3.ONE * scale
	add_child(inst)
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.9, 0.9, 0.9) * scale
	cs.shape = shape
	cs.position = Vector3(0, 0.45 * scale, 0)
	sb.add_child(cs)
	add_child(sb)
	sb.position = pos

# ---------------------------------------------------------------- spawns / zones

func add_spawn(pos: Vector3, enemy: bool = false) -> void:
	var m := Marker3D.new()
	m.position = pos
	m.add_to_group("spawn_enemy" if enemy else "spawn_player")
	add_child(m)

## Place a pickup. Deterministic names keep RPC paths identical across peers.
func add_pickup(kind: String, pos: Vector3, amount: int = 25, weapon_id: String = "shotgun") -> void:
	var p := PICKUP_SCENE.instantiate()
	p.name = "Pickup_%d_%s" % [_pickup_count, kind]
	_pickup_count += 1
	p.kind = kind
	p.amount = amount
	p.weapon_id = weapon_id
	p.position = pos
	add_child(p)

func add_zone(zone_id: String, pos: Vector3, size: Vector3) -> void:
	var area := Area3D.new()
	area.name = "Zone_" + zone_id
	area.position = pos
	area.collision_layer = 0
	area.collision_mask = 2  # detect players
	area.add_to_group("zone")
	area.set_meta("zone_id", zone_id)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	area.add_child(cs)
	# A faint marker so the objective zone is visible in-world.
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size.x, 0.1, size.z)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.8, 1.0, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.7, 1.0)
	mi.material_override = mat
	mi.position = Vector3(0, -size.y * 0.5 + 0.06, 0)
	area.add_child(mi)
	add_child(area)
