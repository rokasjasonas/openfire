extends Node3D
## Drives the player's weapons: model display, hitscan firing, ammo, reload,
## switching, aim-zoom and recoil. Lives under Head/Camera3D.
## Firing/hit detection runs on the local shooter; muzzle/tracer FX are broadcast.

const IMPACT_SCENE := preload("res://scenes/fx/impact.tscn")
# Ray mask: world(1) | hitbox(16). Body-part hitbox areas carry damage multipliers.
const HIT_MASK := 1 | 16

var player: CharacterBody3D
var camera: Camera3D
var is_local: bool = false

const SLOTS := 3                     # three gun slots (gun1/gun2/gun3 in the UI)

# Fixed-size loadout: always SLOTS entries, "" marks an empty slot. This lets a gun
# sit in slot 2 while slots 1/3 stay empty (slots no longer pack toward index 0).
var loadout: Array = ["", "", ""]
var ammo: Dictionary = {}            # id -> { "mag": int, "reserve": int }
var current_index: int = 0

var _cooldown: float = 0.0
var _reloading: bool = false
var _reload_left: float = 0.0
var _trigger: bool = false
var _fired_this_press: bool = false
var _aiming: bool = false
var _base_fov: float = 75.0
var _model: Node3D = null
var _recoil: float = 0.0

# Viewmodel motion (bob/sway) state.
var _vm_time: float = 0.0
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0
var _sway: Vector3 = Vector3.ZERO

@onready var holder: Node3D = $Holder
@onready var muzzle: Marker3D = $Holder/Muzzle
@onready var flash: OmniLight3D = $Holder/Muzzle/Flash

func setup(p: CharacterBody3D, cam: Camera3D) -> void:
	player = p
	camera = cam
	_base_fov = cam.fov
	flash.visible = false

func set_local(v: bool) -> void:
	is_local = v
	# Push the viewmodel slightly closer / scaled for the local player only.
	holder.visible = true

func set_hidden(v: bool) -> void:
	holder.visible = not v

func set_loadout(ids: Array) -> void:
	loadout = ["", "", ""]
	for i in mini(ids.size(), SLOTS):
		loadout[i] = String(ids[i])
	ammo.clear()
	for id in loadout:
		if String(id) == "":
			continue
		var w: Dictionary = WeaponDB.get_weapon(id)
		ammo[id] = {"mag": int(w["mag_size"]), "reserve": int(w["reserve"])}
	current_index = maxi(_first_filled(), 0)
	_equip(current_index)

## True if gun slot `i` holds a weapon (not empty).
func slot_filled(i: int) -> bool:
	return i >= 0 and i < loadout.size() and String(loadout[i]) != ""

## Index of the first occupied gun slot, or -1 if all are empty (unarmed).
func _first_filled() -> int:
	for i in loadout.size():
		if String(loadout[i]) != "":
			return i
	return -1

func _has_weapon() -> bool:
	return _first_filled() != -1

func refill() -> void:
	for id in loadout:
		if String(id) == "":
			continue
		var w: Dictionary = WeaponDB.get_weapon(id)
		ammo[id] = {"mag": int(w["mag_size"]), "reserve": int(w["reserve"])}
	emit_state()

## Pickup: grant a weapon into the first empty slot (replace the current one if all
## three are full), with full ammo.
func give_weapon(id: String) -> void:
	if not WeaponDB.has_weapon(id):
		return
	var w: Dictionary = WeaponDB.get_weapon(id)
	var full := {"mag": int(w["mag_size"]), "reserve": int(w["reserve"])}
	if loadout.has(id):
		ammo[id] = full
		return
	var slot: int = loadout.find("")  # first empty slot
	if slot == -1:
		slot = current_index  # all full -> replace the current weapon
		ammo.erase(String(loadout[slot]))
	loadout[slot] = id
	ammo[id] = full
	_equip(slot)
	emit_state()

## Place weapon `id` into a specific gun slot `i`, swapping out whatever was there.
## Returns the id previously in that slot ("" if it was empty). Ignored if `id` is
## already equipped in another slot.
func set_slot(i: int, id: String) -> String:
	if i < 0 or i >= SLOTS or not WeaponDB.has_weapon(id) or loadout.has(id):
		return ""
	var prev := String(loadout[i])
	if prev != "":
		ammo.erase(prev)
	loadout[i] = id
	var w: Dictionary = WeaponDB.get_weapon(id)
	ammo[id] = {"mag": int(w["mag_size"]), "reserve": int(w["reserve"])}
	if not slot_filled(current_index):
		current_index = i
	_equip(current_index)
	emit_state()
	return prev

## Move/swap the weapon in gun slot `a` with slot `b` (drag between gun slots).
func move_slot(a: int, b: int) -> void:
	if a < 0 or a >= SLOTS or b < 0 or b >= SLOTS or a == b:
		return
	var tmp = loadout[a]
	loadout[a] = loadout[b]
	loadout[b] = tmp
	if current_index == a:
		current_index = b
	elif current_index == b:
		current_index = a
	_equip(current_index)
	emit_state()

## Remove the weapon in gun slot `i` (unequip). Leaves the slot empty.
func remove_slot(i: int) -> void:
	if not slot_filled(i):
		return
	var id = loadout[i]
	loadout[i] = ""
	ammo.erase(id)
	if not _has_weapon():
		if _model:
			_model.queue_free()
			_model = null
		current_index = 0
	elif current_index == i:
		_equip(_first_filled())
	emit_state()

func _current() -> Dictionary:
	if not slot_filled(current_index):
		return WeaponDB.WEAPONS[0]
	return WeaponDB.get_weapon(loadout[current_index])

func _equip(index: int) -> void:
	current_index = clampi(index, 0, SLOTS - 1)
	_reloading = false
	if _model:
		_model.queue_free()
		_model = null
	if not slot_filled(current_index):
		if is_local:
			emit_state()  # empty slot -> show "Unarmed", no model
		return
	var w := _current()
	var packed: PackedScene = load(w["model"])
	if packed:
		_model = packed.instantiate()
		holder.add_child(_model)
		# Position the viewmodel bottom-right of the view. The Kenney blasters are
		# modelled along +Z (barrel forward), so rotate 180° on Y to point the
		# muzzle away from the camera (which looks down -Z). Per-weapon offset because
		# the blaster models have differing origins (the SMG sat too far out).
		_model.position = w.get("vm_pos", Vector3(0.18, -0.18, -0.45))
		_model.rotation_degrees = Vector3(0, 180, 0)
		_model.scale = Vector3.ONE * float(w.get("vm_scale", 1.0))
	if is_local:
		emit_state()

## Remote players: keep the visible weapon matched to the replicated index.
func ensure_index(index: int) -> void:
	if index != current_index or (slot_filled(index) and _model == null):
		_equip(index)

func switch_to(index: int) -> void:
	if index < 0 or index >= SLOTS or index == current_index or not slot_filled(index):
		return  # ignore switches to an empty slot
	_equip(index)

func set_trigger(pressed: bool) -> void:
	if not pressed:
		_fired_this_press = false
	_trigger = pressed

func set_aiming(v: bool) -> void:
	_aiming = v

func reload() -> void:
	if not slot_filled(current_index):
		return
	var w := _current()
	var a: Dictionary = ammo[loadout[current_index]]
	if _reloading or a["mag"] >= int(w["mag_size"]) or a["reserve"] <= 0:
		return
	_reloading = true
	_reload_left = float(w["reload_time"])
	if player.get("perks") != null and (player.perks as Array).has("reload"):
		_reload_left *= 0.75   # Fast hands perk
	Audio.play_3d("res://assets/audio/reload.ogg", player.global_position, -3.0, 0.04)

func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta
	# Smoothly recover aim FOV + recoil kick.
	if camera and is_local:
		var w := _current()
		var target_fov: float = float(w["zoom_fov"]) if _aiming else _base_fov
		camera.fov = lerp(camera.fov, target_fov, 12.0 * delta)
	if _recoil > 0.0:
		_recoil = max(0.0, _recoil - delta * 6.0)
	if flash.visible:
		flash.visible = false

	_update_viewmodel(delta)

	if _reloading:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_finish_reload()
		return

	if not is_local or player == null or player.dead:
		return

	var w := _current()
	if _trigger and _cooldown <= 0.0:
		var can: bool = bool(w["automatic"]) or not _fired_this_press
		if can:
			_fire()

func _finish_reload() -> void:
	_reloading = false
	var w := _current()
	var a: Dictionary = ammo[loadout[current_index]]
	var need := int(w["mag_size"]) - int(a["mag"])
	var take := mini(need, int(a["reserve"]))
	a["mag"] += take
	a["reserve"] -= take
	emit_state()

func _fire() -> void:
	if not slot_filled(current_index):
		return  # unarmed (Survival start / empty slot) — nothing to fire
	var w := _current()
	var a: Dictionary = ammo[loadout[current_index]]
	if int(a["mag"]) <= 0:
		reload()
		_cooldown = 0.2
		return
	a["mag"] -= 1
	_fired_this_press = true
	_cooldown = 1.0 / float(w["fire_rate"])
	if is_local:
		player.shots_fired += 1

	var origin := camera.global_position
	var fwd := -camera.global_transform.basis.z
	var spread := deg_to_rad(float(w["aim_spread_deg"]) if _aiming else float(w["spread_deg"]))
	var space := player.get_world_3d().direct_space_state
	var furthest := origin + fwd * float(w["range"])
	var dmg_dealt := 0.0
	var last_hit := Vector3.ZERO
	var hit_combatant := false
	var was_headshot := false
	var base_dmg := float(w["damage"])
	# Exclude our own body so the ray never hits the shooter's own hitboxes.
	var exclude: Array = [player.get_rid()]
	exclude.append_array(player.hitbox_rids())

	for i in int(w["pellets"]):
		var dir := _apply_spread(fwd, spread)
		var to := origin + dir * float(w["range"])
		var q := PhysicsRayQueryParameters3D.create(origin, to)
		q.collision_mask = HIT_MASK
		q.collide_with_areas = true
		q.exclude = exclude
		var res := space.intersect_ray(q)
		var endpoint := to
		if res:
			endpoint = res.position
			var hit := _resolve_hit(res.collider)
			var victim = hit[0]
			var mult: float = hit[1]
			# Friendly fire is off: never damage a same-team combatant.
			if victim and victim != player and victim.get("team") == player.team:
				victim = null
			if victim and victim != player and victim.has_method("hit"):
				var dealt := base_dmg * mult
				var zone: String = res.collider.part if res.collider is Hitbox else ""
				victim.hit(dealt, player.combatant_id, zone)
				dmg_dealt += dealt
				last_hit = res.position
				hit_combatant = true
				if mult >= 2.0:
					was_headshot = true
			elif res.collider and res.collider.is_in_group("destructible") and not res.collider.destroyed and res.collider.has_method("hit"):
				res.collider.hit(base_dmg, player.combatant_id)
				dmg_dealt += base_dmg
				last_hit = res.position
				hit_combatant = true
				_spawn_impact.rpc(res.position, res.normal)  # sparks off the target
			elif res.collider and res.collider.is_in_group("vehicle") and res.collider.has_method("hit"):
				res.collider.hit(base_dmg, player.combatant_id)
				dmg_dealt += base_dmg
				last_hit = res.position
				hit_combatant = true
				_spawn_impact.rpc(res.position, res.normal)  # sparks off the car
			else:
				_spawn_impact.rpc(res.position, res.normal)
		furthest = endpoint
	# Visual feedback for everyone.
	_play_fire_fx.rpc(furthest)
	# Damage feedback for the shooter only.
	if hit_combatant and is_local:
		_show_damage_number(last_hit, dmg_dealt, was_headshot)
		player.dealt_damage.emit(dmg_dealt)
		player.shots_hit += 1  # any shot that connected with a target (for accuracy)
	# Local recoil kick.
	_recoil = 1.0
	if player.has_node("Head"):
		player.get_node("Head").rotation.x += deg_to_rad(0.6)
	emit_state()

## Animate the viewmodel holder: walk bob + look sway + recoil kickback.
func _update_viewmodel(delta: float) -> void:
	if holder == null or player == null:
		return
	_vm_time += delta

	# Walk bob — oscillate while moving on the ground.
	var horiz := Vector2(player.velocity.x, player.velocity.z).length()
	var move_amt := clampf(horiz / 9.0, 0.0, 1.0)
	var grounded: bool = player.is_on_floor() if player.has_method("is_on_floor") else true
	var bob := Vector3.ZERO
	if grounded and move_amt > 0.05:
		var f := 11.0
		bob.x = sin(_vm_time * f) * 0.012 * move_amt
		bob.y = -absf(sin(_vm_time * f)) * 0.012 * move_amt
	# Reduce bob/sway while aiming down sights.
	var settle := 0.35 if _aiming else 1.0

	# Look sway — the gun lags behind fast camera turns, then eases back.
	var yaw := player.rotation.y
	var pitch: float = player.head.rotation.x if player.has_node("Head") else 0.0
	var dyaw := wrapf(yaw - _last_yaw, -PI, PI)
	var dpitch := pitch - _last_pitch
	_last_yaw = yaw
	_last_pitch = pitch
	var sway_target := Vector3(
		clampf(dyaw * 1.6, -0.05, 0.05),
		clampf(-dpitch * 1.6, -0.05, 0.05),
		0.0)
	_sway = _sway.lerp(sway_target, clampf(10.0 * delta, 0.0, 1.0))

	# Recoil pulls the gun back toward the camera (+Z) and up slightly.
	var kick := Vector3(0, _recoil * 0.012, _recoil * 0.05)

	var target := (bob + _sway) * settle + kick
	holder.position = holder.position.lerp(target, clampf(14.0 * delta, 0.0, 1.0))
	# Subtle roll/pitch from sway for a livelier feel.
	var target_rot := Vector3(-_sway.y * 4.0, _sway.x * 4.0, _sway.x * 6.0) * settle
	holder.rotation = holder.rotation.lerp(target_rot, clampf(12.0 * delta, 0.0, 1.0))

## Resolve a raycast collider to [combatant, damage_multiplier].
func _resolve_hit(col) -> Array:
	if col == null:
		return [null, 1.0]
	if col is Hitbox:
		return [col.combatant(), col.multiplier]
	if col.is_in_group("combatant"):
		return [col, 1.0]  # fallback: flat damage
	return [null, 1.0]

## Spawn a floating damage number at the hit point (shooter's screen only).
func _show_damage_number(pos: Vector3, amount: float, headshot: bool = false) -> void:
	var lbl := Label3D.new()
	lbl.text = ("%d!" % int(round(amount))) if headshot else str(int(round(amount)))
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0011
	lbl.outline_size = 10
	lbl.outline_modulate = Color(0, 0, 0, 0.8)
	# Headshots are always red and large; otherwise colour/size scale with damage.
	if headshot:
		lbl.modulate = Color(1.0, 0.2, 0.15)
		lbl.font_size = 104
	elif amount >= 50.0:
		lbl.modulate = Color(1.0, 0.3, 0.2)
		lbl.font_size = 96
	elif amount >= 25.0:
		lbl.modulate = Color(1.0, 0.7, 0.2)
		lbl.font_size = 80
	else:
		lbl.modulate = Color(1.0, 1.0, 1.0)
		lbl.font_size = 64
	get_tree().current_scene.add_child(lbl)
	var start := pos + Vector3(randf_range(-0.2, 0.2), 0.4, randf_range(-0.2, 0.2))
	lbl.global_position = start
	var tw := lbl.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lbl, "global_position", start + Vector3(0, 1.0, 0), 0.7).set_ease(Tween.EASE_OUT)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.7).set_delay(0.25)
	tw.chain().tween_callback(lbl.queue_free)

func _apply_spread(fwd: Vector3, spread: float) -> Vector3:
	if spread <= 0.0:
		return fwd
	var basis := camera.global_transform.basis
	var ang := randf() * TAU
	var rad := randf() * spread
	var offset := (basis.x * cos(ang) + basis.y * sin(ang)) * tan(rad)
	return (fwd + offset).normalized()

@rpc("any_peer", "call_local", "unreliable")
func _play_fire_fx(hit_point: Vector3) -> void:
	flash.visible = true
	_make_tracer(muzzle.global_position, hit_point)
	Audio.play_3d(String(_current().get("sfx", "")), muzzle.global_position, -2.0, 0.08)

@rpc("any_peer", "call_local", "unreliable")
func _spawn_impact(pos: Vector3, normal: Vector3) -> void:
	var fx := IMPACT_SCENE.instantiate()
	get_tree().current_scene.add_child(fx)
	fx.global_position = pos
	if normal.length() > 0.01:
		fx.look_at(pos + normal, Vector3.UP)
	Audio.play_3d("res://assets/audio/impact.ogg", pos, -8.0, 0.12)
	_spawn_bullet_hole(pos, normal)

## A small fading scorch decal at the impact point. Capped + auto-removed.
func _spawn_bullet_hole(pos: Vector3, normal: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var holes := get_tree().get_nodes_in_group("bullet_hole")
	if holes.size() > 80:
		holes[0].queue_free()
	var mi := MeshInstance3D.new()
	mi.add_to_group("bullet_hole")
	var quad := QuadMesh.new()
	quad.size = Vector2(0.13, 0.13)
	mi.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.04, 0.04, 0.05, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	scene.add_child(mi)
	mi.global_position = pos + normal * 0.02
	if normal.length() > 0.01:
		var up := Vector3.UP if absf(normal.y) < 0.9 else Vector3.FORWARD
		mi.look_at(pos - normal, up)  # quad face (+Z) points back along the normal
	var tw := mi.create_tween()
	tw.tween_interval(8.0)
	tw.tween_property(mat, "albedo_color:a", 0.0, 2.0)
	tw.tween_callback(mi.queue_free)

func _make_tracer(from: Vector3, to: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	var dist := from.distance_to(to)
	box.size = Vector3(0.03, 0.03, dist)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.3)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	get_tree().current_scene.add_child(mesh)
	mesh.global_position = (from + to) * 0.5
	if dist > 0.05:
		mesh.look_at(to, Vector3.UP)
	var tw := mesh.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.08)
	tw.tween_callback(mesh.queue_free)

# ---------------------------------------------------------------- HUD signals

func emit_state() -> void:
	if not is_local or player == null:
		return
	var filled := slot_filled(current_index)
	var id = loadout[current_index] if filled else ""
	var w := _current()
	var a: Dictionary = ammo.get(id, {"mag": 0, "reserve": 0})
	player.ammo_changed.emit(int(a["mag"]), int(a["reserve"]))
	player.weapon_changed.emit("Unarmed" if not filled else String(w["name"]))
