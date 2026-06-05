extends VehicleBody3D
## Arcade drivable vehicle, networked driver-authoritative. Has health, can be
## destroyed (explodes + ejects driver + respawns), shields its driver, and can be
## driven by bots (host-authoritative). Visual model is chosen per spawn.

const STEER_SPEED := 2.6
const MAX_HEALTH := 350.0
const RESPAWN_TIME := 14.0
const BLAST_RADIUS := 6.0
const BLAST_DAMAGE := 80.0
const FLIP_TIME := 0.7

# Per-model handling. Lower com_y + stiffer suspension = less body roll.
# All com_y are above the roll-centre (~0) so the lean is outward (correct).
const PROFILES := [
	{"name": "SUV",       "model": "res://assets/models/vehicles/suv.glb",
		"engine": 1300.0, "reverse": 600.0, "steer": 0.5,  "mass": 1200.0, "com_y": 0.2,  "stiff": 38.0, "travel": 0.45},
	{"name": "Sedan",     "model": "res://assets/models/vehicles/sedan.glb",
		"engine": 1550.0, "reverse": 650.0, "steer": 0.5,  "mass": 1000.0, "com_y": 0.15, "stiff": 42.0, "travel": 0.4},
	{"name": "Hatchback", "model": "res://assets/models/vehicles/hatchback-sports.glb",
		"engine": 1750.0, "reverse": 700.0, "steer": 0.55, "mass": 850.0,  "com_y": 0.12, "stiff": 46.0, "travel": 0.35},
	{"name": "Race",      "model": "res://assets/models/vehicles/race-future.glb",
		"engine": 2300.0, "reverse": 800.0, "steer": 0.6,  "mass": 800.0,  "com_y": 0.1,  "stiff": 55.0, "travel": 0.28},
]

@export var model_index: int = 0

var max_engine := 1400.0
var max_reverse := 650.0
var max_steer := 0.5

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
var _flip_t := 0.0
var _flip_target := Quaternion.IDENTITY
var _empty_over_t := 0.0

func _ready() -> void:
	add_to_group("vehicle")
	_spawn_pos = global_position
	_spawn_quat = global_transform.basis.get_rotation_quaternion()
	sync_pos = global_position
	sync_quat = _spawn_quat
	_apply_model()
	_update_authority()

func _apply_model() -> void:
	var p: Dictionary = PROFILES[clampi(model_index, 0, PROFILES.size() - 1)]
	# Handling
	mass = p["mass"]
	center_of_mass = Vector3(0, p["com_y"], 0)
	max_engine = p["engine"]
	max_reverse = p["reverse"]
	max_steer = p["steer"]
	for w in get_children():
		if w is VehicleWheel3D:
			w.suspension_stiffness = p["stiff"]
			w.suspension_travel = p["travel"]
	# Visual model
	for c in get_children():
		if c.name == "Model":
			c.free()
	if ResourceLoader.exists(p["model"]):
		var m: Node3D = load(p["model"]).instantiate()
		m.name = "Model"
		m.transform = Transform3D(Basis.from_scale(Vector3(1.9, 1.9, 1.9)), Vector3(0, -0.57, 0))
		add_child(m)

func type_name() -> String:
	return PROFILES[clampi(model_index, 0, PROFILES.size() - 1)]["name"]

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
		if _flip_t > 0.0:
			_animate_flip(delta)
			return
		_auto_flip(delta)
		engine_force = _throttle * (max_engine if _throttle >= 0.0 else max_reverse)
		steering = move_toward(steering, _steer * max_steer, STEER_SPEED * delta)
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

# ---------------------------------------------------------------- flipping

func is_overturned() -> bool:
	return global_transform.basis.y.dot(Vector3.UP) < 0.5

## Driver-requested flip (R). Empty cars auto-flip via _auto_flip().
func request_flip() -> void:
	flip.rpc()

@rpc("any_peer", "call_local", "reliable")
func flip() -> void:
	if _flip_t > 0.0 or not is_overturned():
		return
	if not is_multiplayer_authority():
		return
	_flip_t = FLIP_TIME
	# Upright basis preserving the car's heading.
	var fwd := global_transform.basis.z
	var flat := Vector3(fwd.x, 0, fwd.z)
	if flat.length() < 0.1:
		flat = Vector3(0, 0, 1)
	flat = flat.normalized()
	var x := Vector3.UP.cross(flat).normalized()
	_flip_target = Basis(x, Vector3.UP, flat).get_rotation_quaternion()

func _animate_flip(delta: float) -> void:
	_flip_t -= delta
	freeze = true
	var k := clampf(8.0 * delta, 0.0, 1.0)
	var cur := global_transform.basis.get_rotation_quaternion()
	global_transform.basis = Basis(cur.slerp(_flip_target, k))
	global_position += Vector3.UP * (2.5 * delta)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sync_pos = global_position
	sync_quat = global_transform.basis.get_rotation_quaternion()
	if _flip_t <= 0.0:
		freeze = false

func _auto_flip(delta: float) -> void:
	# Empty cars that end up on their roof right themselves after a few seconds.
	if driver_id == 0 and is_overturned():
		_empty_over_t += delta
		if _empty_over_t > 3.0:
			_empty_over_t = 0.0
			flip()
	else:
		_empty_over_t = 0.0

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
