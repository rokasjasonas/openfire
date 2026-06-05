extends VehicleBody3D
## Arcade drivable vehicle. The driver's peer is authoritative — it simulates the
## physics and replicates the transform; other peers freeze the body and lerp
## toward the synced pose. Placed by maps; bots don't drive.

const MAX_ENGINE := 1800.0
const MAX_REVERSE := 800.0
const MAX_STEER := 0.5
const STEER_SPEED := 3.0

var driver_id: int = 0           # 0 = empty
var driver_team: int = -999
var seat_offset := Vector3(0, 2.4, 0)

var sync_pos: Vector3
var sync_quat: Quaternion = Quaternion.IDENTITY

var _throttle := 0.0
var _steer := 0.0
var _brake := 0.0
var _roadkill_cd := 0.0

func _ready() -> void:
	add_to_group("vehicle")
	sync_pos = global_position
	sync_quat = global_transform.basis.get_rotation_quaternion()
	_update_authority()

func _update_authority() -> void:
	var auth := driver_id if driver_id != 0 else 1
	set_multiplayer_authority(auth)
	freeze = not is_multiplayer_authority()

func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		if _throttle >= 0.0:
			engine_force = _throttle * MAX_ENGINE
		else:
			engine_force = _throttle * MAX_REVERSE
		steering = move_toward(steering, _steer * MAX_STEER, STEER_SPEED * delta)
		brake = _brake
		sync_pos = global_position
		sync_quat = global_transform.basis.get_rotation_quaternion()
		if driver_id != 0:
			_roadkill(delta)
	else:
		# Remote: interpolate toward the replicated pose (body is frozen).
		var t := clampf(15.0 * delta, 0.0, 1.0)
		global_position = global_position.lerp(sync_pos, t)
		var cur := global_transform.basis.get_rotation_quaternion()
		global_transform.basis = Basis(cur.slerp(sync_quat, t))

func set_drive(throttle: float, steer: float, brake_force: float) -> void:
	_throttle = throttle
	_steer = steer
	_brake = brake_force

func seat_position() -> Vector3:
	return global_transform * seat_offset

## World-space drive-forward direction (engine_force > 0 drives along local +Z).
func forward() -> Vector3:
	return global_transform.basis.z.normalized()

func speed() -> float:
	return linear_velocity.length()

func is_occupied() -> bool:
	return driver_id != 0

# ---------------------------------------------------------------- enter / exit

func enter(peer_id: int, team: int) -> void:
	_set_occupant.rpc(peer_id, team)

func exit() -> void:
	_set_occupant.rpc(0, -999)

@rpc("any_peer", "call_local", "reliable")
func _set_occupant(peer_id: int, team: int) -> void:
	driver_id = peer_id
	driver_team = team
	_throttle = 0.0
	_steer = 0.0
	_brake = 3.0 if peer_id == 0 else 0.0  # park when empty
	_update_authority()

# ---------------------------------------------------------------- roadkill

func _roadkill(delta: float) -> void:
	_roadkill_cd -= delta
	if _roadkill_cd > 0.0:
		return
	var speed := linear_velocity.length()
	if speed < 7.0:
		return
	for c in get_tree().get_nodes_in_group("combatant"):
		if not is_instance_valid(c) or c.get("dead") or c.get("team") == driver_team:
			continue
		if global_position.distance_to(c.global_position) < 2.3:
			if c.has_method("hit"):
				c.hit(45.0, driver_id)
			_roadkill_cd = 0.6
			return
