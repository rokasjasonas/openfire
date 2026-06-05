extends Node3D
## A friendly VIP / payload the players must escort to a destination. The host moves
## it toward its goal but only while at least one living player walks alongside it;
## position is replicated to clients (lerped) via RPC. The objective runner polls
## `arrived`. Built procedurally — no scene file.

var combatant_id: int = 0
var dest: Vector3 = Vector3.ZERO
var speed: float = 2.4
var arrived: bool = false
var team: int = 0  # allied

const NEAR_RADIUS := 10.0

var sync_pos: Vector3 = Vector3.ZERO
var _net_t: float = 0.0
var _label: Label3D
var _ring: MeshInstance3D

func setup(id: int, destination: Vector3, mv_speed: float) -> void:
	combatant_id = id
	dest = destination
	speed = mv_speed

func _ready() -> void:
	add_to_group("escort")
	sync_pos = global_position
	_build_visual()
	set_process(true)

func _build_visual() -> void:
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.5
	cap.height = 1.9
	body.mesh = cap
	body.position = Vector3(0, 1.0, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.9, 0.5)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.8, 0.4)
	mat.emission_energy_multiplier = 0.5
	body.material_override = mat
	add_child(body)

	_label = Label3D.new()
	_label.text = "VIP"
	_label.position = Vector3(0, 2.4, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(0.5, 1.0, 0.6)
	_label.font_size = 52
	_label.outline_size = 8
	_label.no_depth_test = true
	add_child(_label)

func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		global_position = global_position.lerp(sync_pos, clampf(8.0 * delta, 0.0, 1.0))
		return
	if not arrived:
		_host_step(delta)
	sync_pos = global_position
	_net_t += delta
	if _net_t >= 0.1:
		_net_t = 0.0
		_net_pos.rpc(global_position)

func _host_step(delta: float) -> void:
	# Advance only when escorted (a living player nearby).
	var escorting := false
	for p in get_tree().get_nodes_in_group("player"):
		if p.get("dead") or p.get("fully_dead") or p.get("downed"):
			continue
		if global_position.distance_to(p.global_position) < NEAR_RADIUS:
			escorting = true
			break
	if not escorting:
		return
	var to := dest - global_position
	to.y = 0.0
	var d := to.length()
	if d <= 1.5:
		arrived = true
		global_position = Vector3(dest.x, global_position.y, dest.z)
		return
	var step: Vector3 = to.normalized() * minf(speed * delta, d)
	global_position += step
	_ground_snap()

## Keep the VIP sitting on the floor as it crosses ramps / uneven ground.
func _ground_snap() -> void:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 3.0
	var to := global_position + Vector3.DOWN * 6.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1  # world geometry
	var res := space.intersect_ray(q)
	if res:
		global_position.y = res.position.y

@rpc("authority", "call_local", "unreliable")
func _net_pos(p: Vector3) -> void:
	sync_pos = p
