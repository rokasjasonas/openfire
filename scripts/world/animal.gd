extends CharacterBody3D
## Adventure wildlife. Passive grazers (deer/boar) wander and flee; predators (wolves)
## hunt the nearest player. Shot like any combatant; drops meat + hide on death.
## Host-authoritative (solo / host view); kept lightweight and ambient.

const PICKUP_SCENE := preload("res://scenes/pickup.tscn")

@export var species: String = "deer"

var team: int = 99          # neutral: not on anyone's side, so player shots always land
var dead: bool = false
var sync_pos: Vector3 = Vector3.ZERO   # host-driven transform, replicated to clients
var sync_yaw: float = 0.0
var health: float = 40.0
var predator: bool = false
var _speed: float = 4.0
var _tint: Color = Color(0.6, 0.45, 0.3)
var _wander: Vector3 = Vector3.ZERO
var _wander_t: float = 0.0
var _attack_cd: float = 0.0
var _anim_pos := Vector3.ZERO
var _bob: float = 0.0
var _body: Node3D = null

const SPECIES := {
	"deer": {"health": 40.0, "speed": 6.0, "tint": Color(0.62, 0.46, 0.3), "size": 1.0, "predator": false},
	"boar": {"health": 70.0, "speed": 5.0, "tint": Color(0.32, 0.28, 0.26), "size": 0.9, "predator": false},
	"wolf": {"health": 55.0, "speed": 7.0, "tint": Color(0.5, 0.5, 0.55), "size": 0.85, "predator": true},
}

func _ready() -> void:
	add_to_group("combatant")
	add_to_group("animal")
	collision_layer = 16   # ray-hittable like a hitbox; not a movement blocker
	collision_mask = 1     # collide with world only
	var s: Dictionary = SPECIES.get(species, SPECIES["deer"])
	health = float(s["health"])
	_speed = float(s["speed"])
	_tint = s["tint"]
	predator = bool(s["predator"])
	_build_body(float(s["size"]))
	_anim_pos = global_position
	sync_pos = global_position
	sync_yaw = rotation.y
	_new_wander()

func _process(delta: float) -> void:
	# Clients don't run the AI; smoothly follow the host-replicated transform.
	if is_multiplayer_authority():
		return
	var t := clampf(15.0 * delta, 0.0, 1.0)
	if global_position.distance_to(sync_pos) > 8.0:
		global_position = sync_pos
	else:
		global_position = global_position.lerp(sync_pos, t)
	rotation.y = lerp_angle(rotation.y, sync_yaw, t)

func _build_body(size: float) -> void:
	_body = Node3D.new()
	add_child(_body)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _tint
	mat.roughness = 0.95
	# Torso.
	_add_box(_body, Vector3(0.5, 0.55, 1.1) * size, Vector3(0, 0.7, 0) * size, mat)
	# Neck + head.
	_add_box(_body, Vector3(0.32, 0.32, 0.4) * size, Vector3(0, 0.95, 0.6) * size, mat)
	_add_box(_body, Vector3(0.28, 0.3, 0.34) * size, Vector3(0, 1.05, 0.85) * size, mat)
	# Four legs.
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_add_box(_body, Vector3(0.14, 0.6, 0.14) * size, Vector3(0.18 * sx, 0.3, 0.4 * sz) * size, mat)
	if species == "deer":
		# Antlers.
		var am := StandardMaterial3D.new()
		am.albedo_color = Color(0.8, 0.75, 0.6)
		_add_box(_body, Vector3(0.05, 0.3, 0.05) * size, Vector3(0.1, 1.3, 0.85) * size, am)
		_add_box(_body, Vector3(0.05, 0.3, 0.05) * size, Vector3(-0.1, 1.3, 0.85) * size, am)
	# A simple collision capsule.
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4 * size
	cap.height = 1.2 * size
	cs.shape = cap
	cs.position.y = 0.7 * size
	cs.rotation.x = PI / 2.0
	add_child(cs)

func _add_box(parent: Node3D, sz: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = sz
	mi.mesh = box
	mi.material_override = mat
	parent.add_child(mi)
	mi.position = pos

func _physics_process(delta: float) -> void:
	if dead or not is_multiplayer_authority():
		return
	if not is_on_floor():
		velocity.y -= 24.0 * delta
	var players := _nearby_players()
	var move := Vector3.ZERO
	if predator and not players.is_empty():
		# Hunt: charge the nearest player and bite only when actually within reach —
		# not through a vertical gap (a player up a ladder/ledge is unreachable).
		var p: Node = players[0]
		var to: Vector3 = p.global_position - global_position
		var vgap: float = absf(to.y)
		to.y = 0
		var reachable: bool = vgap < 1.6 and not bool(p.get("is_climbing")) and _has_line_of_sight(p)
		if to.length() < 1.8 and reachable:
			_attack_cd -= delta
			if _attack_cd <= 0.0:
				_attack_cd = 1.0
				if p.has_method("receive_damage"):
					p.receive_damage(12.0, 0)
		elif not reachable and to.length() < 2.5:
			# Right under the target but can't reach: pace at the base, don't bite.
			move = Vector3.ZERO
		else:
			move = to.normalized() * _speed
	elif not players.is_empty() and players[0].global_position.distance_to(global_position) < 14.0:
		# Flee: run directly away from the nearest player.
		var away: Vector3 = global_position - players[0].global_position
		away.y = 0
		move = away.normalized() * _speed
	else:
		# Graze: wander slowly.
		_wander_t -= delta
		if _wander_t <= 0.0:
			_new_wander()
		move = _wander * _speed * 0.4
	velocity.x = move.x
	velocity.z = move.z
	if move.length() > 0.1:
		var yaw := atan2(move.x, move.z)
		rotation.y = lerp_angle(rotation.y, yaw, 8.0 * delta)
	move_and_slide()
	sync_pos = global_position
	sync_yaw = rotation.y
	# A little gait bob.
	if _body != null and Vector2(velocity.x, velocity.z).length() > 0.5:
		_bob += delta * 12.0
		_body.position.y = absf(sin(_bob)) * 0.08

## True when nothing solid (world geometry, layer 1) sits between us and the target, so a
## predator can't bite a player through a wall it's merely pressed against. The player body
## (layer 2) and hitboxes (layer 16) aren't on the ray mask, so only walls can block it.
func _has_line_of_sight(p: Node) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var from := global_position + Vector3.UP * 0.7
	var to := (p.global_position as Vector3) + Vector3.UP * 0.8
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()

func _nearby_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead") and not p.get("fully_dead"):
			out.append(p)
	out.sort_custom(func(a, b): return a.global_position.distance_to(global_position) < b.global_position.distance_to(global_position))
	return out

func _new_wander() -> void:
	_wander_t = randf_range(2.0, 5.0)
	var ang := randf() * TAU
	_wander = Vector3(cos(ang), 0, sin(ang))

## Shot resolution routes here (animal is in group "combatant"). A client's hit is
## forwarded to the host, which owns the animal's health (like bots).
func hit(amount: float, attacker_id: int, _zone: String = "") -> void:
	if dead:
		return
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, _attacker_id: int) -> void:
	if dead or not is_multiplayer_authority():
		return
	health -= amount
	if health <= 0.0:
		_die()

func _die() -> void:
	dead = true
	# Drop via the world so the meat/hide pickups replicate to co-op clients.
	var world := get_tree().get_first_node_in_group("world")
	var here := global_position
	if world != null and world.has_method("spawn_item_pickup"):
		world.spawn_item_pickup(here + Vector3(0.3, 0.4, 0.0), "raw_meat")
		if randf() < 0.6:
			world.spawn_item_pickup(here + Vector3(-0.3, 0.4, 0.0), "hide")
	Audio.play_3d("res://assets/audio/death_body.wav", here, -3.0, 0.1)
	queue_free()
