extends CharacterBody3D
## Navmesh-driven AI combatant. All decision-making runs on the server (authority
## == peer 1); clients only receive replicated transform/health/dead state.
## Targets any combatant whose team differs from its own (works for both co-op
## team play and free-for-all deathmatch).

enum State { PATROL, CHASE, ATTACK, DEAD }

const MAX_HEALTH := 100.0
const HIT_MASK := 1 | 2 | 4
const LOS_MASK := 1   # only world geometry blocks line of sight

@export var skill: float = 1.0          # set by world; scales accuracy/cadence/damage
@export var respawns: bool = false      # deathmatch bots respawn; coop enemies don't

var combatant_id: int = -1
var team: int = 1
var display_name: String = "Bot"

var sync_health: float = MAX_HEALTH
var dead: bool = false

var _state: int = State.PATROL
var _target: Node3D = null
var _shoot_cd: float = 0.0
var _think_cd: float = 0.0
var _patrol_target: Vector3
var _has_patrol: bool = false
var _spawn_pos: Vector3
var _respawn_timer: float = 0.0

@onready var nav: NavigationAgent3D = $NavigationAgent3D
@onready var body_model: Node3D = $BodyModel
@onready var muzzle: Marker3D = $Muzzle
@onready var name_label: Label3D = $NameLabel

signal died(attacker_id: int, victim_id: int)

func _ready() -> void:
	add_to_group("combatant")
	add_to_group("bot")
	_spawn_pos = global_position
	name_label.text = display_name
	nav.path_desired_distance = 1.0
	nav.target_desired_distance = 1.5
	nav.avoidance_enabled = false
	# Only the server thinks. Clients just display synced state.
	set_physics_process(is_multiplayer_authority())

func configure(id: int, t: int, sk: float, respawn_on_death: bool, label: String) -> void:
	combatant_id = id
	team = t
	skill = sk
	respawns = respawn_on_death
	display_name = label
	if is_node_ready():
		name_label.text = label

func _physics_process(delta: float) -> void:
	if dead:
		if respawns:
			_respawn_timer -= delta
			if _respawn_timer <= 0.0:
				_do_respawn()
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 24.0) * delta

	_think_cd -= delta
	if _think_cd <= 0.0:
		_think_cd = 0.25
		_acquire_target()

	if _shoot_cd > 0.0:
		_shoot_cd -= delta

	match _state:
		State.PATROL:
			_do_patrol()
		State.CHASE:
			_do_chase()
		State.ATTACK:
			_do_attack(delta)

	move_and_slide()

# ---------------------------------------------------------------- perception

func _acquire_target() -> void:
	var best: Node3D = null
	var best_d := INF
	for c in get_tree().get_nodes_in_group("combatant"):
		if c == self or not is_instance_valid(c):
			continue
		if c.get("dead"):
			continue
		if c.get("team") == team:
			continue
		var d := global_position.distance_to(c.global_position)
		if d < best_d and d < 60.0 and _can_see(c):
			best_d = d
			best = c
	_target = best
	if _target == null:
		_state = State.PATROL
	elif best_d <= 28.0:
		_state = State.ATTACK
	else:
		_state = State.CHASE

func _can_see(c: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var from := muzzle.global_position
	var to := c.global_position + Vector3.UP * 1.2
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = LOS_MASK
	q.exclude = [get_rid()]
	var res := space.intersect_ray(q)
	return res.is_empty()  # nothing solid in the way

# ---------------------------------------------------------------- behaviours

func _do_patrol() -> void:
	if not _has_patrol or global_position.distance_to(_patrol_target) < 2.0:
		_pick_patrol_point()
	_move_toward(_patrol_target, 3.0)

func _pick_patrol_point() -> void:
	var map := get_tree().get_first_node_in_group("nav_region")
	var offset := Vector3(randf_range(-12, 12), 0, randf_range(-12, 12))
	_patrol_target = _spawn_pos + offset
	if map and map is NavigationRegion3D:
		var closest := NavigationServer3D.map_get_closest_point(map.get_navigation_map(), _patrol_target)
		_patrol_target = closest
	_has_patrol = true

func _do_chase() -> void:
	if _target == null:
		_state = State.PATROL
		return
	_move_toward(_target.global_position, 5.5 * clampf(skill, 0.7, 1.4))

func _do_attack(delta: float) -> void:
	if _target == null:
		_state = State.PATROL
		return
	# Strafe slowly toward / hold; face the target and shoot.
	var to_target := _target.global_position - global_position
	to_target.y = 0
	if to_target.length() > 18.0:
		_move_toward(_target.global_position, 4.0)
	else:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
	_face(_target.global_position)
	if _shoot_cd <= 0.0 and _can_see(_target):
		_shoot_at(_target)

func _move_toward(world_pos: Vector3, speed: float) -> void:
	nav.target_position = world_pos
	if nav.is_navigation_finished():
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * 0.016)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * 0.016)
		return
	var next := nav.get_next_path_position()
	var dir := (next - global_position)
	dir.y = 0
	dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face(global_position + dir)

func _face(world_pos: Vector3) -> void:
	var flat := Vector3(world_pos.x, global_position.y, world_pos.z)
	if flat.distance_to(global_position) > 0.05:
		look_at(flat, Vector3.UP)
		rotation.x = 0
		rotation.z = 0

func _shoot_at(target: Node3D) -> void:
	# Cadence and accuracy scale with skill.
	_shoot_cd = clampf(0.9 / skill, 0.35, 1.4)
	var origin := muzzle.global_position
	var aim := (target.global_position + Vector3.UP * 1.1) - origin
	var spread := deg_to_rad(lerpf(7.0, 1.5, clampf(skill - 0.5, 0.0, 1.0)))
	var dir := aim.normalized()
	# random cone
	var n := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	dir = dir.rotated(n, randf() * spread).normalized()
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 80.0)
	q.collision_mask = HIT_MASK
	q.exclude = [get_rid()]
	var res := space.intersect_ray(q)
	var endpoint := origin + dir * 80.0
	if res:
		endpoint = res.position
		var col = res.collider
		if col and col.is_in_group("combatant") and col.has_method("hit") and col.get("team") != team:
			col.hit(11.0 * clampf(skill, 0.6, 1.6), combatant_id)
	_fire_fx.rpc(endpoint)

@rpc("any_peer", "call_local", "unreliable")
func _fire_fx(hit_point: Vector3) -> void:
	var from := muzzle.global_position
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	var dist := from.distance_to(hit_point)
	box.size = Vector3(0.03, 0.03, dist)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.4, 0.3)
	mesh.material_override = mat
	get_tree().current_scene.add_child(mesh)
	mesh.global_position = (from + hit_point) * 0.5
	if dist > 0.05:
		mesh.look_at(hit_point, Vector3.UP)
	var tw := mesh.create_tween()
	tw.tween_property(mesh, "transparency", 1.0, 0.07)
	tw.tween_callback(mesh.queue_free)

# ---------------------------------------------------------------- damage / death

func hit(amount: float, attacker_id: int) -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, attacker_id: int) -> void:
	if dead:
		return
	sync_health = max(0.0, sync_health - amount)
	if sync_health <= 0.0:
		_die(attacker_id)

func _die(attacker_id: int) -> void:
	if dead:
		return
	dead = true
	body_model.visible = false
	name_label.visible = false
	$CollisionShape3D.disabled = true
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		Game.add_kill(attacker_id, combatant_id)
		died.emit(attacker_id, combatant_id)
		_set_dead_visual.rpc(true)
		if respawns:
			_respawn_timer = 4.0

@rpc("authority", "call_local", "reliable")
func _set_dead_visual(is_dead: bool) -> void:
	dead = is_dead
	body_model.visible = not is_dead
	name_label.visible = not is_dead
	$CollisionShape3D.disabled = is_dead

func _do_respawn() -> void:
	sync_health = MAX_HEALTH
	global_position = _spawn_pos
	_set_dead_visual.rpc(false)

func get_team() -> int:
	return team
