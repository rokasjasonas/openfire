extends VehicleBody3D
## Arcade drivable vehicle, networked driver-authoritative. Has health, can be
## destroyed (explodes + ejects driver + respawns), shields its driver, and can be
## driven by bots (host-authoritative). Visual model is chosen per spawn.

const MAX_ENGINE := 1400.0
const MAX_REVERSE := 650.0
const MAX_STEER := 0.45
const STEER_SPEED := 2.6
const MAX_HEALTH := 350.0
const RESPAWN_TIME := 14.0
const BLAST_RADIUS := 6.0
const BLAST_DAMAGE := 80.0

const MODELS := [
	"res://assets/models/vehicles/suv.glb",
	"res://assets/models/vehicles/sedan.glb",
	"res://assets/models/vehicles/hatchback-sports.glb",
	"res://assets/models/vehicles/race-future.glb",
]

@export var model_index: int = 0

var driver_id: int = 0           # 0 = empty, >0 player peer, <0 bot combatant id
var driver_team: int = -999
var seat_offset := Vector3(0, 1.5, 0)
var health: float = MAX_HEALTH
var destroyed: bool = false

var sync_pos: Vector3
var sync_quat: Quaternion = Quaternion.IDENTITY

var _throttle := 0.0
var _steer := 0.0
var _brake := 0.0
var _roadkill_cd := 0.0
var _respawn_timer := 0.0
var _spawn_pos: Vector3
var _spawn_quat: Quaternion = Quaternion.IDENTITY

func _ready() -> void:
	add_to_group("vehicle")
	_spawn_pos = global_position
	_spawn_quat = global_transform.basis.get_rotation_quaternion()
	sync_pos = global_position
	sync_quat = _spawn_quat
	_apply_model()
	_update_authority()

func _apply_model() -> void:
	for c in get_children():
		if c.name == "Model":
			c.free()
	var path: String = MODELS[clampi(model_index, 0, MODELS.size() - 1)]
	if ResourceLoader.exists(path):
		var m: Node3D = load(path).instantiate()
		m.name = "Model"
		m.transform = Transform3D(Basis.from_scale(Vector3(1.9, 1.9, 1.9)), Vector3(0, -0.57, 0))
		add_child(m)

func _update_authority() -> void:
	# Players drive on their own peer; empty or bot-driven cars stay with the host.
	var auth := driver_id if driver_id > 0 else 1
	set_multiplayer_authority(auth)
	freeze = destroyed or not is_multiplayer_authority()

func _physics_process(delta: float) -> void:
	if destroyed:
		if is_multiplayer_authority():
			_respawn_timer -= delta
			if _respawn_timer <= 0.0:
				_do_respawn()
		return
	if is_multiplayer_authority():
		engine_force = _throttle * (MAX_ENGINE if _throttle >= 0.0 else MAX_REVERSE)
		steering = move_toward(steering, _steer * MAX_STEER, STEER_SPEED * delta)
		brake = _brake
		sync_pos = global_position
		sync_quat = global_transform.basis.get_rotation_quaternion()
		if driver_id != 0:
			_roadkill(delta)
	else:
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

func forward() -> Vector3:
	return global_transform.basis.z.normalized()

func speed() -> float:
	return linear_velocity.length()

func is_occupied() -> bool:
	return driver_id != 0 or destroyed

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
	_brake = 3.0 if peer_id == 0 else 0.0
	_update_authority()

# ---------------------------------------------------------------- damage

func hit(amount: float, attacker_id: int) -> void:
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
	# Blast damage to nearby combatants (authority computes it).
	if is_multiplayer_authority():
		for c in get_tree().get_nodes_in_group("combatant"):
			if not is_instance_valid(c) or c.get("dead"):
				continue
			var d := global_position.distance_to(c.global_position)
			if d < BLAST_RADIUS and c.has_method("hit"):
				c.hit(BLAST_DAMAGE * (1.0 - d / BLAST_RADIUS), attacker_id)
		_respawn_timer = RESPAWN_TIME
	driver_id = 0
	driver_team = -999
	_set_destroyed.rpc(true)
	_update_authority()

@rpc("authority", "call_local", "reliable")
func _set_destroyed(v: bool) -> void:
	destroyed = v
	if v:
		_explosion_fx()
		visible = false
		freeze = true
		$CollisionShape3D.disabled = true
	else:
		health = MAX_HEALTH
		visible = true
		$CollisionShape3D.disabled = false
		global_position = _spawn_pos
		global_transform.basis = Basis(_spawn_quat)
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		_update_authority()

func _do_respawn() -> void:
	_set_destroyed.rpc(false)

func _explosion_fx() -> void:
	Audio.play_3d("res://assets/audio/death.ogg", global_position, 6.0, 0.05)
	var scene := get_tree().current_scene
	if scene == null:
		return
	var fx: Node3D = load("res://scenes/fx/impact.tscn").instantiate()
	scene.add_child(fx)
	fx.global_position = global_position + Vector3.UP
	fx.scale = Vector3.ONE * 8.0
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 12.0
	light.omni_range = BLAST_RADIUS * 2.0
	scene.add_child(light)
	light.global_position = global_position + Vector3.UP
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.5)
	tw.tween_callback(light.queue_free)

# ---------------------------------------------------------------- roadkill

func _roadkill(delta: float) -> void:
	_roadkill_cd -= delta
	if _roadkill_cd > 0.0 or speed() < 7.0:
		return
	for c in get_tree().get_nodes_in_group("combatant"):
		if not is_instance_valid(c) or c.get("dead") or c.get("team") == driver_team:
			continue
		if global_position.distance_to(c.global_position) < 2.6:
			if c.has_method("hit"):
				c.hit(50.0, driver_id)
			_roadkill_cd = 0.6
			return
