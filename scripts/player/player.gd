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

# Co-op downed / revive
const BLEED_TIME := 15.0
const REVIVE_RANGE := 2.6
const REVIVE_TIME := 3.0
const REVIVE_HEALTH := 40.0

# Survival needs (only active in Survival mode). Hunger/thirst drain over time
# (faster while sprinting) and chip health once either hits zero.
const MAX_NEED := 100.0
const HUNGER_RATE := 0.45        # points/sec
const THIRST_RATE := 0.7         # points/sec (thirst drains a bit faster)
const NEED_SPRINT_MULT := 1.8
const NEED_DAMAGE := 2.0         # health/sec while starving or dehydrated

# combatant_id == peer id for players (always positive). Used for scoring.
var combatant_id: int = 1
var team: int = -1
var display_name: String = "Player"
var faction: String = "player"   # Survival faction (used for NPC hostility)

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

# Survival needs (authority-owned; HUD shows the local player's only).
var hunger: float = MAX_NEED
var thirst: float = MAX_NEED
var _need_dmg_accum: float = 0.0

# Survival backpack: a spatial grid (backpack_w x backpack_h). Items are non-stacking
# and occupy a w x h footprint at a placed (gx, gy); fixed orientation.
var backpack_w: int = ItemDB.DEFAULT_GRID_W
var backpack_h: int = ItemDB.DEFAULT_GRID_H
var inventory: Array = []
var _drop_counter: int = 0

# Equipment slots: armor (head/body/pants) + a throwable slot. Guns live in the
# weapon loadout (gun1/2/3 in the UI mirror weapons.loadout).
var equip: Dictionary = {"head": {}, "body": {}, "pants": {}, "extra": {}}

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
var near_npc: Node = null      # Survival: nearest talkable (non-hostile) NPC, or null
var _cam_yaw: float = 0.0      # drive-camera orbit (relative to car)
var _cam_pitch: float = 0.0
var _cam_idle: float = 0.0

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
	weapons.setup(self, camera)
	# Equip weapons on every peer (so remote players also show a gun and the
	# local player can actually fire). Runs before set_local/_emit_hud below.
	# In Survival you spawn unarmed — your starting gear goes into the backpack
	# instead (see _fill_survival_start), and you equip a gun from there.
	if Game.is_survival():
		weapons.set_loadout([])
		_fill_survival_start()
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
		return

	if dead:
		_respawn_timer -= delta
		return

	if fully_dead:
		return
	if downed:
		_update_downed(delta)
		return

	if Game.is_survival():
		_update_needs(delta)

	# Driving a vehicle redirects all movement input to the vehicle.
	if driving != null and is_instance_valid(driving):
		if driving.is_in_group("aircraft"):
			_fly_vehicle(delta)
		else:
			_drive_vehicle(delta)
		return
	near_vehicle = _nearest_vehicle() != null
	near_npc = _nearest_talkable_npc() if Game.is_survival() else null
	if Input.is_action_just_pressed("interact"):
		if near_vehicle:
			_enter_vehicle(_nearest_vehicle())
			return
		elif near_npc != null:
			_talk_to(near_npc)

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
		if Input.is_action_just_pressed("grenade") and grenades > 0:
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

# ---------------------------------------------------------------- survival needs

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

## Survival: spawn unarmed with the default guns + grenades stowed in the backpack.
func _fill_survival_start() -> void:
	if not is_multiplayer_authority():
		return
	for wid in WeaponDB.default_loadout():
		inv_add(ItemDB.make_weapon(wid))
	for i in MAX_GRENADES:
		inv_add(ItemDB.make("grenade"))
	grenades = 0
	grenades_changed.emit(grenades)

## Consumables (Survival #3) call these to restore the needs.
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

# ---------------------------------------------------------------- survival backpack

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
func armor_reduction(zone: String) -> float:
	var slot: String = {"head": "head", "torso": "body", "legs": "pants"}.get(zone, "")
	if slot == "":
		return 0.0
	return float((equip.get(slot, {}) as Dictionary).get("armor", 0.0))

## Equip the backpack item at `index` into its natural slot (double-click / drag).
func equip_item(index: int) -> void:
	if not is_multiplayer_authority() or index < 0 or index >= inventory.size():
		return
	var item: Dictionary = inventory[index]
	match String(item.get("kind", "")):
		"weapon":
			if weapons.loadout.size() >= 3 and not weapons.loadout.has(String(item.get("weapon_id", ""))):
				return  # all gun slots full
			weapons.give_weapon(String(item.get("weapon_id", "")))
			inventory.remove_at(index)
			inventory_changed.emit()
			equipment_changed.emit()
		"armor":
			_equip_slot(String(item.get("slot", "body")), index)
		"grenade":
			_equip_slot("extra", index)
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
		grenades = MAX_GRENADES
		grenades_changed.emit(grenades)
	inventory_changed.emit()
	equipment_changed.emit()

## Move an equipped item back into the backpack.
func unequip(slot: String) -> void:
	if not is_multiplayer_authority():
		return
	if slot.begins_with("gun"):
		var i := int(slot.substr(3)) - 1
		if i < 0 or i >= weapons.loadout.size():
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
			grenades = 0
			grenades_changed.emit(0)
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
			if grenades >= MAX_GRENADES:
				return
			add_grenades(int(item.get("amount", 1)))
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

## Survival: nearest living NPC within talk range that isn't hostile to us.
func _nearest_talkable_npc() -> Node:
	var best: Node = null
	var bd := NPC_TALK_RANGE
	for b in get_tree().get_nodes_in_group("bot"):
		if b.get("dead"):
			continue
		if Game.survival_hostile("player", String(b.get("faction"))):
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
	var qm := get_tree().get_first_node_in_group("quest_manager")
	if qm != null:
		var offer: Dictionary = qm.offer_for(int(npc.get("combatant_id")))
		if not offer.is_empty():
			info["quest_id"] = int(offer["id"])
			info["quest_title"] = String(offer["title"])
			info["quest_desc"] = "%s  (+%d pts)" % [String(offer["desc"]), int(offer["points"])]
	talk_to.emit(info)

func _npc_greeting(npc: Node) -> String:
	var fac := String(npc.get("faction"))
	var role := String(npc.get("role"))
	# Prefer the generated, on-theme greeting for this faction if we have one.
	var greetings = Game.story.get("greetings", {})
	if typeof(greetings) == TYPE_DICTIONARY and greetings.has(fac):
		return String(greetings[fac])
	var stance := String(Game.survival_stance.get(fac, "neutral"))
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

## Called by an attacker's hitscan on whatever it hit. `zone` is the body part hit
## (head/torso/legs) so the victim can apply its worn armor.
func hit(amount: float, attacker_id: int, zone: String = "") -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id, zone)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, attacker_id: int, zone: String = "") -> void:
	if dead or downed or fully_dead:
		return
	amount *= 1.0 - armor_reduction(zone)  # worn armor cuts this zone's damage
	sync_health = max(0.0, sync_health - amount)
	if is_multiplayer_authority():
		health_changed.emit(sync_health, MAX_HEALTH)
		if sync_health > 0.0:
			Audio.play_3d("res://assets/audio/hurt.ogg", global_position, -1.0, 0.05)
			_emit_damage_direction(attacker_id)
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
	Audio.play_3d("res://assets/audio/death.ogg", global_position, 0.0, 0.05)
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
