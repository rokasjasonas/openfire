extends Node3D
## Battle-royale storm wall: a tall translucent cylinder that marks the safe-zone
## boundary. The host drives its radius/centre (see world.gd) and replicates them;
## standing outside the ring takes escalating damage. Purely visual — no collision.

const WALL_HEIGHT := 140.0

var radius: float = 200.0
var _mesh: MeshInstance3D
var _mat: StandardMaterial3D

func _ready() -> void:
	add_to_group("storm")
	_build()
	set_radius(radius)

func _build() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0      # unit radius — scaled to `radius` in set_radius()
	cyl.bottom_radius = 1.0
	cyl.height = WALL_HEIGHT
	cyl.radial_segments = 72
	cyl.cap_top = false
	cyl.cap_bottom = false
	_mesh.mesh = cyl
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.7, 0.2, 1.0, 0.16)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from inside the safe zone too
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.emission_enabled = true
	_mat.emission = Color(0.6, 0.15, 1.0)
	_mat.emission_energy_multiplier = 1.4
	_mesh.mesh.material = _mat
	_mesh.position.y = WALL_HEIGHT * 0.5
	add_child(_mesh)

func set_radius(r: float) -> void:
	radius = maxf(r, 0.5)
	if _mesh:
		_mesh.scale = Vector3(radius, 1.0, radius)

func set_center(c: Vector3) -> void:
	global_position = Vector3(c.x, 0.0, c.z)

## Horizontal distance from the safe-zone centre; > radius means "in the storm".
func is_outside(pos: Vector3) -> bool:
	var d := Vector2(pos.x - global_position.x, pos.z - global_position.z).length()
	return d > radius
