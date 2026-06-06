extends CharacterBody3D
## Navmesh-driven AI combatant. All decision-making runs on the server (authority
## == peer 1); clients only receive replicated transform/health/dead state.
## Targets any combatant whose team differs from its own (works for both co-op
## team play and free-for-all deathmatch).

enum State { PATROL, CHASE, ATTACK, SEARCH, DEAD }

const HIT_MASK := 1 | 16  # world | hitbox
const LOS_MASK := 1   # only world geometry blocks line of sight

## Enemy archetypes. Add a type by appending an entry here, then reference its key
## when spawning (world.spawn_enemy) or in a mission's enemy_types list.
const PROFILES := {
	"soldier": {"name": "Soldier", "health": 100.0, "speed": 5.5, "cooldown": 0.9, "damage": 11.0,
		"sight": 60.0, "attack": 26.0, "spread_far": 7.0, "spread_near": 1.5,
		"model": "res://assets/models/characters/character-m.glb", "color": Color(1, 0.5, 0.45), "scale": 1.0},
	"rusher": {"name": "Rusher", "health": 55.0, "speed": 8.5, "cooldown": 0.5, "damage": 7.0,
		"sight": 55.0, "attack": 16.0, "spread_far": 9.0, "spread_near": 3.0,
		"model": "res://assets/models/characters/character-c.glb", "color": Color(1, 0.8, 0.3), "scale": 0.9},
	"sniper": {"name": "Sniper", "health": 70.0, "speed": 4.0, "cooldown": 2.1, "damage": 55.0,
		"sight": 130.0, "attack": 85.0, "spread_far": 1.4, "spread_near": 0.3,
		"model": "res://assets/models/characters/character-h.glb", "color": Color(0.5, 0.8, 1.0), "scale": 1.0},
	"heavy": {"name": "Heavy", "health": 210.0, "speed": 3.6, "cooldown": 0.7, "damage": 14.0,
		"sight": 55.0, "attack": 22.0, "spread_far": 6.0, "spread_near": 2.0,
		"model": "res://assets/models/characters/character-p.glb", "color": Color(1, 0.3, 0.3), "scale": 1.18},
	"boss": {"name": "WARLORD", "health": 1500.0, "speed": 4.2, "cooldown": 0.5, "damage": 22.0,
		"sight": 95.0, "attack": 45.0, "spread_far": 4.0, "spread_near": 1.0,
		"model": "res://assets/models/characters/character-p.glb", "color": Color(1, 0.15, 0.55), "scale": 1.9},
}
# Spawn weighting (soldiers common, others rarer).
const SPAWN_WEIGHTS := {"soldier": 5, "rusher": 3, "sniper": 2, "heavy": 1}

@export var skill: float = 1.0          # set by world; scales accuracy/cadence/damage
@export var respawns: bool = false      # deathmatch bots respawn; coop enemies don't

var etype: String = "soldier"
var combatant_id: int = -1
var team: int = 1
var display_name: String = "Bot"

# Stats resolved from the profile.
var max_health: float = 100.0
var move_speed: float = 5.5
var fire_cooldown: float = 0.9
var shoot_damage: float = 11.0
var sight_range: float = 60.0
var attack_range: float = 26.0
var spread_far: float = 7.0
var spread_near: float = 1.5

var sync_health: float = 100.0
var sync_pos: Vector3 = Vector3.ZERO
var sync_yaw: float = 0.0
var dead: bool = false

var _state: int = State.PATROL
var _target: Node3D = null
var _shoot_cd: float = 0.0
var _think_cd: float = 0.0
var _patrol_target: Vector3
var _has_patrol: bool = false
var _spawn_pos: Vector3
var _respawn_timer: float = 0.0

# Smarter-AI memory/behaviour
var _last_seen: Vector3
var _has_last_seen: bool = false
var _search_time: float = 0.0
var _reaction: float = 0.0       # delay before firing after acquiring a target
var _strafe_sign: float = 1.0
var _strafe_timer: float = 0.0

# Vehicle AI
const VEH_ENTER_DIST := 35.0
const VEH_EXIT_DIST := 18.0
const VEH_RANGE := 9.0
var _vehicle: Node = null

@onready var nav: NavigationAgent3D = $NavigationAgent3D
@onready var body_model: Node3D = $BodyModel
@onready var muzzle: Marker3D = $Muzzle
@onready var name_label: Label3D = $NameLabel

signal died(attacker_id: int, victim_id: int)

func _ready() -> void:
	add_to_group("combatant")
	add_to_group("bot")
	_spawn_pos = global_position
	sync_pos = global_position
	sync_yaw = rotation.y
	_apply_profile()
	nav.path_desired_distance = 1.0
	nav.target_desired_distance = 1.5
	nav.avoidance_enabled = false
	# Only the server thinks. Clients just display + interpolate synced state.
	set_physics_process(is_multiplayer_authority())
	set_process(not is_multiplayer_authority())

func _apply_profile() -> void:
	var p: Dictionary = PROFILES.get(etype, PROFILES["soldier"])
	max_health = p["health"]
	move_speed = p["speed"]
	fire_cooldown = p["cooldown"]
	shoot_damage = p["damage"]
	sight_range = p["sight"]
	attack_range = p["attack"]
	spread_far = p["spread_far"]
	spread_near = p["spread_near"]
	if is_multiplayer_authority():
		sync_health = max_health
	name_label.text = "%s %d" % [p["name"], absi(combatant_id) % 1000]
	name_label.modulate = Game.team_color(team) if Game.is_team_mode() else p["color"]
	# Hide bot/NPC name tags in Battle Royale (stealthy FFA) and in Survival.
	name_label.visible = not Game.is_battle_royale() and not Game.is_survival()
	body_model.scale = Vector3.ONE * float(p["scale"])
	# Swap the body model to the archetype's character.
	for c in body_model.get_children():
		c.queue_free()
	if ResourceLoader.exists(p["model"]):
		var packed: PackedScene = load(p["model"])
		body_model.add_child(packed.instantiate())

func _process(delta: float) -> void:
	# Remote copy: smoothly interpolate toward the replicated transform.
	var t := clampf(15.0 * delta, 0.0, 1.0)
	if global_position.distance_to(sync_pos) > 5.0:
		global_position = sync_pos
	else:
		global_position = global_position.lerp(sync_pos, t)
	rotation.y = lerp_angle(rotation.y, sync_yaw, t)

func configure(id: int, t: int, sk: float, respawn_on_death: bool, label: String, type_id: String = "soldier") -> void:
	combatant_id = id
	team = t
	skill = sk
	respawns = respawn_on_death
	display_name = label
	etype = type_id if PROFILES.has(type_id) else "soldier"
	if is_node_ready():
		_apply_profile()

func _physics_process(delta: float) -> void:
	if dead:
		if _vehicle:
			_exit_bot_vehicle()
		if respawns:
			_respawn_timer -= delta
			if _respawn_timer <= 0.0:
				_do_respawn()
		return

	# Driving a vehicle overrides on-foot behaviour.
	if _vehicle != null and is_instance_valid(_vehicle):
		_drive_bot_vehicle(delta)
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 24.0) * delta

	_think_cd -= delta
	if _think_cd <= 0.0:
		_think_cd = 0.25
		_acquire_target()
		_maybe_enter_vehicle()

	if _shoot_cd > 0.0:
		_shoot_cd -= delta
	if _reaction > 0.0:
		_reaction -= delta

	match _state:
		State.PATROL:
			_do_patrol()
		State.CHASE:
			_do_chase()
		State.ATTACK:
			_do_attack(delta)
		State.SEARCH:
			_do_search(delta)

	move_and_slide()
	_update_footsteps(delta)
	sync_pos = global_position
	sync_yaw = rotation.y

var _step_timer: float = 0.0

func _update_footsteps(delta: float) -> void:
	var hspeed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and hspeed > 1.5:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer = clampf(0.5 * (5.0 / maxf(hspeed, 0.1)), 0.3, 0.6)
			_step_fx.rpc()
	else:
		_step_timer = 0.0

@rpc("any_peer", "call_local", "unreliable")
func _step_fx() -> void:
	Audio.play_3d("res://assets/audio/footstep_%d.ogg" % (randi() % 4 + 1), global_position, -9.0, 0.12)

# ---------------------------------------------------------------- perception

func _acquire_target() -> void:
	var best: Node3D = null
	var best_d := INF
	for c in get_tree().get_nodes_in_group("combatant"):
		if c == self or not is_instance_valid(c):
			continue
		if c.get("dead") or c.get("downed") or c.get("fully_dead"):
			continue
		if c.get("team") == team:
			continue
		var d := global_position.distance_to(c.global_position)
		if d < best_d and d < sight_range and _can_see(c):
			best_d = d
			best = c
	# Also consider enemy-occupied vehicles (cars / helicopters).
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v.get("destroyed") or v.get("driver_id") == 0 or v.get("driver_team") == team:
			continue
		var d: float = global_position.distance_to(v.global_position)
		if d < best_d and d < sight_range and _can_see(v):
			best_d = d
			best = v
	if best != null:
		if _target == null:
			_reaction = _reaction_time()  # we just spotted someone
		_target = best
		_last_seen = best.global_position
		_has_last_seen = true
		if best.is_in_group("vehicle"):
			_state = State.ATTACK  # shoot vehicles from wherever we can see them
		else:
			_state = State.ATTACK if best_d <= attack_range else State.CHASE
	else:
		# Lost sight: investigate the last known position before giving up.
		_target = null
		if _has_last_seen and _state != State.SEARCH:
			_state = State.SEARCH
			_search_time = 4.0
		elif not _has_last_seen:
			_state = State.PATROL

func _reaction_time() -> float:
	return clampf(0.45 / skill, 0.08, 0.6)

# ---------------------------------------------------------------- vehicle AI

func _maybe_enter_vehicle() -> void:
	if _vehicle != null or _target == null:
		return
	if global_position.distance_to(_target.global_position) < VEH_ENTER_DIST:
		return
	var best: Node = null
	var bd := VEH_RANGE
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v.is_occupied() or v.is_in_group("aircraft"):
			continue  # bots drive cars, not helicopters
		var d: float = global_position.distance_to(v.global_position)
		if d < bd:
			bd = d
			best = v
	if best:
		_vehicle = best
		best.enter(combatant_id, team)
		$CollisionShape3D.disabled = true
		_set_hitboxes(false)

func _drive_bot_vehicle(delta: float) -> void:
	var v := _vehicle
	if v.get("destroyed") or _target == null \
			or global_position.distance_to(_target.global_position) < VEH_EXIT_DIST:
		_exit_bot_vehicle()
		return
	# Steer toward the target.
	var to: Vector3 = _target.global_position - v.global_position
	to.y = 0.0
	var fwd: Vector3 = v.forward()
	fwd.y = 0.0
	var angle := fwd.signed_angle_to(to.normalized(), Vector3.UP)
	var steer := clampf(angle * 2.0, -1.0, 1.0)
	v.set_drive(1.0, steer, 0.0)
	# Ride the seat so clients see the bot in the car.
	global_position = v.seat_position()
	rotation.y = atan2(fwd.x, fwd.z)
	sync_pos = global_position
	sync_yaw = rotation.y

func _exit_bot_vehicle() -> void:
	if _vehicle and is_instance_valid(_vehicle):
		var side: Vector3 = _vehicle.global_transform.basis.x * 3.0 + Vector3.UP * 0.8
		global_position = _vehicle.global_position + side
		_vehicle.exit()
	$CollisionShape3D.disabled = false
	_set_hitboxes(true)
	_vehicle = null

func _set_hitboxes(on: bool) -> void:
	if has_node("Hitboxes"):
		for a in $Hitboxes.get_children():
			if a is Area3D:
				a.collision_layer = 16 if on else 0

func _can_see(c: Node) -> bool:
	var space := get_world_3d().direct_space_state
	var from := muzzle.global_position
	var to: Vector3 = c.global_position + Vector3.UP * 1.2
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = LOS_MASK
	q.exclude = [get_rid()]
	var res := space.intersect_ray(q)
	if res.is_empty():
		return true
	return res.collider == c  # only the target itself (a vehicle) blocks -> visible

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
	_move_toward(_target.global_position, move_speed)

func _do_attack(delta: float) -> void:
	if _target == null:
		_state = State.PATROL
		return
	_last_seen = _target.global_position
	_has_last_seen = true
	# Vehicles (incl. flying helicopters): stand ground and shoot, don't chase.
	if _target.is_in_group("vehicle"):
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		_face(_target.global_position)
		if _shoot_cd <= 0.0 and _reaction <= 0.0 and _can_see(_target):
			_shoot_at(_target)
		return
	# Close to preferred range, otherwise strafe sideways to be harder to hit.
	var to_target := _target.global_position - global_position
	to_target.y = 0
	if to_target.length() > attack_range * 0.7:
		_move_toward(_target.global_position, move_speed * 0.85)
	else:
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_strafe_timer = randf_range(0.7, 1.6)
			_strafe_sign = -_strafe_sign
		var sv := global_transform.basis.x * _strafe_sign * move_speed * 0.55
		velocity.x = sv.x
		velocity.z = sv.z
	_face(_target.global_position)
	# Reaction delay before the first shot makes them feel human, not instant.
	if _shoot_cd <= 0.0 and _reaction <= 0.0 and _can_see(_target):
		_shoot_at(_target)

func _do_search(delta: float) -> void:
	_search_time -= delta
	if not _has_last_seen or _search_time <= 0.0:
		_has_last_seen = false
		_state = State.PATROL
		return
	_move_toward(_last_seen, move_speed * 0.85)
	if global_position.distance_to(_last_seen) < 2.5:
		_has_last_seen = false  # reached it, nobody here — resume patrol
		_state = State.PATROL

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
	# Cadence and accuracy come from the archetype, scaled by skill.
	_shoot_cd = clampf(fire_cooldown / skill, 0.3, 3.0)
	var origin := muzzle.global_position
	var reach := maxf(origin.distance_to(target.global_position) + 12.0, 90.0)
	var aim := (target.global_position + Vector3.UP * 1.1) - origin
	var spread := deg_to_rad(lerpf(spread_far, spread_near, clampf(skill - 0.5, 0.0, 1.0)))
	var dir := aim.normalized()
	# random cone
	var n := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	dir = dir.rotated(n, randf() * spread).normalized()
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * reach)
	q.collision_mask = HIT_MASK
	q.collide_with_areas = true
	var exclude: Array = [get_rid()]
	exclude.append_array(hitbox_rids())
	q.exclude = exclude
	var res := space.intersect_ray(q)
	var endpoint := origin + dir * reach
	if res:
		endpoint = res.position
		var col = res.collider
		# Resolve body-part hitbox -> combatant + damage multiplier, or a vehicle.
		var victim: Node = null
		var mult := 1.0
		if col is Hitbox:
			victim = col.combatant()
			mult = col.multiplier
		elif col and col.is_in_group("vehicle"):
			victim = col
		elif col and col.is_in_group("combatant"):
			victim = col
		if victim and victim.has_method("hit"):
			var vteam: int = victim.driver_team if victim.is_in_group("vehicle") else int(victim.get("team"))
			if vteam != team:
				victim.hit(shoot_damage * clampf(skill, 0.6, 1.6) * mult, combatant_id)
	_fire_fx.rpc(endpoint)

@rpc("any_peer", "call_local", "unreliable")
func _fire_fx(hit_point: Vector3) -> void:
	Audio.play_3d("res://assets/audio/fire_bot.ogg", muzzle.global_position, -3.0, 0.1)
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
	if is_dead:
		Audio.play_3d("res://assets/audio/death.ogg", global_position, -2.0, 0.06)

func _do_respawn() -> void:
	sync_health = max_health
	global_position = _spawn_pos
	sync_pos = _spawn_pos
	_set_dead_visual.rpc(false)

func get_team() -> int:
	return team

## RIDs of this bot's own hitbox areas, so its own shots can exclude itself.
func hitbox_rids() -> Array:
	var rids: Array = []
	if has_node("Hitboxes"):
		for a in $Hitboxes.get_children():
			if a is Area3D:
				rids.append(a.get_rid())
	return rids
