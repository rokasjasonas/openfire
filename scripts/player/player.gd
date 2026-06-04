extends CharacterBody3D
## First-person player. Movement + look run only on the owning peer (authority);
## transform/health/weapon are replicated to everyone via MultiplayerSynchronizer.
## Damage is applied on the victim's authority and routed through hit() -> receive_damage().

const WALK_SPEED := 6.0
const SPRINT_SPEED := 9.5
const CROUCH_SPEED := 3.2
const JUMP_VELOCITY := 9.0
const ACCEL_GROUND := 12.0
const ACCEL_AIR := 3.0
const MOUSE_SENS := 0.0024
const MAX_HEALTH := 100.0

# Crouch
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.0
const STAND_HEAD := 1.6
const CROUCH_HEAD := 1.05
const CROUCH_SPEED_FACTOR := 8.0   # how fast we transition

# combatant_id == peer id for players (always positive). Used for scoring.
var combatant_id: int = 1
var team: int = -1
var display_name: String = "Player"

# Replicated state (see SceneReplicationConfig in player.tscn).
var sync_health: float = MAX_HEALTH
var sync_weapon_index: int = 0
var sync_crouch: float = 0.0   # 0 = standing, 1 = fully crouched
var sync_pos: Vector3 = Vector3.ZERO   # replicated; remotes interpolate toward it
var sync_yaw: float = 0.0
var dead: bool = false

var _yaw: float = 0.0
var _pitch: float = 0.0
var _crouch: float = 0.0
var _spawn_point: Transform3D
var _respawn_timer: float = 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var body_model: Node3D = $BodyModel
@onready var weapons: Node = $Head/Camera3D/WeaponManager
@onready var name_label: Label3D = $NameLabel
@onready var col_shape: CollisionShape3D = $CollisionShape3D
@onready var hitboxes: Node3D = $Hitboxes
@onready var hud: CanvasLayer = $HUD if has_node("HUD") else null

signal health_changed(current: float, maximum: float)
signal ammo_changed(mag: int, reserve: int)
signal weapon_changed(weapon_name: String)
signal dealt_damage(amount: float)
signal grenades_changed(count: int)
signal damaged_from(angle: float)
signal died(attacker_id: int)

const MAX_GRENADES := 2
const GRENADE_SCENE := preload("res://scenes/grenade.tscn")
var grenades: int = MAX_GRENADES

func _ready() -> void:
	_spawn_point = global_transform
	sync_pos = global_position
	sync_yaw = rotation.y
	# Own copy of the capsule so crouch resizing is per-player, not shared.
	col_shape.shape = col_shape.shape.duplicate()
	add_to_group("combatant")
	add_to_group("player")
	name_label.text = display_name
	name_label.visible = not is_multiplayer_authority()
	camera.fov = Settings.fov
	weapons.setup(self, camera)
	# Equip weapons on every peer (so remote players also show a gun and the
	# local player can actually fire). Runs before set_local/_emit_hud below.
	weapons.set_loadout(WeaponDB.default_loadout())
	# Only the owning peer drives input and owns the camera.
	if is_multiplayer_authority():
		camera.current = true
		body_model.visible = false  # hide own body in first person
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_yaw = rotation.y
		weapons.set_local(true)
		_emit_hud()
	else:
		set_physics_process(true)  # still process to apply synced transform smoothing
		weapons.set_local(false)

func _emit_hud() -> void:
	health_changed.emit(sync_health, MAX_HEALTH)
	grenades_changed.emit(grenades)
	weapons.emit_state()

## Apply a crouch factor (0..1): shrink/recenter the capsule, lower the camera,
## drop the hitboxes and squash the body model. Runs on every peer so remote
## players are hit at their crouched height.
func _apply_crouch(f: float) -> void:
	var height := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, f)
	if col_shape.shape is CapsuleShape3D:
		(col_shape.shape as CapsuleShape3D).height = height
	col_shape.position.y = height * 0.5
	head.position.y = lerpf(STAND_HEAD, CROUCH_HEAD, f)
	hitboxes.position.y = lerpf(0.0, CROUCH_HEAD - STAND_HEAD, f)
	body_model.scale.y = lerpf(1.0, 0.7, f)

var _step_timer: float = 0.0

## Emit positional footsteps (heard by everyone) while moving on the ground.
func _update_footsteps(delta: float) -> void:
	var hspeed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and hspeed > 1.5:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer = clampf(0.5 * (WALK_SPEED / maxf(hspeed, 0.1)), 0.27, 0.6)
			_footstep.rpc()
	else:
		_step_timer = 0.0

@rpc("any_peer", "call_local", "unreliable")
func _footstep() -> void:
	var vol := -13.0 if _crouch > 0.5 else -8.0
	Audio.play_3d("res://assets/audio/footstep_%d.ogg" % (randi() % 4 + 1), global_position, vol, 0.12)

## True if there is room to stand back up (nothing solid overhead).
func _has_headroom() -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * (CROUCH_HEIGHT - 0.1)
	var to := global_position + Vector3.UP * (STAND_HEIGHT + 0.1)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1  # world only
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or dead:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := MOUSE_SENS * Settings.mouse_sensitivity
		_yaw -= event.relative.x * sens
		_pitch = clamp(_pitch - event.relative.y * sens, deg_to_rad(-89), deg_to_rad(89))
		rotation.y = _yaw
		head.rotation.x = _pitch

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# Remote copy: keep weapon model + crouch pose matched, and smoothly
		# interpolate toward the replicated transform instead of snapping.
		weapons.ensure_index(sync_weapon_index)
		_apply_crouch(sync_crouch)
		var t := clampf(15.0 * delta, 0.0, 1.0)
		if global_position.distance_to(sync_pos) > 5.0:
			global_position = sync_pos  # snap on teleport / respawn
		else:
			global_position = global_position.lerp(sync_pos, t)
		rotation.y = lerp_angle(rotation.y, sync_yaw, t)
		return

	if dead:
		_respawn_timer -= delta
		return

	# Crouch (hold). Can't stand back up if something is overhead.
	var want_crouch := Input.is_action_pressed("crouch")
	if not want_crouch and _crouch > 0.05 and not _has_headroom():
		want_crouch = true
	_crouch = move_toward(_crouch, 1.0 if want_crouch else 0.0, CROUCH_SPEED_FACTOR * delta)
	sync_crouch = _crouch
	_apply_crouch(_crouch)

	# Gravity
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 24.0) * delta

	if Input.is_action_just_pressed("jump") and is_on_floor() and _crouch < 0.5:
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var speed := WALK_SPEED
	if _crouch > 0.3:
		speed = CROUCH_SPEED
	elif Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED

	var accel := ACCEL_GROUND if is_on_floor() else ACCEL_AIR
	var target := dir * speed
	velocity.x = lerp(velocity.x, target.x, accel * delta)
	velocity.z = lerp(velocity.z, target.z, accel * delta)

	move_and_slide()
	_update_footsteps(delta)

	# Weapon actions
	weapons.set_trigger(Input.is_action_pressed("fire"))
	if Input.is_action_just_pressed("reload"):
		weapons.reload()
	if Input.is_action_just_pressed("aim"):
		weapons.set_aiming(true)
	if Input.is_action_just_released("aim"):
		weapons.set_aiming(false)
	if Input.is_action_just_pressed("grenade") and grenades > 0:
		_throw_grenade()
	if Input.is_action_just_pressed("weapon_1"):
		weapons.switch_to(0)
	if Input.is_action_just_pressed("weapon_2"):
		weapons.switch_to(1)
	if Input.is_action_just_pressed("weapon_3"):
		weapons.switch_to(2)
	sync_weapon_index = weapons.current_index
	sync_pos = global_position
	sync_yaw = rotation.y

func set_loadout(ids: Array) -> void:
	weapons.set_loadout(ids)

## Pickup effects (run on the claiming player's authority).
func heal(value: int) -> void:
	if not is_multiplayer_authority():
		return
	sync_health = minf(MAX_HEALTH, sync_health + value)
	health_changed.emit(sync_health, MAX_HEALTH)

func add_grenades(n: int) -> void:
	if not is_multiplayer_authority():
		return
	grenades = mini(MAX_GRENADES, grenades + n)
	grenades_changed.emit(grenades)

func _throw_grenade() -> void:
	grenades -= 1
	grenades_changed.emit(grenades)
	var fwd := -camera.global_transform.basis.z
	var pos := camera.global_position + fwd * 0.6
	var vel := fwd * 16.0 + Vector3.UP * 4.0 + Vector3(velocity.x, 0, velocity.z) * 0.5
	_spawn_grenade.rpc(pos, vel)

@rpc("any_peer", "call_local", "reliable")
func _spawn_grenade(pos: Vector3, vel: Vector3) -> void:
	var g := GRENADE_SCENE.instantiate()
	g.thrower_id = combatant_id
	g.thrower_team = team
	g.authoritative = is_multiplayer_authority()
	get_tree().current_scene.add_child(g)
	g.global_position = pos
	g.linear_velocity = vel

# ---------------------------------------------------------------- damage / death

## Called by an attacker's hitscan on whatever it hit.
func hit(amount: float, attacker_id: int) -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, attacker_id: int) -> void:
	if dead:
		return
	sync_health = max(0.0, sync_health - amount)
	if is_multiplayer_authority():
		health_changed.emit(sync_health, MAX_HEALTH)
		if sync_health > 0.0:
			Audio.play_3d("res://assets/audio/hurt.ogg", global_position, -1.0, 0.05)
			_emit_damage_direction(attacker_id)
	if sync_health <= 0.0:
		_die(attacker_id)

func _emit_damage_direction(attacker_id: int) -> void:
	var a := _combatant_by_id(attacker_id)
	if a == null or a == self:
		return
	var dir: Vector3 = a.global_position - global_position
	var local := global_transform.basis.inverse() * dir
	damaged_from.emit(atan2(local.x, -local.z))

func _combatant_by_id(id: int) -> Node3D:
	for c in get_tree().get_nodes_in_group("combatant"):
		if c.get("combatant_id") == id:
			return c
	return null

func _die(attacker_id: int) -> void:
	if dead:
		return
	dead = true
	died.emit(attacker_id)
	# Report to host for scoring.
	_report_death.rpc_id(1, attacker_id, combatant_id)
	Audio.play_3d("res://assets/audio/death.ogg", global_position, 0.0, 0.05)
	body_model.visible = false
	weapons.set_hidden(true)
	name_label.visible = false
	$CollisionShape3D.disabled = true
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		_respawn_timer = 3.0
		set_process(true)

@rpc("any_peer", "call_local", "reliable")
func _report_death(attacker_id: int, victim_id: int) -> void:
	if Net.is_host():
		Game.add_kill(attacker_id, victim_id)

func _process(_delta: float) -> void:
	if dead and is_multiplayer_authority() and _respawn_timer <= 0.0:
		_request_respawn()

func _request_respawn() -> void:
	var world := get_tree().get_first_node_in_group("world")
	var xform := _spawn_point
	if world and world.has_method("get_spawn_transform"):
		xform = world.get_spawn_transform(team)
	respawn.rpc(xform)

@rpc("any_peer", "call_local", "reliable")
func respawn(xform: Transform3D) -> void:
	dead = false
	sync_health = MAX_HEALTH
	body_model.visible = not is_multiplayer_authority()  # body visible only for remotes
	weapons.set_hidden(false)
	name_label.visible = not is_multiplayer_authority()
	$CollisionShape3D.disabled = false
	if is_multiplayer_authority():
		global_transform = xform
		velocity = Vector3.ZERO
		_yaw = rotation.y
		_pitch = 0.0
		sync_pos = global_position
		sync_yaw = rotation.y
		head.rotation.x = 0.0
		set_process(false)
		grenades = MAX_GRENADES
		health_changed.emit(sync_health, MAX_HEALTH)
		grenades_changed.emit(grenades)
		weapons.refill()

func get_team() -> int:
	return team

## RIDs of this combatant's own hitbox areas, so a shooter can exclude itself.
func hitbox_rids() -> Array:
	var rids: Array = []
	if has_node("Hitboxes"):
		for a in $Hitboxes.get_children():
			if a is Area3D:
				rids.append(a.get_rid())
	return rids
