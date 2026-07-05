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
# Enemy bots hit ~half as hard against the player, and a single bot hit is capped so
# it can never one-shot you (no instant sniper headshots). Doesn't touch your own
# weapons or player-vs-player — bots have negative combatant ids.
const BOT_DAMAGE_SCALE := 0.5
const BOT_HIT_CAP := MAX_HEALTH * 0.7

# Crouch
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.0
const STAND_HEAD := 1.6
const CROUCH_HEAD := 1.05
const CROUCH_SPEED_FACTOR := 8.0   # how fast we transition

# Co-op downed / revive
const BLEED_TIME := 15.0
const REVIVE_RANGE := 2.6
const REVIVE_TIME := 3.0
const REVIVE_HEALTH := 40.0

# Adventure needs (only active in Adventure mode). Hunger/thirst drain over time
# (faster while sprinting) and chip health once either hits zero.
const MAX_NEED := 100.0
const HUNGER_RATE := 0.1125      # points/sec (4x slower than the original 0.45)
const THIRST_RATE := 0.175       # points/sec (4x slower; thirst drains a bit faster)
const NEED_SPRINT_MULT := 1.8
const NEED_DAMAGE := 2.0         # health/sec while starving or dehydrated

# Swimming + oxygen. You swim when your body drops below the water surface; oxygen
# drains while your head is submerged and refills at the surface, then you drown.
const SWIM_SPEED := 4.5
const SWIM_ACCEL := 6.0
const SWIM_VERT_SPEED := 5.0
const SWIM_FLOAT_DEPTH := 1.3    # idle: body floats this far below the surface (head out)
const MAX_OXYGEN := 100.0
const OXYGEN_DRAIN := 9.0        # points/sec underwater (~11 s of air)
const OXYGEN_REGEN := 45.0       # points/sec at the surface (~2 s to refill)
const DROWN_DAMAGE := 6.0        # health/sec once out of air

# Ladders
const CLIMB_SPEED := 4.0

# Fall damage: a landing faster than FALL_SAFE_SPEED hurts (≈ a >4 m drop), scaling
# with how much faster you hit the ground.
const FALL_SAFE_SPEED := 14.0
const FALL_DAMAGE_PER := 6.0

# combatant_id == peer id for players (always positive). Used for scoring.
var combatant_id: int = 1
var team: int = -1

# The combatant this player most recently shot, so allied followers can pile onto the
# same target. Stamped with a wall-clock time so the AI can ignore stale targets.
var aim_target_id: int = 0
var aim_target_t: int = 0
var display_name: String = "Player"
var faction: String = "player"   # Adventure faction (used for NPC hostility)

# Replicated state (see SceneReplicationConfig in player.tscn).
var sync_health: float = MAX_HEALTH
var sync_weapon_index: int = 0
var sync_crouch: float = 0.0   # 0 = standing, 1 = fully crouched
var sync_pos: Vector3 = Vector3.ZERO   # replicated; remotes interpolate toward it
var sync_yaw: float = 0.0
var dead: bool = false
var downed: bool = false        # co-op: incapacitated, awaiting revive (synced)
var fully_dead: bool = false    # co-op: bled out with no lives left (synced)

var _bleed: float = 0.0
var _revive_prog: float = 0.0
var _awaiting_life: bool = false

# Adventure needs (authority-owned; HUD shows the local player's only).
var hunger: float = MAX_NEED
var thirst: float = MAX_NEED
var _need_dmg_accum: float = 0.0

# Debug (solo only): free-fly noclip toggled from the [0] debug menu.
var noclip: bool = false

# Swimming / oxygen / ladders (authority-owned).
var oxygen: float = MAX_OXYGEN
var in_water: bool = false
var perks: Array = []            # character perk ids (Characters.PERKS), set on apply
var coins: int = 0               # trade currency (persisted on the character)
var _input_enabled: bool = true  # false while a menu/text field has the cursor (no gameplay input)
var near_ladder: Node = null
var is_climbing: bool = false    # on a ladder right now (out of melee reach)
var _water_y: float = -1.0e20    # cached water-surface height (sentinel = unknown)
var _oxy_dmg_accum: float = 0.0
var _ladder_detach: float = 0.0  # brief no-grab window after jumping off a ladder
var _air_speed: float = 0.0      # peak downward speed while airborne, for fall damage

# Run stats (local only) for the Stats tab: distance, shots, accuracy.
var meters_walked: float = 0.0
var shots_fired: int = 0
var shots_hit: int = 0

# Adventure backpack: a spatial grid (backpack_w x backpack_h). Items are non-stacking
# and occupy a w x h footprint at a placed (gx, gy); fixed orientation.
var backpack_w: int = ItemDB.DEFAULT_GRID_W
var backpack_h: int = ItemDB.DEFAULT_GRID_H
var inventory: Array = []
var _drop_counter: int = 0

# Equipment slots: armor (head/body/pants) + a throwable slot. Guns live in the
# weapon loadout (gun1/2/3 in the UI mirror weapons.loadout).
var equip: Dictionary = {"head": {}, "body": {}, "pants": {}, "extra": {}, "gadget": {}}

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
signal hunger_changed(value: float, maximum: float)
signal thirst_changed(value: float, maximum: float)
signal oxygen_changed(value: float, maximum: float)
signal inventory_changed
signal equipment_changed
signal talk_to(info: Dictionary)
signal damaged_from(angle: float)
signal downed_changed(is_downed: bool, bleed_frac: float, revive_frac: float, spectator: bool)
signal died(attacker_id: int)

const MAX_GRENADES := 2
const GRENADE_SCENE := preload("res://scenes/grenade.tscn")
const PICKUP_SCENE := preload("res://scenes/pickup.tscn")
var grenades: int = MAX_GRENADES

const ENTER_RANGE := 3.5
const NPC_TALK_RANGE := 4.5
var driving: Node = null       # the vehicle we're in, or null
var near_vehicle: bool = false
var near_npc: Node = null      # Adventure: nearest talkable (non-hostile) NPC, or null
var near_pickup: Node = null   # Adventure: nearest collectable pickup (press E), or null
var _cam_yaw: float = 0.0      # drive-camera orbit (relative to car)
var _cam_pitch: float = 0.0
var _cam_idle: float = 0.0

# Camera juice (local view only): walk bob, landing dip, and blast/hit shake.
var _cam_base_pos := Vector3.ZERO
var _cam_bob_t: float = 0.0
var _cam_dip: float = 0.0       # downward kick on hard landings (eases back)
var _cam_shake: float = 0.0     # trauma 0..1; screen shakes by trauma^2

func _ready() -> void:
	_spawn_point = global_transform
	sync_pos = global_position
	sync_yaw = rotation.y
	# Own copy of the capsule so crouch resizing is per-player, not shared.
	col_shape.shape = col_shape.shape.duplicate()
	add_to_group("combatant")
	add_to_group("player")
	name_label.text = display_name
	# Battle Royale is a stealthy FFA: hide every floating name tag so labels never
	# reveal positions. Otherwise remote players show their name.
	name_label.visible = not is_multiplayer_authority() and not Game.is_battle_royale()
	if Game.is_team_mode():
		name_label.modulate = Game.team_color(team)
	camera.fov = Settings.fov
	_cam_base_pos = camera.position
	equipment_changed.connect(_update_worn_armor)   # show/hide worn armor primitives
	_body_anim = _find_body_anim(body_model)
	_body_anim_pos = global_position
	if _body_anim != null:
		for clip in ["walk", "sprint", "idle"]:
			if _body_anim.has_animation(clip):
				_body_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		if _body_anim.has_animation("idle"):
			_body_anim.play("idle")
	weapons.setup(self, camera)
	# Equip weapons on every peer (so remote players also show a gun and the
	# local player can actually fire). Runs before set_local/_emit_hud below.
	# In Adventure you spawn with just a pistol already equipped (slot 1); the
	# backpack starts empty (see _fill_adventure_start).
	if Game.is_adventure():
		weapons.set_loadout(["pistol"])
		_fill_adventure_start()
		# A chosen character brings their saved gear/loadout/appearance with them.
		if is_multiplayer_authority() and Characters.has_current():
			Characters.apply_to_player(self)
			name_label.text = display_name
			get_tree().create_timer(1.5).timeout.connect(_broadcast_tint)
	else:
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
	# Q activates the equipped gadget (only while actually playing).
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_Q and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_use_gadget()
		return
	# V = melee swing (always usable, even with no ammo).
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_V and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if driving == null:
			weapons.melee()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := MOUSE_SENS * Settings.mouse_sensitivity
		if driving != null:
			# Orbit the chase camera around the car (pitch inverted on purpose).
			_cam_yaw -= event.relative.x * sens
			_cam_pitch = clamp(_cam_pitch + event.relative.y * sens, deg_to_rad(-55), deg_to_rad(35))
			_cam_idle = 0.0
		else:
			_yaw -= event.relative.x * sens
			_pitch = clamp(_pitch - event.relative.y * sens, deg_to_rad(-89), deg_to_rad(89))
			rotation.y = _yaw
			head.rotation.x = _pitch

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# Remote copy: keep weapon model + crouch/downed pose matched, and smoothly
		# interpolate toward the replicated transform instead of snapping.
		weapons.ensure_index(sync_weapon_index)
		if downed or fully_dead:
			body_model.scale.y = 0.5
			weapons.set_hidden(true)
		else:
			weapons.set_hidden(false)
			_apply_crouch(sync_crouch)
		var t := clampf(15.0 * delta, 0.0, 1.0)
		if global_position.distance_to(sync_pos) > 5.0:
			global_position = sync_pos  # snap on teleport / respawn
		else:
			global_position = global_position.lerp(sync_pos, t)
		rotation.y = lerp_angle(rotation.y, sync_yaw, t)
		_update_body_anim(delta)   # animate the third-person body others see
		return

	if dead:
		_respawn_timer -= delta
		return

	if fully_dead:
		return
	if downed:
		_update_downed(delta)
		return

	if Game.is_adventure():
		_update_needs(delta)

	# Driving a vehicle redirects all movement input to the vehicle.
	if driving != null and is_instance_valid(driving):
		if driving.is_in_group("aircraft"):
			_fly_vehicle(delta)
		else:
			_drive_vehicle(delta)
		return
	near_vehicle = _nearest_vehicle() != null
	near_npc = _nearest_talkable_npc() if Game.is_adventure() else null
	near_pickup = _nearest_pickup() if Game.is_adventure() else null
	near_ladder = _nearest_ladder()
	# When a menu or text field is open the cursor is freed; suppress all gameplay
	# input so typing to an NPC (or browsing the backpack) doesn't move/act/shoot.
	_input_enabled = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _input_enabled and Input.is_action_just_pressed("interact"):
		if near_vehicle:
			_enter_vehicle(_nearest_vehicle())
			return
		elif near_pickup != null:
			near_pickup.collect(self)
		elif near_npc != null:
			_talk_to(near_npc)
		elif near_campfire() and hud != null and hud.has_method("open_crafting"):
			hud.open_crafting()   # cook / craft at the fire

	# Swimming + oxygen: switch to swim physics when the body is below the surface.
	if _water_y < -1.0e19:
		_update_water_level()
	in_water = global_position.y < _water_y
	_update_oxygen(delta, head.global_position.y < _water_y)

	_ladder_detach = maxf(0.0, _ladder_detach - delta)
	is_climbing = not in_water and near_ladder != null and _ladder_detach <= 0.0 and _wants_climb()
	if noclip:
		_noclip_move(delta)
	elif in_water:
		_swim(delta)
	elif is_climbing:
		_climb(delta, near_ladder)
	else:
		# Crouch (hold). Can't stand back up if something is overhead.
		var want_crouch := _input_enabled and Input.is_action_pressed("crouch")
		if not want_crouch and _crouch > 0.05 and not _has_headroom():
			want_crouch = true
		_crouch = move_toward(_crouch, 1.0 if want_crouch else 0.0, CROUCH_SPEED_FACTOR * delta)
		sync_crouch = _crouch
		_apply_crouch(_crouch)

		# Gravity
		if not is_on_floor():
			velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 24.0) * delta

		if _input_enabled and Input.is_action_just_pressed("jump") and is_on_floor() and _crouch < 0.5:
			velocity.y = JUMP_VELOCITY

		var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if _input_enabled else Vector2.ZERO
		var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

		var speed := WALK_SPEED
		if _crouch > 0.3:
			speed = CROUCH_SPEED
		elif _input_enabled and Input.is_action_pressed("sprint"):
			speed = SPRINT_SPEED

		var accel := ACCEL_GROUND if is_on_floor() else ACCEL_AIR
		var target := dir * speed
		velocity.x = lerp(velocity.x, target.x, accel * delta)
		velocity.z = lerp(velocity.z, target.z, accel * delta)

		_jetpack(delta)
		move_and_slide()
		# Fall damage: track peak downward speed in the air, apply it on landing.
		if is_on_floor():
			_apply_fall_landing()
		else:
			_air_speed = maxf(_air_speed, -velocity.y)
	if is_multiplayer_authority():
		meters_walked += Vector2(velocity.x, velocity.z).length() * delta
	_update_footsteps(delta)

	# Weapon actions only while actively playing (cursor captured). When a menu or
	# the backpack is open the cursor is free, so clicking UI must not fire/act.
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		weapons.set_trigger(Input.is_action_pressed("fire"))
		if Input.is_action_just_pressed("reload"):
			weapons.reload()
		if Input.is_action_just_pressed("aim"):
			weapons.set_aiming(true)
		if Input.is_action_just_released("aim"):
			weapons.set_aiming(false)
		if Input.is_action_just_pressed("grenade") and _can_throw_grenade():
			_throw_grenade()
		if Input.is_action_just_pressed("weapon_1"):
			weapons.switch_to(0)
		if Input.is_action_just_pressed("weapon_2"):
			weapons.switch_to(1)
		if Input.is_action_just_pressed("weapon_3"):
			weapons.switch_to(2)
	else:
		weapons.set_trigger(false)
		weapons.set_aiming(false)
	sync_weapon_index = weapons.current_index
	_tick_gadget(delta)
	_update_camera_fx(delta)
	_update_body_anim(delta)
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

# ---------------------------------------------------------------- debug (solo)
# These back the [0] debug menu. They only ever run for the local authority player in a
# solo game, so they mutate state directly rather than routing through combat RPCs.

## Free-fly movement: drift along the camera's look direction, ignoring gravity/collision.
func _noclip_move(delta: float) -> void:
	var id := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if _input_enabled else Vector2.ZERO
	var move := camera.global_transform.basis * Vector3(id.x, 0, id.y)
	if _input_enabled and Input.is_action_pressed("jump"):
		move.y += 1.0
	if _input_enabled and Input.is_action_pressed("crouch"):
		move.y -= 1.0
	var speed := 22.0 if (_input_enabled and Input.is_action_pressed("sprint")) else 10.0
	velocity = Vector3.ZERO
	if move.length() > 0.01:
		global_position += move.normalized() * speed * delta
	sync_pos = global_position

## Enable/disable noclip: turn off world collision so you can pass through geometry.
func debug_set_noclip(on: bool) -> void:
	noclip = on
	collision_mask = 0 if on else 7   # 7 = the player's normal world/prop/vehicle mask
	if on:
		velocity = Vector3.ZERO

func debug_add_health(n: float) -> void:
	sync_health = clampf(sync_health + n, 0.0, MAX_HEALTH)
	health_changed.emit(sync_health, MAX_HEALTH)

func debug_add_thirst(n: float) -> void:
	thirst = clampf(thirst + n, 0.0, MAX_NEED)

func debug_add_hunger(n: float) -> void:
	hunger = clampf(hunger + n, 0.0, MAX_NEED)

## Spawn any item/weapon by id as a world pickup a couple of metres in front of you (so it
## lands in the world to grab, not silently into the backpack).
func debug_spawn_item(id: String) -> bool:
	var it: Dictionary = ItemDB.make_weapon(id) if WeaponDB.has_weapon(id) else ItemDB.make(id)
	if it.is_empty():
		return false
	var pos := global_position + (-global_transform.basis.z) * 2.0 + Vector3.UP * 0.5
	_spawn_dropped_item.rpc(combatant_id, _drop_counter, it, pos)
	_drop_counter += 1
	return true

func add_grenades(n: int) -> void:
	if not is_multiplayer_authority():
		return
	grenades = mini(MAX_GRENADES, grenades + n)
	grenades_changed.emit(grenades)

# ---------------------------------------------------------------- grenades (Adventure)
# In Adventure grenades are inventory items: the HUD count is the total you hold across
# the Extra gear slot + backpack. You can only throw when one is equipped in the Extra
# slot, and throws spend loose backpack grenades first (the equipped one is the last to
# go). In other modes `grenades` is a plain per-life counter (no inventory).

## Throwable grenades: the equipped Extra-slot grenade plus every backpack grenade OF THE
## SAME TYPE. Grenades of other types don't count (you can only throw the equipped kind),
## so equipping a frag never lets a smoke/flash get spent as a frag. Zero if none equipped.
func grenade_count() -> int:
	var g: Dictionary = equip.get("extra", {})
	if String(g.get("kind", "")) != "grenade":
		return 0
	var gtype := String(g.get("gtype", "frag"))
	var n := int(g.get("amount", 1))
	for it in inventory:
		if String(it.get("kind", "")) == "grenade" and String(it.get("gtype", "frag")) == gtype:
			n += int(it.get("amount", 1))
	return n

## True when a grenade is equipped in the Extra slot (required to throw in Adventure).
func _grenade_equipped() -> bool:
	return String(equip.get("extra", {}).get("kind", "")) == "grenade"

## Recompute the displayed total from inventory + gear and push it to the HUD.
func _refresh_grenades() -> void:
	grenades = grenade_count()
	grenades_changed.emit(grenades)

## Consume one grenade of the EQUIPPED TYPE for a throw: a matching backpack grenade
## first, then the equipped Extra slot itself. Only the equipped type is ever spent, so
## carrying other grenade types is never affected. Returns false if none could be spent.
func _consume_grenade() -> bool:
	var g: Dictionary = equip.get("extra", {})
	if String(g.get("kind", "")) != "grenade":
		return false
	var gtype := String(g.get("gtype", "frag"))
	# Spend a loose backpack grenade of the same type first; the equipped one goes last.
	for i in inventory.size():
		if String(inventory[i].get("kind", "")) == "grenade" and String(inventory[i].get("gtype", "frag")) == gtype:
			var amt := int(inventory[i].get("amount", 1))
			if amt > 1:
				inventory[i]["amount"] = amt - 1
			else:
				inventory.remove_at(i)
			inventory_changed.emit()
			_refresh_grenades()
			return true
	# None loose of this type -> spend the equipped grenade itself.
	var amt2 := int(g.get("amount", 1))
	if amt2 > 1:
		equip["extra"]["amount"] = amt2 - 1
	else:
		equip["extra"] = {}
	equipment_changed.emit()
	_refresh_grenades()
	return true

# ---------------------------------------------------------------- adventure needs

## Drain hunger/thirst over time (faster while sprinting); chip health when empty.
func _update_needs(delta: float) -> void:
	var moving := Vector2(velocity.x, velocity.z).length() > 1.2
	var mult := NEED_SPRINT_MULT if (moving and Input.is_action_pressed("sprint")) else 1.0
	var h0 := hunger
	var t0 := thirst
	hunger = maxf(0.0, hunger - HUNGER_RATE * mult * delta)
	thirst = maxf(0.0, thirst - THIRST_RATE * mult * delta)
	if not is_equal_approx(hunger, h0):
		hunger_changed.emit(hunger, MAX_NEED)
	if not is_equal_approx(thirst, t0):
		thirst_changed.emit(thirst, MAX_NEED)
	if hunger <= 0.0 or thirst <= 0.0:
		_need_dmg_accum += delta
		if _need_dmg_accum >= 1.0:
			_need_dmg_accum = 0.0
			receive_damage(NEED_DAMAGE, combatant_id)  # starvation/dehydration
	else:
		_need_dmg_accum = 0.0

# ---------------------------------------------------------------- swimming / oxygen

## Cache the water surface height from the map's water plane (sentinel if no water).
func _update_water_level() -> void:
	var y := -1.0e20
	for w in get_tree().get_nodes_in_group("water"):
		if w is Node3D:
			y = maxf(y, (w as Node3D).global_position.y)
	_water_y = y

func _update_oxygen(delta: float, head_under: bool) -> void:
	var o0 := oxygen
	if head_under:
		var drain := OXYGEN_DRAIN * (0.6 if perks.has("lungs") else 1.0)
		oxygen = maxf(0.0, oxygen - drain * delta)
		if oxygen <= 0.0:
			_oxy_dmg_accum += delta
			if _oxy_dmg_accum >= 1.0:
				_oxy_dmg_accum = 0.0
				receive_damage(DROWN_DAMAGE, combatant_id)  # drowning
	else:
		oxygen = minf(MAX_OXYGEN, oxygen + OXYGEN_REGEN * delta)
		_oxy_dmg_accum = 0.0
	if not is_equal_approx(oxygen, o0):
		oxygen_changed.emit(oxygen, MAX_OXYGEN)

## Swim physics: horizontal from look-yaw input, vertical from jump/dive + buoyancy
## that floats you to the surface when you're not actively diving/ascending.
func _swim(delta: float) -> void:
	_crouch = 0.0
	sync_crouch = 0.0
	_air_speed = 0.0   # water breaks the fall — no landing damage
	_apply_crouch(0.0)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if _input_enabled else Vector2.ZERO
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y))
	velocity.x = lerp(velocity.x, dir.x * SWIM_SPEED, SWIM_ACCEL * delta)
	velocity.z = lerp(velocity.z, dir.z * SWIM_SPEED, SWIM_ACCEL * delta)
	var vy := 0.0
	if _input_enabled and Input.is_action_pressed("jump"):
		vy += 1.0
	if _input_enabled and Input.is_action_pressed("crouch"):
		vy -= 1.0
	var target_vy := vy * SWIM_VERT_SPEED
	if absf(vy) < 0.01:
		# Buoyancy: settle so the head rests just above the surface.
		var depth := _water_y - global_position.y
		target_vy = clampf(depth - SWIM_FLOAT_DEPTH, -1.0, 1.0) * SWIM_VERT_SPEED
	velocity.y = lerp(velocity.y, target_vy, SWIM_ACCEL * delta)
	move_and_slide()

# ---------------------------------------------------------------- ladders

## The ladder volume the player is currently within (horizontally close + in its
## height span), or null. Ladders are Node3Ds in group "ladder" with bottom/top meta.
func _nearest_ladder() -> Node:
	for l in get_tree().get_nodes_in_group("ladder"):
		var bottom: Vector3 = l.get_meta("bottom")
		var top: Vector3 = l.get_meta("top")
		var r: float = float(l.get_meta("radius", 1.1))
		var horiz := Vector2(global_position.x - bottom.x, global_position.z - bottom.z).length()
		if horiz < r and global_position.y > bottom.y - 1.0 and global_position.y < top.y + 1.0:
			return l
	return null

## On a ladder you climb with forward/back, or whenever you're off the floor
## (mid-climb). Standing idle at the base lets you walk away normally. Jump is NOT
## a climb input — it detaches you from the ladder (see _climb).
func _wants_climb() -> bool:
	if not _input_enabled:
		return not is_on_floor()   # keep clinging mid-climb, but don't grab while typing
	var up := Input.is_action_pressed("move_forward")
	var down := Input.is_action_pressed("move_back") or Input.is_action_pressed("crouch")
	return up or down or not is_on_floor()

const LADDER_OFFSET := 0.5   # stand this far out in front of the rungs

func _climb(delta: float, l: Node) -> void:
	_crouch = 0.0
	sync_crouch = 0.0
	_air_speed = 0.0   # grabbing the ladder cancels any fall
	_apply_crouch(0.0)
	var bottom: Vector3 = l.get_meta("bottom")
	var top: Vector3 = l.get_meta("top")
	var normal: Vector3 = l.get_meta("normal", Vector3(0, 0, -1))  # outward, toward climber

	# Space jumps OFF the ladder — leap outward and up, with a brief no-regrab window.
	if _input_enabled and Input.is_action_just_pressed("jump"):
		velocity = normal * 6.0 + Vector3.UP * (JUMP_VELOCITY * 0.8)
		_ladder_detach = 0.4
		move_and_slide()
		return

	var up := 0.0
	if _input_enabled and Input.is_action_pressed("move_forward"):
		up += 1.0
	if _input_enabled and (Input.is_action_pressed("move_back") or Input.is_action_pressed("crouch")):
		up -= 1.0
	velocity.y = up * CLIMB_SPEED

	# Stand a little out in front of the rungs (not embedded in the ladder), hugging
	# that offset line so you stay aligned while climbing. This also pulls you off the
	# platform edge when you start a descent, so the floor stops holding you up.
	var stand := Vector3(bottom.x, 0.0, bottom.z) + normal * LADDER_OFFSET
	velocity.x = (stand.x - global_position.x) * 6.0
	velocity.z = (stand.z - global_position.z) * 6.0

	# At the top, climbing up steps inward (toward the platform) and over the lip.
	if global_position.y >= top.y - 0.6 and up > 0.0:
		var inward := -normal
		velocity.x = inward.x * WALK_SPEED
		velocity.z = inward.z * WALK_SPEED
		velocity.y = CLIMB_SPEED
	move_and_slide()

## Apply fall damage for the speed built up while airborne, then reset. A landing
## faster than FALL_SAFE_SPEED hurts, scaling with the excess.
# ---------------------------------------------------------------- crafting (Adventure)
const CAMPFIRE_SCENE := preload("res://scenes/campfire.tscn")

## How many of an item id the backpack holds.
func _count_material(id: String) -> int:
	var n := 0
	for it in inventory:
		if String(it.get("id", "")) == id:
			n += int(it.get("amount", 1))
	return n

func near_campfire() -> bool:
	return _nearest_campfire() != null

func _nearest_campfire() -> Node:
	for f in get_tree().get_nodes_in_group("campfire"):
		if is_instance_valid(f) and f.global_position.distance_to(global_position) < 5.0:
			return f
	return null

## Spend one wood to extend the nearest campfire (returns true on success).
func feed_campfire() -> bool:
	if not is_multiplayer_authority() or _count_material("wood") <= 0:
		return false
	var fire := _nearest_campfire()
	if fire == null or not fire.has_method("feed"):
		return false
	# Remove one wood.
	for i in inventory.size():
		if String(inventory[i].get("id", "")) == "wood":
			inventory.remove_at(i)
			break
	fire.feed()
	inventory_changed.emit()
	return true

## Whether the recipe's inputs (and fire requirement) are currently satisfied.
func can_craft(recipe: Dictionary) -> bool:
	if bool(recipe.get("fire", false)) and not near_campfire():
		return false
	for id in (recipe.get("in", {}) as Dictionary):
		if _count_material(String(id)) < int(recipe["in"][id]):
			return false
	return true

## Consume the recipe's inputs and produce its output (item or a deployed campfire).
func craft(recipe: Dictionary) -> bool:
	if not is_multiplayer_authority() or not can_craft(recipe):
		return false
	for id in (recipe.get("in", {}) as Dictionary):
		var need := int(recipe["in"][id])
		var i := 0
		while need > 0 and i < inventory.size():
			if String(inventory[i].get("id", "")) == String(id):
				inventory.remove_at(i)
				need -= 1
			else:
				i += 1
	var out := String(recipe["out"])
	if out == "_campfire":
		_deploy_campfire()
	else:
		if not inv_add(ItemDB.make(out)):
			_drop_item_world(ItemDB.make(out))   # no room — drop it at your feet
	inventory_changed.emit()
	return true

func _deploy_campfire() -> void:
	_place_campfire.rpc(global_position - global_transform.basis.z * 1.5)

@rpc("any_peer", "call_local", "reliable")
func _place_campfire(pos: Vector3) -> void:
	var f := CAMPFIRE_SCENE.instantiate()
	get_tree().current_scene.add_child(f)
	f.global_position = pos

func _drop_item_world(item: Dictionary) -> void:
	var p := PICKUP_SCENE.instantiate()
	p.kind = "food"
	p.item_data = item
	get_tree().current_scene.add_child(p)
	p.global_position = global_position + Vector3(0, 0.4, 0)

# ---------------------------------------------------------------- gadgets (Adventure)
# The Gadget slot holds one special item; Q activates it. Flashlight and night-vision
# toggle on/off; binoculars toggle a zoom; the scanner pings on each press.

var _gadget_on: bool = false       # flashlight / nvg / binoculars sustained state
var glassing: bool = false         # binoculars zoom active (weapon_manager reads this)
var reveal_until: int = 0          # msec until which the minimap reveals all enemies
var _flashlight: SpotLight3D = null
var _torch_light: OmniLight3D = null    # warm omnidirectional glow, flickers while lit
var _torch_flicker: float = 1.0         # smoothed flicker multiplier (~0.7..1.15)

func equipped_gadget() -> String:
	return String(equip.get("gadget", {}).get("gadget", ""))

func _use_gadget() -> void:
	var g := equipped_gadget()
	if g == "":
		return
	match g:
		"scanner":
			reveal_until = Time.get_ticks_msec() + 5000   # 5 s radar sweep
			Audio.play_3d("res://assets/audio/ui_click.ogg", global_position, -4.0)
		"shovel":
			_dig_hole()   # dig a hole into the terrain just ahead
		_:
			_gadget_on = not _gadget_on
			_apply_gadget()

## Push the current gadget's on/off state to its effect (light, zoom, overlay).
func _apply_gadget() -> void:
	var g := equipped_gadget()
	# Flashlight.
	if _flashlight == null:
		_flashlight = SpotLight3D.new()
		_flashlight.spot_range = 28.0
		_flashlight.spot_angle = 32.0
		_flashlight.light_energy = 6.0
		_flashlight.rotation_degrees.x = 0.0
		# Cull mask 1 = light the world (render layer 1) but never the held weapon,
		# which sits on render layer 2 (set in weapon_manager).
		_flashlight.light_cull_mask = 1
		camera.add_child(_flashlight)
	# The flashlight is a tight white beam; a torch is a separate warm omni glow (below).
	_flashlight.visible = _gadget_on and g == "flashlight"
	if _flashlight.visible:
		_flashlight.light_color = Color(1, 1, 1)
		_flashlight.spot_range = 28.0
	# Torch: a soft omnidirectional fire-glow that pools around you rather than casting a
	# beam. Held down-and-forward like a hand torch; energy/range/tint are driven in
	# _tick_gadget so it flickers. Warmer, shorter, and far softer-edged than the flashlight.
	if _torch_light == null:
		_torch_light = OmniLight3D.new()
		_torch_light.omni_range = 13.0
		_torch_light.light_color = Color(1.0, 0.6, 0.28)
		_torch_light.light_energy = 3.2
		_torch_light.omni_attenuation = 1.6   # falls off quickly, like real firelight
		_torch_light.light_cull_mask = 1       # light the world, not the held viewmodel
		_torch_light.position = Vector3(0.25, -0.35, -0.55)
		camera.add_child(_torch_light)
	_torch_light.visible = _gadget_on and g == "torch"
	# Binoculars zoom (handled in camera FX / weapon manager).
	glassing = _gadget_on and g == "binoculars"
	# Night-vision overlay on the HUD.
	if hud and hud.has_method("set_nightvision"):
		hud.set_nightvision(_gadget_on and g == "nvg")

## Per-frame gadget upkeep: torch burns its fuel while lit (and is consumed when spent);
## jetpack thrust is handled in the movement code.
func _tick_gadget(delta: float) -> void:
	_dig_cd = maxf(0.0, _dig_cd - delta)
	var g := equipped_gadget()
	# Flicker the torch flame every frame while it's lit: a fast random target chased
	# smoothly so the glow shimmers and its warm/cool tint wavers, never a steady beam.
	if _torch_light != null and _torch_light.visible:
		var target := randf_range(0.72, 1.16)
		_torch_flicker = lerpf(_torch_flicker, target, clampf(delta * 14.0, 0.0, 1.0))
		_torch_light.light_energy = 3.2 * _torch_flicker
		_torch_light.omni_range = 13.0 * (0.9 + 0.1 * _torch_flicker)
		# Brighter licks run yellower; dips go a touch redder.
		_torch_light.light_color = Color(1.0, 0.52 + 0.12 * _torch_flicker, 0.22 + 0.1 * _torch_flicker)
	if g == "torch" and _gadget_on:
		var piece: Dictionary = equip.get("gadget", {})
		var fuel := float(piece.get("cur_fuel", 0.0)) - delta
		piece["cur_fuel"] = fuel
		if fuel <= 0.0:
			equip["gadget"] = {}   # torch burned out — gone
			_gadget_on = false
			_apply_gadget()
			equipment_changed.emit()

## Jetpack: hold jump while airborne to thrust upward, draining fuel that recharges on
## the ground. No-op unless a jetpack is the equipped gadget.
func _jetpack(delta: float) -> void:
	if equipped_gadget() != "jetpack":
		return
	var jp: Dictionary = equip.get("gadget", {})
	var fuel := float(jp.get("cur_fuel", 0.0))
	var maxf_jp := float(jp.get("fuel", 100.0))
	if is_on_floor():
		fuel = minf(maxf_jp, fuel + 28.0 * delta)   # refuel on the ground
	elif _input_enabled and Input.is_action_pressed("jump") and fuel > 0.0:
		velocity.y = move_toward(velocity.y, 7.5, 34.0 * delta)   # climb against gravity
		fuel = maxf(0.0, fuel - 26.0 * delta)
		_air_speed = 0.0   # thrusting cancels fall damage
	jp["cur_fuel"] = fuel

## Shovel: dig a real bowl-shaped hole into the terrain just ahead of the player.
## Repeated digs deepen/widen the pit. Replicated so every peer deforms identically.
var _dig_cd: float = 0.0
func _dig_hole() -> void:
	if _dig_cd > 0.0:
		return
	_dig_cd = 0.45
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	# Dig at the ground in front of the feet.
	var pos := global_position + fwd * 1.6
	pos.y -= 1.0
	_dig_terrain_hole.rpc(pos)

@rpc("any_peer", "call_local", "reliable")
func _dig_terrain_hole(pos: Vector3) -> void:
	var map := get_tree().get_first_node_in_group("map")
	if map != null and map.has_method("dig_hole"):
		map.dig_hole(pos, 2.6, 1.2)
	_dig_fx(pos)

## A quick puff of dirt where the shovel bites.
func _dig_fx(pos: Vector3) -> void:
	Audio.play_3d("res://assets/audio/impact.ogg", pos, -4.0, 0.1)
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = 14
	p.lifetime = 0.6
	p.explosiveness = 0.85
	p.direction = Vector3(0, 1, 0)
	p.spread = 40.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 4.0
	p.gravity = Vector3(0, -9.0, 0)
	p.scale_amount_min = 0.15
	p.scale_amount_max = 0.35
	var mesh := SphereMesh.new()
	mesh.radius = 0.12
	mesh.height = 0.24
	mesh.radial_segments = 5
	mesh.rings = 3
	p.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.32, 0.22)
	p.mesh.surface_set_material(0, mat)
	get_tree().current_scene.add_child(p)
	p.global_position = pos + Vector3.UP * 0.3
	get_tree().create_timer(1.2).timeout.connect(p.queue_free)

## Clear gadget state when the slot is emptied or changed.
func _reset_gadget() -> void:
	_gadget_on = false
	_apply_gadget()

# ---------------------------------------------------------------- worn armor
# Simple primitive armor shown on the body per equipped slot (procedural, no assets).
var _worn: Dictionary = {}   # slot -> MeshInstance3D

func _update_worn_armor() -> void:
	if body_model == null:
		return
	# slot -> [box size, local y]
	var spec := {
		"head":  [Vector3(0.55, 0.45, 0.55), 2.42],
		"body":  [Vector3(0.85, 0.9, 0.55), 1.55],
		"pants": [Vector3(0.7, 0.9, 0.55), 0.78],
	}
	for slot in spec:
		var has: bool = String((equip.get(slot, {}) as Dictionary).get("kind", "")) == "armor"
		if has and not _worn.has(slot):
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = spec[slot][0]
			mi.mesh = box
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.5, 0.55, 0.62)
			m.metallic = 0.6
			m.roughness = 0.5
			mi.material_override = m
			mi.position = Vector3(0, spec[slot][1], 0)
			body_model.add_child(mi)
			_worn[slot] = mi
		elif not has and _worn.has(slot):
			if is_instance_valid(_worn[slot]):
				_worn[slot].queue_free()
			_worn.erase(slot)

func _apply_fall_landing() -> void:
	# A perceptible landing: dip the camera (and shake hard for real falls).
	if _air_speed > 5.0:
		_cam_dip = minf(0.18, _air_speed * 0.012)
		if _air_speed > FALL_SAFE_SPEED:
			add_camera_shake(0.5)
	if _air_speed > FALL_SAFE_SPEED:
		receive_damage((_air_speed - FALL_SAFE_SPEED) * FALL_DAMAGE_PER, combatant_id)
	_air_speed = 0.0

## Add screen-shake trauma (0..1, clamped). Called by landings, blasts, and big hits.
func add_camera_shake(amount: float) -> void:
	_cam_shake = clampf(_cam_shake + amount, 0.0, 1.0)

## Local view juice: subtle head bob while walking, landing dip, and decaying shake.
## Only the authority owns a camera, so this is purely cosmetic and unsynced.
func _update_camera_fx(delta: float) -> void:
	if not is_multiplayer_authority() or driving != null:
		return
	var off := Vector3.ZERO
	var rot := Vector3.ZERO
	# Head bob while moving on the ground.
	var horiz := Vector2(velocity.x, velocity.z).length()
	var move_amt := clampf(horiz / 9.0, 0.0, 1.0)
	if is_on_floor() and move_amt > 0.05:
		_cam_bob_t += delta * 11.0
		off.y += sin(_cam_bob_t * 2.0) * 0.018 * move_amt
		off.x += sin(_cam_bob_t) * 0.012 * move_amt
	else:
		# Standing still: a faint breathing rise/fall so the view feels alive.
		_cam_bob_t += delta * 1.5
		off.y += sin(_cam_bob_t) * 0.004
	# Landing dip eases back up.
	_cam_dip = move_toward(_cam_dip, 0.0, delta * 0.9)
	off.y -= _cam_dip
	# Trauma-based shake (decays quickly; offset + roll scale with trauma squared).
	if _cam_shake > 0.0:
		_cam_shake = maxf(0.0, _cam_shake - delta * 1.8)
		var s := _cam_shake * _cam_shake
		off.x += (_rng_shake() ) * 0.06 * s
		off.y += (_rng_shake()) * 0.06 * s
		rot.z = _rng_shake() * 0.05 * s
		rot.x = _rng_shake() * 0.03 * s
	camera.position = camera.position.lerp(_cam_base_pos + off, clampf(18.0 * delta, 0.0, 1.0))
	camera.rotation.z = lerpf(camera.rotation.z, rot.z, clampf(20.0 * delta, 0.0, 1.0))
	camera.rotation.x = lerpf(camera.rotation.x, rot.x, clampf(20.0 * delta, 0.0, 1.0))

func _rng_shake() -> float:
	return randf() * 2.0 - 1.0

# ---------------------------------------------------------------- body animation
# The third-person body (what other players see) plays idle/walk/sprint from speed.
var _body_anim: AnimationPlayer = null
var _body_anim_pos := Vector3.ZERO
var _body_anim_speed: float = 0.0

func _find_body_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_body_anim(c)
		if r != null:
			return r
	return null

func _update_body_anim(delta: float) -> void:
	if _body_anim == null:
		return
	var d := global_position - _body_anim_pos
	d.y = 0.0
	_body_anim_speed = lerpf(_body_anim_speed, d.length() / maxf(delta, 0.001), 0.25)
	_body_anim_pos = global_position
	var want := "idle"
	if _body_anim_speed > 7.5 and _body_anim.has_animation("sprint"):
		want = "sprint"
	elif _body_anim_speed > 0.6 and _body_anim.has_animation("walk"):
		want = "walk"
	if _body_anim.current_animation != want and _body_anim.has_animation(want):
		_body_anim.play(want, 0.18)

var _tint: Color = Color.TRANSPARENT

## Tint the body model to the character's colour (Adventure appearance).
func set_body_tint(c: Color) -> void:
	_tint = c
	for mi in _mesh_instances(body_model):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		mi.material_override = m

## Replicate the local character's tint to every peer (their copy of us spawns with
## the default body). Called a beat after spawn so remote instances exist.
func _broadcast_tint() -> void:
	if _tint.a > 0.0:
		_share_tint.rpc(_tint)

@rpc("any_peer", "reliable")
func _share_tint(c: Color) -> void:
	if not is_multiplayer_authority():
		set_body_tint(c)

func _mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for child in n.get_children():
		out.append_array(_mesh_instances(child))
	return out

## Adventure: spawn unarmed with the default guns + grenades stowed in the backpack.
func _fill_adventure_start() -> void:
	if not is_multiplayer_authority():
		return
	# Start with only the equipped pistol — empty backpack, no grenades.
	grenades = 0
	grenades_changed.emit(grenades)
	# In Adventure the grenade count tracks inventory, so recompute it whenever the
	# backpack changes (pickups, trades, drops, equips).
	if not inventory_changed.is_connected(_refresh_grenades):
		inventory_changed.connect(_refresh_grenades)

## Consumables (Adventure #3) call these to restore the needs.
func eat(amount: float) -> void:
	if not is_multiplayer_authority():
		return
	hunger = minf(MAX_NEED, hunger + amount)
	hunger_changed.emit(hunger, MAX_NEED)

func drink(amount: float) -> void:
	if not is_multiplayer_authority():
		return
	thirst = minf(MAX_NEED, thirst + amount)
	thirst_changed.emit(thirst, MAX_NEED)

# ---------------------------------------------------------------- adventure backpack

func inv_cell_count() -> int:
	return backpack_w * backpack_h

## Cells the carried items occupy (sum of footprints).
func inv_used() -> int:
	var u := 0
	for it in inventory:
		u += int(it.get("w", 1)) * int(it.get("h", 1))
	return u

## Occupancy grid (rows of bools), optionally ignoring the item at `exclude`.
func _occupancy(gw: int, gh: int, exclude: int) -> Array:
	var grid: Array = []
	for y in gh:
		var row: Array = []
		for x in gw:
			row.append(false)
		grid.append(row)
	for i in inventory.size():
		if i == exclude:
			continue
		var it: Dictionary = inventory[i]
		for dy in int(it.get("h", 1)):
			for dx in int(it.get("w", 1)):
				var gx: int = int(it.get("gx", 0)) + dx
				var gy: int = int(it.get("gy", 0)) + dy
				if gx >= 0 and gx < gw and gy >= 0 and gy < gh:
					grid[gy][gx] = true
	return grid

func _fits(gx: int, gy: int, w: int, h: int, grid: Array, gw: int, gh: int) -> bool:
	if gx < 0 or gy < 0 or gx + w > gw or gy + h > gh:
		return false
	for dy in h:
		for dx in w:
			if grid[gy + dy][gx + dx]:
				return false
	return true

## First free (gx, gy) for a w x h item, or [-1, -1].
func _find_free(w: int, h: int) -> Array:
	var grid := _occupancy(backpack_w, backpack_h, -1)
	for gy in backpack_h:
		for gx in backpack_w:
			if _fits(gx, gy, w, h, grid, backpack_w, backpack_h):
				return [gx, gy]
	return [-1, -1]

func inv_can_fit(item: Dictionary) -> bool:
	return _find_free(int(item.get("w", 1)), int(item.get("h", 1)))[0] >= 0

## Add an item, auto-placing it in the first free spot. False if it doesn't fit.
func inv_add(item: Dictionary) -> bool:
	if not is_multiplayer_authority() or item.is_empty():
		return false
	var spot := _find_free(int(item.get("w", 1)), int(item.get("h", 1)))
	if spot[0] < 0:
		return false
	var it: Dictionary = item.duplicate()
	it["gx"] = spot[0]
	it["gy"] = spot[1]
	inventory.append(it)
	inventory_changed.emit()
	return true

## Move the item at `index` to grid cell (gx, gy). False if it doesn't fit there.
func inv_move(index: int, gx: int, gy: int) -> bool:
	if not is_multiplayer_authority() or index < 0 or index >= inventory.size():
		return false
	var it: Dictionary = inventory[index]
	var grid := _occupancy(backpack_w, backpack_h, index)
	if not _fits(gx, gy, int(it.get("w", 1)), int(it.get("h", 1)), grid, backpack_w, backpack_h):
		return false
	it["gx"] = gx
	it["gy"] = gy
	inventory_changed.emit()
	return true

## Rotate a backpack item 90° by swapping its footprint. Square items are a no-op. Keeps
## the item where it is when the rotated shape fits there, otherwise nudges the top-left
## back inside the grid; fails (leaves it untouched) only if it can't fit rotated at all.
func inv_rotate(index: int) -> bool:
	if not is_multiplayer_authority() or index < 0 or index >= inventory.size():
		return false
	var it: Dictionary = inventory[index]
	var w := int(it.get("w", 1))
	var h := int(it.get("h", 1))
	if w == h:
		return false
	var grid := _occupancy(backpack_w, backpack_h, index)
	# Swapped footprint is h x w. Try in place, then pull it back in if it overhangs.
	var nx := int(it.get("gx", 0))
	var ny := int(it.get("gy", 0))
	nx = clampi(nx, 0, maxi(0, backpack_w - h))
	ny = clampi(ny, 0, maxi(0, backpack_h - w))
	if not _fits(nx, ny, h, w, grid, backpack_w, backpack_h):
		return false
	it["w"] = h
	it["h"] = w
	it["gx"] = nx
	it["gy"] = ny
	it["rot"] = not bool(it.get("rot", false))
	inventory_changed.emit()
	return true

## Try to re-pack every item (except `exclude`) into a fresh gw x gh grid. On
## success, updates their placements and returns true; otherwise leaves them be.
func _repack(gw: int, gh: int, exclude: int) -> bool:
	var grid: Array = []
	for y in gh:
		var row: Array = []
		for x in gw:
			row.append(false)
		grid.append(row)
	var placements: Array = []
	for i in inventory.size():
		if i == exclude:
			continue
		var it: Dictionary = inventory[i]
		var w := int(it.get("w", 1))
		var h := int(it.get("h", 1))
		var placed := false
		for gy in gh:
			for gx in gw:
				if _fits(gx, gy, w, h, grid, gw, gh):
					for dy in h:
						for dx in w:
							grid[gy + dy][gx + dx] = true
					placements.append([it, gx, gy])
					placed = true
					break
			if placed:
				break
		if not placed:
			return false
	for pl in placements:
		pl[0]["gx"] = pl[1]
		pl[0]["gy"] = pl[2]
	return true

# ---------------------------------------------------------------- equipment

## Damage cut for a body zone from worn armor (head/torso/legs -> head/body/pants).
## Armor is a pool of extra HP on the hit zone: it soaks damage until its durability
## (cur_hp) runs out, then the piece breaks and is removed. Returns the damage that
## spills past the armor onto the player's health.
func _absorb_armor(zone: String, amount: float) -> float:
	var slot: String = {"head": "head", "torso": "body", "legs": "pants"}.get(zone, "")
	if slot == "":
		return amount
	var piece: Dictionary = equip.get(slot, {})
	if String(piece.get("kind", "")) != "armor":
		return amount
	var hp := float(piece.get("cur_hp", 0.0))
	if hp <= 0.0:
		return amount
	var absorbed := minf(amount, hp)
	hp -= absorbed
	piece["cur_hp"] = hp
	if hp <= 0.0:
		equip[slot] = {}   # armor destroyed — gone for good
		if is_multiplayer_authority():
			Audio.play_3d("res://assets/audio/impact.ogg", global_position, -2.0, 0.1)
			equipment_changed.emit()
	return amount - absorbed

## Equip the backpack item at `index` into its natural slot (double-click / drag).
## `gun_slot` (0-2) targets a specific gun slot when dragging a weapon onto it;
## -1 means "first free slot" (double-click / drop onto the panel generally).
func equip_item(index: int, gun_slot: int = -1) -> void:
	if not is_multiplayer_authority() or index < 0 or index >= inventory.size():
		return
	var item: Dictionary = inventory[index]
	match String(item.get("kind", "")):
		"weapon":
			var wid := String(item.get("weapon_id", ""))
			if weapons.loadout.has(wid):
				return  # already equipped in some slot
			if gun_slot >= 0 and gun_slot < weapons.SLOTS:
				# Drop into the chosen slot, swapping any existing gun back to the pack.
				var prev_id := String(weapons.loadout[gun_slot])
				inventory.remove_at(index)  # free its cells so the swapped-out gun fits
				if prev_id != "" and not inv_add(ItemDB.make_weapon(prev_id)):
					inventory.insert(index, item)  # no room to swap — revert
					inventory_changed.emit()
					return
				weapons.set_slot(gun_slot, wid)
			else:
				if not weapons.loadout.has(""):
					return  # all gun slots full
				weapons.give_weapon(wid)
				inventory.remove_at(index)
			inventory_changed.emit()
			equipment_changed.emit()
		"armor":
			_equip_slot(String(item.get("slot", "body")), index)
		"grenade":
			_equip_slot("extra", index)
		"gadget":
			_equip_slot("gadget", index)
		_:
			inv_use(index)  # not equippable -> consume it

func _equip_slot(slot: String, index: int) -> void:
	var item: Dictionary = inventory[index]
	inventory.remove_at(index)  # frees its cells so the swapped-out piece can fit
	var old: Dictionary = equip.get(slot, {})
	if not old.is_empty() and not inv_add(old):
		inventory.insert(index, item)  # no room to swap — revert
		inventory_changed.emit()
		return
	equip[slot] = item
	if slot == "extra":
		_refresh_grenades()   # total = equipped + backpack
	elif slot == "gadget":
		_reset_gadget()       # new gadget starts off
	inventory_changed.emit()
	equipment_changed.emit()

## Reorder/swap the weapons between two gun slots (drag between gun slots in the UI).
func move_gun(from_slot: int, to_slot: int) -> void:
	if not is_multiplayer_authority():
		return
	weapons.move_slot(from_slot, to_slot)
	equipment_changed.emit()

## Move an equipped item back into the backpack.
func unequip(slot: String) -> void:
	if not is_multiplayer_authority():
		return
	if slot.begins_with("gun"):
		var i := int(slot.substr(3)) - 1
		if not weapons.slot_filled(i):
			return
		var wid := String(weapons.loadout[i])
		if inv_add(ItemDB.make_weapon(wid)):
			weapons.remove_slot(i)
			equipment_changed.emit()
		return
	var item: Dictionary = equip.get(slot, {})
	if item.is_empty():
		return
	if inv_add(item):
		equip[slot] = {}
		if slot == "extra":
			_refresh_grenades()   # still counts the ones now back in the backpack
		elif slot == "gadget":
			_reset_gadget()       # turn it off when removed
		equipment_changed.emit()

## Use/equip the item at `index`, applying its effect; consumed items are removed.
func inv_use(index: int) -> void:
	if not is_multiplayer_authority() or index < 0 or index >= inventory.size():
		return
	var item: Dictionary = inventory[index]
	var consumed := true
	match String(item.get("kind", "")):
		"food":
			eat(float(item.get("amount", 40)))
		"water":
			drink(float(item.get("amount", 50)))
		"health":
			if sync_health >= MAX_HEALTH:
				return  # don't waste a medkit at full health
			heal(int(item.get("amount", 40)))
		"ammo":
			weapons.refill()
		"grenade":
			_equip_slot("extra", index)   # using a grenade equips it to the Extra slot
			return
		"gadget":
			_equip_slot("gadget", index)  # using a gadget equips it to the Gadget slot
			return
		"weapon":
			weapons.give_weapon(String(item.get("weapon_id", "")))
		"backpack":
			var gw := int(item.get("grid_w", backpack_w))
			var gh := int(item.get("grid_h", backpack_h))
			if not _repack(gw, gh, index):
				return  # the new pack can't hold what you're already carrying
			backpack_w = gw
			backpack_h = gh
		_:
			consumed = false
	if consumed:
		inventory.remove_at(index)
		inventory_changed.emit()

## Drop the item at `index` into the world as a pickup (replicated for co-op).
func inv_drop(index: int) -> void:
	if not is_multiplayer_authority() or index < 0 or index >= inventory.size():
		return
	var item: Dictionary = inventory[index]
	inventory.remove_at(index)
	inventory_changed.emit()
	var pos := global_position + (-global_transform.basis.z) * 1.6 + Vector3.UP * 0.4
	_spawn_dropped_item.rpc(combatant_id, _drop_counter, item, pos)
	_drop_counter += 1

## Adventure death: scatter a few carried items as loot where you fell, then wipe
## the backpack and gear back to a fresh start (you respawn with just a pistol).
func _drop_loot_on_death() -> void:
	if not is_multiplayer_authority():
		return
	var loot: Array = inventory.duplicate()
	for slot in ["head", "body", "pants", "extra", "gadget"]:
		var it: Dictionary = equip.get(slot, {})
		if not it.is_empty():
			loot.append(it)
	for i in mini(loot.size(), 5):
		var pos := global_position + Vector3(randf_range(-1.5, 1.5), 0.5, randf_range(-1.5, 1.5))
		_spawn_dropped_item.rpc(combatant_id, _drop_counter, loot[i], pos)
		_drop_counter += 1
	# Drop your whole coin purse as a recoverable cash pile where you fell.
	if coins > 0:
		var cpos := global_position + Vector3(randf_range(-1.0, 1.0), 0.5, randf_range(-1.0, 1.0))
		_spawn_dropped_cash.rpc(combatant_id, _drop_counter, coins, cpos)
		_drop_counter += 1
		coins = 0
	inventory.clear()
	equip = {"head": {}, "body": {}, "pants": {}, "extra": {}, "gadget": {}}
	weapons.set_loadout(["pistol"])
	grenades = 0
	inventory_changed.emit()
	equipment_changed.emit()
	grenades_changed.emit(0)

@rpc("any_peer", "call_local", "reliable")
func _spawn_dropped_cash(owner_id: int, idx: int, amount: int, pos: Vector3) -> void:
	var p := PICKUP_SCENE.instantiate()
	p.name = "Drop_%d_%d" % [owner_id, idx]
	p.kind = "money"
	p.amount = amount
	p.respawn_time = 999999.0
	get_tree().current_scene.add_child(p)
	p.global_position = pos

@rpc("any_peer", "call_local", "reliable")
func _spawn_dropped_item(owner_id: int, idx: int, item: Dictionary, pos: Vector3) -> void:
	var p := PICKUP_SCENE.instantiate()
	p.name = "Drop_%d_%d" % [owner_id, idx]   # deterministic across peers for RPC paths
	p.kind = String(item.get("kind", "misc"))
	p.weapon_id = String(item.get("weapon_id", "shotgun"))
	p.item_data = item
	p.respawn_time = 999999.0
	get_tree().current_scene.add_child(p)
	p.global_position = pos

# ---------------------------------------------------------------- vehicles

func _nearest_vehicle() -> Node:
	var best: Node = null
	var bd := ENTER_RANGE
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v.is_occupied():
			continue
		var d: float = global_position.distance_to(v.global_position)
		if d < bd:
			bd = d
			best = v
	return best

## Adventure: nearest collectable pickup within reach (collected on E).
func _nearest_pickup() -> Node:
	var best: Node = null
	var bd := 2.6
	for p in get_tree().get_nodes_in_group("pickup"):
		if not p.get("available"):
			continue
		var d: float = global_position.distance_to(p.global_position)
		if d < bd:
			bd = d
			best = p
	return best

## Adventure: nearest living NPC within talk range that isn't hostile to us.
func _nearest_talkable_npc() -> Node:
	var best: Node = null
	var bd := NPC_TALK_RANGE
	for b in get_tree().get_nodes_in_group("bot"):
		if b.get("dead"):
			continue
		if Game.adventure_hostile("player", String(b.get("faction"))):
			continue  # can't chat with someone trying to kill you
		var d: float = global_position.distance_to(b.global_position)
		if d < bd:
			bd = d
			best = b
	return best

func _talk_to(npc: Node) -> void:
	var info := {
		"name": String(npc.get("display_name")),
		"role": String(npc.get("role")),
		"faction": String(npc.get("faction")),
		"persona": String(npc.get("persona")),
		"greeting": _npc_greeting(npc),
	}
	# Generated faction backstory (from the story), shown as lore in the dialog.
	var facs = Game.story.get("factions", {})
	if typeof(facs) == TYPE_DICTIONARY and facs.has(info["faction"]):
		info["lore"] = String(facs[info["faction"]])
	# Quartermasters of factions that tolerate you will trade.
	if String(npc.get("role")) == "Quartermaster" \
			and String(Game.adventure_stance.get(String(npc.get("faction")), "neutral")) != "hostile":
		info["can_trade"] = true
	# Hireable: a non-hostile, not-yet-recruited NPC, when you're carrying money.
	_talking_npc = npc
	if _can_hire(npc):
		info["can_hire"] = true
		info["hire_cost"] = HIRE_COST
	var qm := get_tree().get_first_node_in_group("quest_manager")
	if qm != null:
		var offer: Dictionary = qm.offer_for(int(npc.get("combatant_id")))
		if not offer.is_empty():
			info["quest_id"] = int(offer["id"])
			var diff_label: String = qm.difficulty_label(offer) if qm.has_method("difficulty_label") else ""
			info["quest_title"] = "[%s]  %s" % [diff_label, String(offer["title"])] if diff_label != "" else String(offer["title"])
			info["quest_desc"] = "%s  (+%d pts)" % [String(offer["desc"]), int(offer["points"])]
	talk_to.emit(info)

const HIRE_COST := 25
var _talking_npc: Node = null

func _can_hire(npc: Node) -> bool:
	if not Game.is_adventure() or npc == null or npc.get("recruited"):
		return false
	if String(Game.adventure_stance.get(String(npc.get("faction")), "neutral")) == "hostile":
		return false
	return coins >= HIRE_COST   # paid from the coin wallet

## Pay the talked-to NPC (coins) to recruit them as a follower.
func hire_npc() -> bool:
	if not is_multiplayer_authority() or _talking_npc == null or not _can_hire(_talking_npc):
		return false
	coins -= HIRE_COST
	if _talking_npc.has_method("recruit"):
		_talking_npc.recruit(self)
	return true

## Talk-menu negotiation with the NPC you're speaking to. Returns a short result line for
## the dialog. Heal / Give need a friendly stance; Follow is free when friendly; Wait /
## Regroup / Go there command your existing followers.
func npc_request(action: String, target_pos: Vector3 = Vector3.INF) -> String:
	if not is_multiplayer_authority() or _talking_npc == null or not is_instance_valid(_talking_npc):
		return ""
	var npc := _talking_npc
	var friendly := String(Game.adventure_stance.get(String(npc.get("faction")), "neutral")) == "friendly"
	var nm := String(npc.get("display_name"))
	match action:
		"follow":
			if bool(npc.get("recruited")):
				return "%s is already with you." % nm
			if not friendly:
				return "\"Earn our trust first.\"  (Trade or run a job — or Hire them.)"
			if npc.has_method("recruit"):
				npc.recruit(self)
			return "%s falls in behind you." % nm
		"wait":
			return "Your followers hold position." if _order_followers("wait") > 0 else "You have no followers."
		"regroup":
			return "Your followers regroup on you." if _order_followers("regroup") > 0 else "You have no followers."
		"goto":
			if target_pos == Vector3.INF:
				return ""
			return "Your followers move out." if _order_followers("goto", target_pos) > 0 else "You have no followers."
		"heal":
			if not friendly:
				return "\"I don't patch up strangers.\""
			if sync_health >= MAX_HEALTH:
				return "You're already at full health."
			heal(40)
			return "%s tends your wounds." % nm
		"give":
			if not friendly:
				return "\"Supplies are for our own.\""
			var gift: String = ["food", "water", "medkit", "ammo"][randi() % 4]
			if inv_add(ItemDB.make(gift)):
				return "%s hands you %s." % [nm, gift]
			return "Your pack is full — make room first."
	return ""

## Apply a follower order to every bot recruited to this player. Returns how many obeyed.
func _order_followers(order: String, pos: Vector3 = Vector3.INF) -> int:
	var n := 0
	for b in get_tree().get_nodes_in_group("bot"):
		if bool(b.get("recruited")) and b.get("follow_target") == self:
			if order == "wait" and b.has_method("set_hold"):
				b.set_hold(true)
			elif order == "regroup" and b.has_method("set_hold"):
				b.set_hold(false)
			elif order == "goto" and b.has_method("set_goto"):
				b.set_goto(pos)
			n += 1
	return n

func _npc_greeting(npc: Node) -> String:
	var fac := String(npc.get("faction"))
	var role := String(npc.get("role"))
	# Prefer the generated, on-theme greeting for this faction if we have one.
	var greetings = Game.story.get("greetings", {})
	if typeof(greetings) == TYPE_DICTIONARY and greetings.has(fac):
		return String(greetings[fac])
	var stance := String(Game.adventure_stance.get(fac, "neutral"))
	if stance == "friendly":
		if role == "Elder":
			return "Welcome, traveler. The %s could use a steady hand." % fac
		if role == "Quartermaster":
			return "Need supplies? Keep your wits about you out there."
		return "Good to see a friendly face in these wilds."
	return "We don't know you, stranger. Mind your step."

func _enter_vehicle(v: Node) -> void:
	if v == null:
		return
	driving = v
	near_vehicle = false
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	_cam_idle = 0.0
	v.enter(combatant_id, team)
	$CollisionShape3D.disabled = true
	weapons.set_hidden(true)
	_set_hitboxes_enabled(false)  # the car takes hits, not the driver

func _set_hitboxes_enabled(on: bool) -> void:
	if has_node("Hitboxes"):
		for a in $Hitboxes.get_children():
			if a is Area3D:
				a.collision_layer = 16 if on else 0

func _exit_vehicle() -> void:
	if driving:
		var side: Vector3 = driving.global_transform.basis.x * 3.0 + Vector3.UP * 0.8
		global_position = driving.global_position + side
		driving.exit()
	$CollisionShape3D.disabled = false
	weapons.set_hidden(false)
	_set_hitboxes_enabled(true)
	velocity = Vector3.ZERO
	sync_pos = global_position
	driving = null
	# Restore the first-person camera.
	camera.transform = Transform3D.IDENTITY
	_yaw = rotation.y
	_pitch = 0.0
	head.rotation.x = 0.0

func _fly_vehicle(delta: float) -> void:
	if driving.destroyed:
		_exit_vehicle()
		return
	var throttle := Input.get_axis("move_back", "move_forward")
	var yaw := Input.get_axis("move_right", "move_left")
	var vertical := (1.0 if Input.is_action_pressed("jump") else 0.0) \
		- (1.0 if Input.is_action_pressed("crouch") else 0.0)
	driving.set_fly(throttle, yaw, vertical)
	if Input.is_action_pressed("fire"):
		# Aim the gun where the camera (crosshair) points.
		var aim := camera.global_position - camera.global_transform.basis.z * 300.0
		driving.request_fire(aim)
	if Input.is_action_just_pressed("interact"):
		_exit_vehicle()
		return
	# Ride the seat.
	global_position = driving.seat_position()
	velocity = Vector3.ZERO
	var fwd: Vector3 = driving.forward()
	rotation.y = atan2(-fwd.x, -fwd.z)
	sync_pos = global_position
	sync_yaw = rotation.y
	# Over-the-shoulder aim camera: the mouse nudges the aim direction; after idle
	# it eases back to straight ahead. The heli sits off to the side so the
	# crosshair points at open space, not at the heli body.
	_cam_idle += delta
	if _cam_idle > 0.7:
		var ease := clampf(3.0 * delta, 0.0, 1.0)
		_cam_yaw = lerp_angle(_cam_yaw, 0.0, ease)
		_cam_pitch = lerpf(_cam_pitch, 0.0, ease)
	var aim_dir := fwd.rotated(Vector3.UP, _cam_yaw)
	var right_h := aim_dir.cross(Vector3.UP).normalized()
	aim_dir = aim_dir.rotated(right_h, _cam_pitch)
	var cam_pos: Vector3 = driving.global_position - aim_dir * 11.0 + Vector3.UP * 4.0 + right_h * 3.5
	camera.global_position = camera.global_position.lerp(cam_pos, clampf(8.0 * delta, 0.0, 1.0))
	camera.look_at(driving.global_position + aim_dir * 22.0, Vector3.UP)

func _leave_vehicle_if_driving() -> void:
	if driving and is_instance_valid(driving):
		driving.exit()
	driving = null
	camera.transform = Transform3D.IDENTITY

func _drive_vehicle(delta: float) -> void:
	if driving.destroyed:
		_exit_vehicle()
		return
	var throttle := Input.get_axis("move_back", "move_forward")  # W forward = +1
	# Chase cam looks along +Z (drive dir); from that view A steers left, D right.
	var steer := Input.get_axis("move_right", "move_left")       # A left = +1
	var handbrake := 5.0 if Input.is_action_pressed("jump") else 0.0
	driving.set_drive(throttle, steer, handbrake)
	if Input.is_action_just_pressed("reload"):
		driving.request_flip()
	# Body rides the seat (so others see the driver in the car), facing forward.
	global_position = driving.seat_position()
	velocity = Vector3.ZERO
	var fwd: Vector3 = driving.forward()
	rotation.y = atan2(fwd.x, fwd.z)
	sync_pos = global_position
	sync_yaw = rotation.y

	# Orbitable chase camera: mouse moves it; after idle it eases back to default.
	_cam_idle += delta
	if _cam_idle > 0.7:
		var back := clampf(3.0 * delta, 0.0, 1.0)
		_cam_yaw = lerp_angle(_cam_yaw, 0.0, back)
		_cam_pitch = lerpf(_cam_pitch, 0.0, back)
	var orbit := (-fwd).rotated(Vector3.UP, _cam_yaw)
	var right := orbit.cross(Vector3.UP).normalized()
	orbit = orbit.rotated(right, _cam_pitch)
	var cam_pos: Vector3 = driving.global_position + orbit * 7.0 + Vector3.UP * 3.2
	camera.global_position = camera.global_position.lerp(cam_pos, clampf(10.0 * delta, 0.0, 1.0))
	camera.look_at(driving.global_position + Vector3.UP * 1.2, Vector3.UP)
	if Input.is_action_just_pressed("interact"):
		_exit_vehicle()

## Can a grenade be thrown right now? Adventure needs one equipped in the Extra slot;
## other modes just need the per-life counter above zero.
func _can_throw_grenade() -> bool:
	return _grenade_equipped() if Game.is_adventure() else grenades > 0

func _throw_grenade() -> void:
	# The equipped grenade's type is what gets thrown (frag by default).
	var gtype := "frag"
	if Game.is_adventure():
		gtype = String(equip.get("extra", {}).get("gtype", "frag"))
		if not _consume_grenade():
			return
	else:
		grenades -= 1
		grenades_changed.emit(grenades)
	var fwd := -camera.global_transform.basis.z
	var pos := camera.global_position + fwd * 0.6
	var vel := fwd * 16.0 + Vector3.UP * 4.0 + Vector3(velocity.x, 0, velocity.z) * 0.5
	_spawn_grenade.rpc(pos, vel, gtype)

@rpc("any_peer", "call_local", "reliable")
func _spawn_grenade(pos: Vector3, vel: Vector3, gtype: String = "frag") -> void:
	var g := GRENADE_SCENE.instantiate()
	g.thrower_id = combatant_id
	g.thrower_team = team
	g.gtype = gtype
	g.authoritative = is_multiplayer_authority()
	get_tree().current_scene.add_child(g)
	g.global_position = pos
	g.linear_velocity = vel

# ---------------------------------------------------------------- damage / death

## Called by an attacker's hitscan on whatever it hit. `zone` is the body part hit
## (head/torso/legs) so the victim can apply its worn armor.
func hit(amount: float, attacker_id: int, zone: String = "") -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id, zone)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, attacker_id: int, zone: String = "") -> void:
	if dead or downed or fully_dead:
		return
	# Soften incoming fire from enemy bots (negative ids) so they don't shred you in two
	# shots — your own weapons and PvP are unaffected.
	if attacker_id < 0:
		amount = minf(amount * BOT_DAMAGE_SCALE, BOT_HIT_CAP)
	amount = _absorb_armor(zone, amount)   # worn armor soaks the zone's damage, then breaks
	if perks.has("tough"):
		amount *= 0.9
	sync_health = max(0.0, sync_health - amount)
	if is_multiplayer_authority():
		health_changed.emit(sync_health, MAX_HEALTH)
		if sync_health > 0.0:
			Audio.play_3d("res://assets/audio/hurt.ogg", global_position, -1.0, 0.05)
			_emit_damage_direction(attacker_id)
			add_camera_shake(clampf(amount / 50.0, 0.06, 0.45))   # hit flinch
	if sync_health <= 0.0:
		# In co-op you go down (revivable) instead of dying outright.
		if Game.is_coop():
			_go_down(attacker_id)
		else:
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

# ---------------------------------------------------------------- co-op downed

func _go_down(attacker_id: int) -> void:
	_leave_vehicle_if_driving()
	downed = true
	_bleed = BLEED_TIME
	_revive_prog = 0.0
	_awaiting_life = false
	velocity = Vector3.ZERO
	weapons.set_hidden(true)
	body_model.scale.y = 0.5  # slumped
	Audio.play_3d("res://assets/audio/hurt.ogg", global_position, 2.0, 0.0)
	# Count the down as a death for scoring + let the host check for a team wipe.
	_report_death.rpc_id(1, attacker_id, combatant_id)
	downed_changed.emit(true, 1.0, 0.0, false)

func _update_downed(delta: float) -> void:
	if _awaiting_life:
		return
	_bleed -= delta
	if _alive_teammate_near():
		_revive_prog += delta
	else:
		_revive_prog = maxf(0.0, _revive_prog - delta * 0.5)
	downed_changed.emit(true, clampf(_bleed / BLEED_TIME, 0, 1), clampf(_revive_prog / REVIVE_TIME, 0, 1), false)
	if _revive_prog >= REVIVE_TIME:
		_revive()
	elif _bleed <= 0.0:
		_bleed_out()

func _alive_teammate_near() -> bool:
	for p in get_tree().get_nodes_in_group("player"):
		if p == self:
			continue
		if p.get("team") != team:
			continue
		if p.get("downed") or p.get("dead") or p.get("fully_dead"):
			continue
		if global_position.distance_to(p.global_position) <= REVIVE_RANGE:
			return true
	return false

func _revive() -> void:
	downed = false
	sync_health = REVIVE_HEALTH
	weapons.set_hidden(false)
	body_model.scale.y = 1.0
	health_changed.emit(sync_health, MAX_HEALTH)
	downed_changed.emit(false, 0, 0, false)

func _bleed_out() -> void:
	# Ask the host for a shared life; it replies via apply_life_result().
	_awaiting_life = true
	var world := get_tree().get_first_node_in_group("world")
	if world:
		world.request_life.rpc_id(1, combatant_id)

## Called (on this player's authority) by the world once the host decides.
func apply_life_result(granted: bool) -> void:
	_awaiting_life = false
	if granted:
		downed = false
		weapons.set_hidden(false)
		body_model.scale.y = 1.0
		_request_respawn()
	else:
		downed = false
		fully_dead = true
		downed_changed.emit(false, 0, 0, true)  # spectator

func _die(attacker_id: int) -> void:
	if dead:
		return
	_leave_vehicle_if_driving()
	dead = true
	died.emit(attacker_id)
	# Report to host for scoring.
	_report_death.rpc_id(1, attacker_id, combatant_id)
	Audio.play_3d("res://assets/audio/death_body.wav", global_position, 0.0, 0.07)
	body_model.visible = false
	weapons.set_hidden(true)
	name_label.visible = false
	$CollisionShape3D.disabled = true
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		if Game.is_battle_royale():
			# No respawns: you're eliminated for good and become a spectator.
			fully_dead = true
			downed_changed.emit(false, 0, 0, true)
			var world := get_tree().get_first_node_in_group("world")
			if world and world.has_method("check_last_standing"):
				world.check_last_standing()
		else:
			if Game.is_adventure():
				_drop_loot_on_death()
			_respawn_timer = 3.0
			set_process(true)

@rpc("any_peer", "call_local", "reliable")
func _report_death(attacker_id: int, victim_id: int) -> void:
	if Net.is_host():
		Game.add_kill(attacker_id, victim_id)
		var world := get_tree().get_first_node_in_group("world")
		if world and world.has_method("check_coop_wipe"):
			world.check_coop_wipe()
		if world and world.has_method("check_last_standing"):
			world.check_last_standing()

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
	oxygen = MAX_OXYGEN
	_air_speed = 0.0
	oxygen_changed.emit(oxygen, MAX_OXYGEN)
	# Respawn restores survival needs to full, too.
	hunger = MAX_NEED
	thirst = MAX_NEED
	_need_dmg_accum = 0.0
	hunger_changed.emit(hunger, MAX_NEED)
	thirst_changed.emit(thirst, MAX_NEED)
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
		if Game.is_adventure():
			_refresh_grenades()   # only what you still carry — no free respawn grenades
		else:
			grenades = MAX_GRENADES
			grenades_changed.emit(grenades)
		health_changed.emit(sync_health, MAX_HEALTH)
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
