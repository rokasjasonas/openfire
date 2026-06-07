extends CharacterBody3D
## Arcade gunship helicopter. Enter like a vehicle; fly with throttle (forward),
## yaw (A/D), and vertical (Space up / Ctrl down). Fires a hitscan nose gun angled
## down for strafing. Driver-authoritative + replicated; bots can fly it too.

const MAX_HEALTH := 220.0
const RESPAWN_TIME := 16.0
const LIFT := 14.0          # max climb/descend speed
const MAX_FWD := 24.0       # max forward speed
const FWD_ACCEL := 0.9
const YAW_RATE := 1.7
const FIRE_RATE := 9.0
const FIRE_DAMAGE := 16.0
const FIRE_RANGE := 220.0
const MAX_ALTITUDE := 70.0  # ceiling above spawn height
const HIT_MASK := 1 | 16

var driver_id: int = 0
var driver_team: int = -999
var health: float = MAX_HEALTH
var destroyed: bool = false
var seat_offset := Vector3(0, 0.6, 0)

var sync_pos: Vector3
var sync_yaw: float = 0.0

var _throttle := 0.0
var _yaw_in := 0.0
var _vert := 0.0
var _fire_cd := 0.0
var _respawn_timer := 0.0
var _spawn_pos: Vector3
var _spawn_yaw := 0.0
var _rotor: Node3D
var _tail_rotor: Node3D
var _body: Node3D

func _ready() -> void:
	add_to_group("vehicle")
	add_to_group("aircraft")
	_spawn_pos = global_position
	_spawn_yaw = rotation.y
	sync_pos = global_position
	sync_yaw = rotation.y
	_build_visual()
	_update_authority()
	set_process(true)

func _update_authority() -> void:
	var auth := driver_id if driver_id > 0 else 1
	set_multiplayer_authority(auth)

func is_occupied() -> bool:
	return driver_id != 0 or destroyed

func seat_position() -> Vector3:
	return global_transform * seat_offset

func forward() -> Vector3:
	# Model nose is +Z; fly nose-first.
	return global_transform.basis.z.normalized()

func speed() -> float:
	return velocity.length()

func type_name() -> String:
	return "Helicopter"

# ---------------------------------------------------------------- flight

func set_fly(throttle: float, yaw: float, vertical: float) -> void:
	_throttle = throttle
	_yaw_in = yaw
	_vert = vertical

func _physics_process(delta: float) -> void:
	if destroyed:
		if is_multiplayer_authority():
			_respawn_timer -= delta
			if _respawn_timer <= 0.0:
				_do_respawn()
		return
	if is_multiplayer_authority():
		if _fire_cd > 0.0:
			_fire_cd -= delta
		rotation.y += _yaw_in * YAW_RATE * delta
		velocity.y = move_toward(velocity.y, _vert * LIFT, 22.0 * delta)
		var fwd := global_transform.basis.z  # nose-first
		var target := fwd * (_throttle * MAX_FWD)
		velocity.x = lerpf(velocity.x, target.x, FWD_ACCEL * delta * 4.0)
		velocity.z = lerpf(velocity.z, target.z, FWD_ACCEL * delta * 4.0)
		move_and_slide()
		# Altitude ceiling.
		var ceil_y := _spawn_pos.y + MAX_ALTITUDE
		if global_position.y > ceil_y:
			global_position.y = ceil_y
			velocity.y = minf(velocity.y, 0.0)
		# Visual lean for feel.
		if _body:
			_body.rotation.x = lerpf(_body.rotation.x, -_throttle * 0.25, 6.0 * delta)
			_body.rotation.z = lerpf(_body.rotation.z, -_yaw_in * 0.2, 6.0 * delta)
		sync_pos = global_position
		sync_yaw = rotation.y
	else:
		var t := clampf(15.0 * delta, 0.0, 1.0)
		global_position = global_position.lerp(sync_pos, t)
		rotation.y = lerp_angle(rotation.y, sync_yaw, t)

func _process(delta: float) -> void:
	if _rotor:
		_rotor.rotation.y += 30.0 * delta
	if _tail_rotor:
		_tail_rotor.rotation.x += 40.0 * delta

# ---------------------------------------------------------------- gun

func request_fire(aim_point: Vector3 = Vector3.INF) -> void:
	if _fire_cd > 0.0 or destroyed or not is_multiplayer_authority():
		return
	_fire_cd = 1.0 / FIRE_RATE
	var origin := global_position + forward() * 3.5
	# Aim toward where the driver is looking (under the crosshair); else straight ahead.
	var dir := forward() if aim_point == Vector3.INF else (aim_point - origin).normalized()
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * FIRE_RANGE)
	q.collision_mask = HIT_MASK
	q.collide_with_areas = true
	var res := space.intersect_ray(q)
	var endpoint := origin + dir * FIRE_RANGE
	if res:
		endpoint = res.position
		var col = res.collider
		var victim: Node = null
		if col is Hitbox:
			victim = col.combatant()
		elif col and (col.is_in_group("combatant") or col.is_in_group("vehicle")):
			victim = col
		if victim and victim != self and victim.has_method("hit") and victim.get("team") != driver_team:
			victim.hit(FIRE_DAMAGE, driver_id)
	_fire_fx.rpc(origin, endpoint)

@rpc("any_peer", "call_local", "unreliable")
func _fire_fx(from: Vector3, to: Vector3) -> void:
	Audio.play_3d("res://assets/audio/fire_smg.ogg", from, -1.0, 0.1)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	var dist := from.distance_to(to)
	box.size = Vector3(0.05, 0.05, dist)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.9, 0.4)
	mesh.material_override = mat
	get_tree().current_scene.add_child(mesh)
	mesh.global_position = (from + to) * 0.5
	if dist > 0.05:
		mesh.look_at(to, Vector3.UP)
	var tw := mesh.create_tween()
	tw.tween_property(mesh, "transparency", 1.0, 0.06)
	tw.tween_callback(mesh.queue_free)

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
		_yaw_in = 0.0
		_vert = 0.0
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
			if d < 7.0 and c.has_method("hit"):
				c.hit(90.0 * (1.0 - d / 7.0), attacker_id)
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
	fx.scale = Vector3.ONE * 9.0

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
	_body.scale = Vector3.ONE * 1.5  # bigger gunship
	add_child(_body)
	var col := Color(0.2, 0.28, 0.22)
	var dark := Color(0.12, 0.13, 0.14)
	_box(_body, Vector3(1.8, 1.4, 3.0), Vector3(0, 0.3, -0.2), col)         # cabin
	_box(_body, Vector3(1.6, 1.0, 1.2), Vector3(0, 0.5, 1.3), Color(0.3, 0.45, 0.6))  # nose/glass
	_box(_body, Vector3(0.4, 0.4, 2.6), Vector3(0, 0.6, -2.6), col)         # tail boom
	_box(_body, Vector3(0.1, 1.0, 0.6), Vector3(0, 0.9, -3.6), col)         # tail fin
	_box(_body, Vector3(2.0, 0.12, 0.25), Vector3(-1.0, -0.4, 0.2), dark)   # left skid bar
	_box(_body, Vector3(2.0, 0.12, 0.25), Vector3(1.0, -0.4, 0.2), dark)
	_box(_body, Vector3(0.12, 0.5, 2.0), Vector3(-0.7, -0.15, 0.2), dark)   # skid legs
	_box(_body, Vector3(0.12, 0.5, 2.0), Vector3(0.7, -0.15, 0.2), dark)
	# Main rotor
	_rotor = Node3D.new()
	_rotor.position = Vector3(0, 1.15, -0.2)
	_body.add_child(_rotor)
	_box(_rotor, Vector3(0.25, 0.06, 7.0), Vector3.ZERO, dark)
	_box(_rotor, Vector3(7.0, 0.06, 0.25), Vector3.ZERO, dark)
	_box(_body, Vector3(0.15, 0.4, 0.15), Vector3(0, 0.95, -0.2), dark)     # rotor mast
	# Tail rotor
	_tail_rotor = Node3D.new()
	_tail_rotor.position = Vector3(0.15, 0.7, -3.7)
	_body.add_child(_tail_rotor)
	_box(_tail_rotor, Vector3(0.05, 1.6, 0.12), Vector3.ZERO, dark)
