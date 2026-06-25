extends CharacterBody3D
## Arcade amphibious boat. Enter like any vehicle; drive with throttle (forward/back)
## and steer (A/D). Rides on top of the water plane, and falls back to riding the
## ground when beached, so it never sinks through the world (keeps bots safe too).
## Driver-authoritative + replicated, like the car and the helicopter.

const MAX_HEALTH := 240.0
const RESPAWN_TIME := 16.0
const MAX_FWD := 17.0       # top forward speed on water
const MAX_REV := 7.0        # top reverse speed
const FWD_ACCEL := 1.4
const YAW_RATE := 1.5       # rad/s at full throttle
const HOVER := 0.35         # how high the hull rides above the surface
const BOB_AMP := 0.12       # gentle idle bob

var driver_id: int = 0
var driver_team: int = -999
var health: float = MAX_HEALTH
var destroyed: bool = false
var seat_offset := Vector3(0, 1.2, 0)

var sync_pos: Vector3
var sync_yaw: float = 0.0

var _throttle := 0.0
var _steer := 0.0
var _speed := 0.0
var _respawn_timer := 0.0
var _spawn_pos: Vector3
var _spawn_yaw := 0.0
var _water_y: float = -1.0e20
var _bob_t := 0.0
var _wake: CPUParticles3D
var _body: Node3D

func _ready() -> void:
	add_to_group("vehicle")
	add_to_group("boat")
	_spawn_pos = global_position
	_spawn_yaw = rotation.y
	sync_pos = global_position
	sync_yaw = rotation.y
	_build_visual()
	_make_wake()
	_update_water_level()
	_update_authority()
	set_process(true)

func _update_authority() -> void:
	var auth := driver_id if driver_id > 0 else 1
	set_multiplayer_authority(auth)

func _update_water_level() -> void:
	var best := -1.0e20
	for node in get_tree().get_nodes_in_group("water"):
		best = maxf(best, node.global_position.y)
	if best > -1.0e19:
		_water_y = best

# ---------------------------------------------------------------- vehicle interface

func is_occupied() -> bool:
	return driver_id != 0 or destroyed

func seat_position() -> Vector3:
	return global_transform * seat_offset

func forward() -> Vector3:
	return global_transform.basis.z.normalized()  # nose is +Z

func speed() -> float:
	return absf(_speed)

func type_name() -> String:
	return "Boat"

func set_drive(throttle: float, steer: float, _brake: float) -> void:
	_throttle = throttle
	_steer = steer

func request_flip() -> void:
	pass  # boats self-right via surface riding; nothing to do

# ---------------------------------------------------------------- physics

## Surface the hull should ride: the higher of the water plane and the ground below,
## so the boat floats on water but rests on the beach when driven ashore.
func _surface_y() -> float:
	var ground := -1.0e20
	var space := get_world_3d().direct_space_state
	if space != null:
		var from := global_position + Vector3.UP * 6.0
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 40.0)
		q.collision_mask = 1
		q.exclude = [get_rid()]
		var res := space.intersect_ray(q)
		if res:
			ground = res.position.y
	return maxf(_water_y, ground)

func _physics_process(delta: float) -> void:
	if destroyed:
		if is_multiplayer_authority():
			_respawn_timer -= delta
			if _respawn_timer <= 0.0:
				_do_respawn()
		return
	if is_multiplayer_authority():
		_bob_t += delta
		# Steering only bites when the boat is actually moving.
		var move_frac := clampf(_speed / MAX_FWD, -1.0, 1.0)
		rotation.y += _steer * YAW_RATE * move_frac * delta
		var target := _throttle * (MAX_FWD if _throttle >= 0.0 else MAX_REV)
		_speed = move_toward(_speed, target, FWD_ACCEL * MAX_FWD * delta)
		var fwd := global_transform.basis.z
		velocity.x = fwd.x * _speed
		velocity.z = fwd.z * _speed
		# Ride the surface: ease the hull onto the water/ground with a gentle bob.
		var rest := _surface_y() + HOVER + sin(_bob_t * 1.7) * BOB_AMP
		velocity.y = (rest - global_position.y) * 6.0
		move_and_slide()
		_update_wake()
		sync_pos = global_position
		sync_yaw = rotation.y
	else:
		var t := clampf(15.0 * delta, 0.0, 1.0)
		global_position = global_position.lerp(sync_pos, t)
		rotation.y = lerp_angle(rotation.y, sync_yaw, t)
		_update_wake()

func _update_wake() -> void:
	if _wake:
		_wake.emitting = not destroyed and speed() > 2.0

# ---------------------------------------------------------------- enter / exit

func enter(peer_id: int, team: int) -> void:
	_set_occupant.rpc(peer_id, team)

func exit() -> void:
	_set_occupant.rpc(0, -999)

@rpc("any_peer", "call_local", "reliable")
func _set_occupant(peer_id: int, team: int) -> void:
	driver_id = peer_id
	driver_team = team
	if peer_id == 0:
		_throttle = 0.0
		_steer = 0.0
	_update_authority()

# ---------------------------------------------------------------- damage

func hit(amount: float, attacker_id: int, _zone: String = "") -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, attacker_id: int) -> void:
	if destroyed:
		return
	health = maxf(0.0, health - amount)
	if health <= 0.0:
		_destroy(attacker_id)

func _destroy(attacker_id: int) -> void:
	if destroyed:
		return
	if is_multiplayer_authority():
		for c in get_tree().get_nodes_in_group("combatant"):
			if not is_instance_valid(c) or c.get("dead"):
				continue
			var d := global_position.distance_to(c.global_position)
			if d < 6.0 and c.has_method("hit"):
				c.hit(70.0 * (1.0 - d / 6.0), attacker_id)
		_respawn_timer = RESPAWN_TIME
	driver_id = 0
	_set_destroyed.rpc(true)
	_update_authority()

@rpc("authority", "call_local", "reliable")
func _set_destroyed(v: bool) -> void:
	destroyed = v
	if v:
		_explosion_fx()
		visible = false
		$CollisionShape3D.disabled = true
	else:
		health = MAX_HEALTH
		visible = true
		$CollisionShape3D.disabled = false
		global_position = _spawn_pos
		rotation.y = _spawn_yaw
		velocity = Vector3.ZERO
		_speed = 0.0

func _do_respawn() -> void:
	_set_destroyed.rpc(false)

func _explosion_fx() -> void:
	Audio.play_3d("res://assets/audio/death.ogg", global_position, 6.0, 0.05)
	var scene := get_tree().current_scene
	if scene == null:
		return
	var fx: Node3D = load("res://scenes/fx/impact.tscn").instantiate()
	scene.add_child(fx)
	fx.global_position = global_position
	fx.scale = Vector3.ONE * 7.0

# ---------------------------------------------------------------- visual

func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi

func _build_visual() -> void:
	_body = Node3D.new()
	add_child(_body)
	var hull := Color(0.75, 0.72, 0.66)
	var trim := Color(0.2, 0.35, 0.55)
	var wood := Color(0.45, 0.32, 0.2)
	_box(_body, Vector3(2.4, 0.7, 5.6), Vector3(0, 0.1, 0), hull)         # hull
	_box(_body, Vector3(2.0, 0.5, 1.4), Vector3(0, 0.7, 1.4), trim)       # bow deck
	_box(_body, Vector3(2.2, 0.6, 2.0), Vector3(0, 0.55, -0.6), wood)     # cockpit floor
	_box(_body, Vector3(0.18, 0.55, 1.8), Vector3(-1.1, 0.55, -0.6), trim)  # left gunwale
	_box(_body, Vector3(0.18, 0.55, 1.8), Vector3(1.1, 0.55, -0.6), trim)   # right gunwale
	_box(_body, Vector3(1.0, 1.0, 0.2), Vector3(0, 1.1, -1.4), trim)     # windshield/console
	_box(_body, Vector3(0.5, 0.7, 0.5), Vector3(0, 0.7, -2.7), Color(0.15, 0.15, 0.15))  # outboard motor

func _make_wake() -> void:
	_wake = CPUParticles3D.new()
	_wake.emitting = false
	_wake.amount = 24
	_wake.lifetime = 0.9
	_wake.position = Vector3(0, 0.1, -2.8)  # behind the stern
	_wake.direction = Vector3(0, 0.4, -1)
	_wake.spread = 18.0
	_wake.initial_velocity_min = 1.0
	_wake.initial_velocity_max = 3.0
	_wake.gravity = Vector3(0, -1.5, 0)
	_wake.scale_amount_min = 0.4
	_wake.scale_amount_max = 1.0
	var mesh := SphereMesh.new()
	mesh.radius = 0.2
	mesh.height = 0.4
	mesh.radial_segments = 6
	mesh.rings = 3
	_wake.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.85, 0.92, 1.0, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wake.mesh.surface_set_material(0, mat)
	add_child(_wake)
