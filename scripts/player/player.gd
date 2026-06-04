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

# combatant_id == peer id for players (always positive). Used for scoring.
var combatant_id: int = 1
var team: int = -1
var display_name: String = "Player"

# Replicated state (see SceneReplicationConfig in player.tscn).
var sync_health: float = MAX_HEALTH
var sync_weapon_index: int = 0
var dead: bool = false

var _yaw: float = 0.0
var _pitch: float = 0.0
var _spawn_point: Transform3D
var _respawn_timer: float = 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var body_model: Node3D = $BodyModel
@onready var weapons: Node = $Head/Camera3D/WeaponManager
@onready var name_label: Label3D = $NameLabel
@onready var hud: CanvasLayer = $HUD if has_node("HUD") else null

signal health_changed(current: float, maximum: float)
signal ammo_changed(mag: int, reserve: int)
signal weapon_changed(weapon_name: String)
signal died(attacker_id: int)

func _ready() -> void:
	_spawn_point = global_transform
	add_to_group("combatant")
	add_to_group("player")
	name_label.text = display_name
	name_label.visible = not is_multiplayer_authority()
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
	weapons.emit_state()

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or dead:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clamp(_pitch - event.relative.y * MOUSE_SENS, deg_to_rad(-89), deg_to_rad(89))
		rotation.y = _yaw
		head.rotation.x = _pitch

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# Remote copy: keep weapon model matched to replicated index.
		weapons.ensure_index(sync_weapon_index)
		return

	if dead:
		_respawn_timer -= delta
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 24.0) * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var speed := WALK_SPEED
	if Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED
	elif Input.is_action_pressed("crouch"):
		speed = CROUCH_SPEED

	var accel := ACCEL_GROUND if is_on_floor() else ACCEL_AIR
	var target := dir * speed
	velocity.x = lerp(velocity.x, target.x, accel * delta)
	velocity.z = lerp(velocity.z, target.z, accel * delta)

	move_and_slide()

	# Weapon actions
	weapons.set_trigger(Input.is_action_pressed("fire"))
	if Input.is_action_just_pressed("reload"):
		weapons.reload()
	if Input.is_action_just_pressed("aim"):
		weapons.set_aiming(true)
	if Input.is_action_just_released("aim"):
		weapons.set_aiming(false)
	if Input.is_action_just_pressed("weapon_1"):
		weapons.switch_to(0)
	if Input.is_action_just_pressed("weapon_2"):
		weapons.switch_to(1)
	if Input.is_action_just_pressed("weapon_3"):
		weapons.switch_to(2)
	sync_weapon_index = weapons.current_index

func set_loadout(ids: Array) -> void:
	weapons.set_loadout(ids)

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
	if sync_health <= 0.0:
		_die(attacker_id)

func _die(attacker_id: int) -> void:
	if dead:
		return
	dead = true
	died.emit(attacker_id)
	# Report to host for scoring.
	_report_death.rpc_id(1, attacker_id, combatant_id)
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
		head.rotation.x = 0.0
		set_process(false)
		health_changed.emit(sync_health, MAX_HEALTH)
		weapons.refill()

func get_team() -> int:
	return team
