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
		"sight": 45.0, "attack": 26.0, "spread_far": 10.0, "spread_near": 1.8, "behavior": "balanced",
		"model": "res://assets/models/characters/character-m.glb", "color": Color(1, 0.5, 0.45), "scale": 1.0},
	"rusher": {"name": "Rusher", "health": 55.0, "speed": 8.5, "cooldown": 0.5, "damage": 7.0,
		"sight": 42.0, "attack": 16.0, "spread_far": 12.0, "spread_near": 3.2, "behavior": "rush",
		"model": "res://assets/models/characters/character-c.glb", "color": Color(1, 0.8, 0.3), "scale": 0.9},
	"sniper": {"name": "Sniper", "health": 70.0, "speed": 4.0, "cooldown": 2.1, "damage": 55.0,
		"sight": 95.0, "attack": 85.0, "spread_far": 2.6, "spread_near": 0.4, "behavior": "kite",
		"model": "res://assets/models/characters/character-h.glb", "color": Color(0.5, 0.8, 1.0), "scale": 1.0},
	"heavy": {"name": "Heavy", "health": 210.0, "speed": 3.6, "cooldown": 0.7, "damage": 14.0,
		"sight": 42.0, "attack": 22.0, "spread_far": 9.0, "spread_near": 2.2, "behavior": "balanced",
		"model": "res://assets/models/characters/character-p.glb", "color": Color(1, 0.3, 0.3), "scale": 1.18},
	"grenadier": {"name": "Grenadier", "health": 80.0, "speed": 5.0, "cooldown": 1.1, "damage": 8.0,
		"sight": 50.0, "attack": 34.0, "spread_far": 13.0, "spread_near": 2.6, "behavior": "grenadier",
		"model": "res://assets/models/characters/character-d.glb", "color": Color(0.9, 0.55, 0.2), "scale": 1.05},
	"boss": {"name": "WARLORD", "health": 1500.0, "speed": 4.2, "cooldown": 0.5, "damage": 22.0,
		"sight": 72.0, "attack": 45.0, "spread_far": 5.0, "spread_near": 1.2, "behavior": "balanced",
		"model": "res://assets/models/characters/character-p.glb", "color": Color(1, 0.15, 0.55), "scale": 1.9},
}
# Spawn weighting (soldiers common, others rarer).
const SPAWN_WEIGHTS := {"soldier": 5, "rusher": 3, "sniper": 2, "heavy": 1, "grenadier": 1}

var behavior: String = "balanced"   # set from the profile in _apply_profile

@export var skill: float = 1.0          # set by world; scales accuracy/cadence/damage
@export var respawns: bool = false      # deathmatch bots respawn; coop enemies don't

var etype: String = "soldier"
var combatant_id: int = -1
var team: int = 1
var display_name: String = "Bot"
var faction: String = ""        # Adventure faction (drives hostility); "" elsewhere
var role: String = ""           # Adventure role (Leader / Guard / Raider / ...)
var persona: String = ""        # Adventure: short LLM-written persona trait
var _active: bool = true         # Adventure: false when far from all players (frozen)

# Swimming: bots float in water and can swim straight to a visible target across it.
const SWIM_CHASE_RANGE := 45.0   # max distance to wade into water after a target
var _water_y: float = -1.0e20
var in_water: bool = false
var _water_ahead: bool = false
var _quest_marker: Label3D = null   # Adventure: floats over kill/hunt targets

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
var _stun: float = 0.0           # flashbang daze: can't act until it runs out

## Daze this bot (flashbang) for `secs`, briefly halting its AI.
func stun(secs: float) -> void:
	_stun = maxf(_stun, secs)
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
	if is_multiplayer_authority():
		call_deferred("_snap_to_navmesh")  # don't start stuck in water / off-mesh

## Move a freshly-spawned bot onto the nearest walkable navmesh point, so NPCs that
## landed in a lake or on a steep slope (no swimming) don't stand there glitching.
func _snap_to_navmesh() -> void:
	var region := get_tree().get_first_node_in_group("nav_region")
	if region == null or not (region is NavigationRegion3D):
		return
	var nmap: RID = region.get_navigation_map()
	if not NavigationServer3D.map_is_active(nmap):
		return
	var p := NavigationServer3D.map_get_closest_point(nmap, global_position)
	var d := Vector2(p.x - global_position.x, p.z - global_position.z).length()
	if d > 0.5 and d < 40.0:
		global_position = Vector3(p.x, p.y + 1.0, p.z)
		sync_pos = global_position
		_spawn_pos = global_position

func _apply_profile() -> void:
	var p: Dictionary = PROFILES.get(etype, PROFILES["soldier"])
	max_health = p["health"]
	move_speed = p["speed"]
	fire_cooldown = p["cooldown"]
	shoot_damage = p["damage"]
	behavior = String(p.get("behavior", "balanced"))
	# Sight scales with skill so Easy bots spot you much later than Hard ones.
	sight_range = float(p["sight"]) * clampf(0.45 + skill * 0.4, 0.5, 1.0)
	attack_range = p["attack"]
	spread_far = p["spread_far"]
	spread_near = p["spread_near"]
	if is_multiplayer_authority():
		sync_health = max_health
	name_label.text = "%s %d" % [p["name"], absi(combatant_id) % 1000]
	name_label.modulate = Game.team_color(team) if Game.is_team_mode() else p["color"]
	# Hide bot/NPC name tags in Battle Royale (stealthy FFA) and in Adventure.
	name_label.visible = not Game.is_battle_royale() and not Game.is_adventure()
	body_model.scale = Vector3.ONE * float(p["scale"])
	# Scale the hitboxes with the visible model so headshots line up on big archetypes.
	if has_node("Hitboxes"):
		$Hitboxes.scale = Vector3.ONE * float(p["scale"])
	# The bot's forward is -Z (look_at + the muzzle), but the character mesh faces
	# +Z, so flip the model 180° or it appears to walk backwards.
	body_model.rotation.y = PI
	# Swap the body model to the archetype's character.
	for c in body_model.get_children():
		c.queue_free()
	if ResourceLoader.exists(p["model"]):
		var packed: PackedScene = load(p["model"])
		body_model.add_child(packed.instantiate())
	# The character meshes are taller than the original 1.8 m design, which left the
	# head hitbox down at chest height. Set up animation + re-fit the hitboxes to the
	# real model once the mesh transforms are valid, so shots land where they look.
	call_deferred("_setup_model")

# Hitbox layout the scene was authored for (a 1.8 m humanoid). Scaled to the real
# model height at runtime so head/torso/legs line up with whatever model is used.
const HB_DESIGN_H := 1.8
const HB_HEAD_Y := 1.6
const HB_TORSO_Y := 1.15
const HB_LEGS_Y := 0.5
const HB_HEAD_R := 0.34

# The shared Kenney character models stand ~2.7 m tall at scale 1.0. Fit against this
# constant rather than the live mesh AABB, which the auto-playing idle clip perturbs.
const MODEL_LOCAL_H := 2.7

func _fit_hitboxes() -> void:
	if not has_node("Hitboxes") or body_model == null:
		return
	var f := MODEL_LOCAL_H / HB_DESIGN_H   # ~1.5, deterministic (pose-independent)
	_set_hb_y($Hitboxes/Head, HB_HEAD_Y * f)
	_set_hb_y($Hitboxes/Torso, HB_TORSO_Y * f)
	_set_hb_y($Hitboxes/Legs, HB_LEGS_Y * f)
	# Resize the shapes proportionally (duplicate first so we don't mutate the shared
	# resources that every bot points at).
	var head: CollisionShape3D = $Hitboxes/Head/Shape
	head.shape = head.shape.duplicate()
	head.shape.radius = HB_HEAD_R * f
	for part in ["Torso", "Legs"]:
		var cs: CollisionShape3D = get_node("Hitboxes/%s/Shape" % part)
		cs.shape = cs.shape.duplicate()
		cs.shape.size *= f

func _set_hb_y(area: Node, y: float) -> void:
	var s := area.get_node("Shape")
	s.position.y = y

## Visible model height in the bot's local frame (divides out the archetype scale,
## which the Hitboxes node already applies separately).
func _body_local_height() -> float:
	var sc: float = maxf(0.001, body_model.scale.y)
	var top := -1.0e20
	var bot := 1.0e20
	for m in _model_meshes(body_model):
		var a: AABB = m.get_aabb()
		var gt: Transform3D = m.global_transform
		for i in 8:
			var corner := a.position + Vector3(
				a.size.x if (i & 1) else 0.0,
				a.size.y if (i & 2) else 0.0,
				a.size.z if (i & 4) else 0.0)
			var wy := (gt * corner).y - global_position.y
			top = maxf(top, wy)
			bot = minf(bot, wy)
	if top <= bot:
		return 0.0
	return (top - bot) / sc

func _model_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_model_meshes(c))
	return out

func _process(delta: float) -> void:
	# Remote copy: smoothly interpolate toward the replicated transform.
	var t := clampf(15.0 * delta, 0.0, 1.0)
	if global_position.distance_to(sync_pos) > 5.0:
		global_position = sync_pos
	else:
		global_position = global_position.lerp(sync_pos, t)
	rotation.y = lerp_angle(rotation.y, sync_yaw, t)
	_update_anim(delta)

# ---------------------------------------------------------------- animation
# The character models ship a full clip set (idle/walk/sprint/die/holding-*-shoot).
# Driven on every peer from locally-visible state (position delta + dead + a
# replicated shoot pulse), so it needs no extra syncing.
var _anim: AnimationPlayer = null
var _anim_pos := Vector3.ZERO
var _anim_speed: float = 0.0
var _shoot_anim_t: float = 0.0
var _died_anim: bool = false

## Grab the model's animation player, then measure the hitboxes against a FIXED pose
## (idle frame 0) — the glb auto-plays a clip, so measuring the live pose would vary.
func _setup_model() -> void:
	_anim = _find_anim(body_model)
	_anim_pos = global_position
	if _anim != null:
		for clip in ["walk", "sprint", "idle"]:
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		if _anim.has_animation("idle"):
			_anim.play("idle")
			_anim.seek(0.0, true)   # apply the neutral pose now, so the fit is stable
	_fit_hitboxes()

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null

func _update_anim(delta: float) -> void:
	if _anim == null:
		return
	if dead:
		if not _died_anim:
			_died_anim = true
			if _anim.has_animation("die"):
				_anim.get_animation("die").loop_mode = Animation.LOOP_NONE
				_anim.play("die", 0.1)
		return
	_died_anim = false
	var d := global_position - _anim_pos
	d.y = 0.0
	_anim_speed = lerpf(_anim_speed, d.length() / maxf(delta, 0.001), 0.25)
	_anim_pos = global_position
	_shoot_anim_t = maxf(0.0, _shoot_anim_t - delta)
	var want := "idle"
	if _shoot_anim_t > 0.0 and _anim.has_animation("holding-both-shoot"):
		want = "holding-both-shoot"
	elif _anim_speed > 6.5 and _anim.has_animation("sprint"):
		want = "sprint"
	elif _anim_speed > 0.6 and _anim.has_animation("walk"):
		want = "walk"
	if _anim.current_animation != want and _anim.has_animation(want):
		_anim.play(want, 0.18)

func configure(id: int, t: int, sk: float, respawn_on_death: bool, label: String, type_id: String = "soldier", faction_id: String = "") -> void:
	combatant_id = id
	team = t
	skill = sk
	respawns = respawn_on_death
	display_name = label
	etype = type_id if PROFILES.has(type_id) else "soldier"
	faction = faction_id
	if is_node_ready():
		_apply_profile()

## Adventure: the world freezes bots far from every player (no AI / physics).
func set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	if is_multiplayer_authority():
		set_physics_process(on)

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

	# Gravity, buoyancy when in water, or climbing when the nav path goes straight up
	# (a ladder navmesh-link step — bots scale it instead of walking into the wall).
	if _water_y < -1.0e19:
		_update_water_level()
	in_water = global_position.y < _water_y
	if in_water:
		var depth := _water_y - global_position.y
		velocity.y = lerp(velocity.y, clampf(depth - 1.3, -1.0, 1.0) * 4.0, 4.0 * delta)
	elif _ladder_step():
		velocity.y = 4.0   # climb the vertical link
	elif not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 24.0) * delta

	# Flashbang stun: stand dazed (no thinking/shooting) until it wears off.
	if _stun > 0.0:
		_stun -= delta
		velocity.x = move_toward(velocity.x, 0.0, 30.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 30.0 * delta)
		move_and_slide()
		return

	_think_cd -= delta
	if _think_cd <= 0.0:
		_think_cd = 0.25
		_acquire_target()
		_maybe_enter_vehicle()
		_water_ahead = _water_between_me_and(_target)
		_update_quest_marker()

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
		if c.is_in_group("animal"):
			continue   # bots don't hunt wildlife
		if c.get("dead") or c.get("downed") or c.get("fully_dead"):
			continue
		if Game.is_adventure():
			if not Game.adventure_hostile(faction, String(c.get("faction"))):
				continue
		elif c.get("team") == team:
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
	# Easy bots are slow on the trigger; Hard bots snap to it.
	return clampf(0.5 / skill, 0.12, 0.95)

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
	# Swim straight at the target when already in water, or wade in if water lies
	# between us and a target within range (the navmesh stops at the shore).
	if in_water or _water_ahead:
		_steer_direct(_target.global_position, move_speed)
	else:
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
	# Movement depends on archetype behaviour.
	var to_target := _target.global_position - global_position
	to_target.y = 0
	var dist := to_target.length()
	if in_water or _water_ahead:
		_steer_direct(_target.global_position, move_speed * 0.9)
	else:
		match behavior:
			"rush":
				# Charge straight in until almost on top of the target; barely strafes.
				if dist > 4.0:
					_move_toward(_target.global_position, move_speed)
				else:
					velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
					velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
			"kite":
				# Snipers keep their distance: back off if the target gets close, else hold.
				if dist < attack_range * 0.45:
					_move_toward(global_position - to_target.normalized() * 8.0, move_speed)
				else:
					_attack_strafe(delta, 0.4)
			"grenadier":
				# Hold mid-range and lob grenades; close in only if very far.
				if dist > attack_range * 0.85:
					_move_toward(_target.global_position, move_speed * 0.8)
				else:
					_attack_strafe(delta, 0.5)
				_grenade_cd -= delta
				if _grenade_cd <= 0.0 and dist < attack_range and dist > 6.0 and _can_see(_target):
					_grenade_cd = randf_range(3.5, 6.0)
					_throw_bot_grenade(_target.global_position)
			_:
				# Balanced: close to preferred range, then strafe to be harder to hit.
				if dist > attack_range * 0.7:
					_move_toward(_target.global_position, move_speed * 0.85)
				else:
					_attack_strafe(delta, 0.55)
	_face(_target.global_position)
	# Reaction delay before the first shot makes them feel human, not instant.
	if _shoot_cd <= 0.0 and _reaction <= 0.0 and _can_see(_target):
		_shoot_at(_target)

func _attack_strafe(delta: float, factor: float) -> void:
	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		_strafe_timer = randf_range(0.7, 1.6)
		_strafe_sign = -_strafe_sign
	var sv := global_transform.basis.x * _strafe_sign * move_speed * factor
	velocity.x = sv.x
	velocity.z = sv.z

var _grenade_cd: float = 3.0

## Grenadier: lob a frag grenade on an arc toward a target point.
func _throw_bot_grenade(target: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	var from := muzzle.global_position
	var flat := target - from
	flat.y = 0.0
	var vel := flat.normalized() * 12.0 + Vector3.UP * 6.0
	_spawn_bot_grenade.rpc(from, vel)

@rpc("authority", "call_local", "reliable")
func _spawn_bot_grenade(pos: Vector3, vel: Vector3) -> void:
	var g = load("res://scenes/grenade.tscn").instantiate()
	g.thrower_id = combatant_id
	g.thrower_team = team
	g.gtype = "frag"
	g.authoritative = is_multiplayer_authority()
	get_tree().current_scene.add_child(g)
	g.global_position = pos
	g.linear_velocity = vel

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

## Steer straight at a world point (no navmesh) — used while swimming.
func _steer_direct(world_pos: Vector3, speed: float) -> void:
	var dir := world_pos - global_position
	dir.y = 0.0
	if dir.length() < 0.1:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * 0.016)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * 0.016)
		return
	dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face(global_position + dir)

func _update_water_level() -> void:
	var y := -1.0e20
	for w in get_tree().get_nodes_in_group("water"):
		if w is Node3D:
			y = maxf(y, (w as Node3D).global_position.y)
	_water_y = y

## True if water lies between this bot and `target` (within swim range), so it
## should wade in and swim across rather than path around on the navmesh.
func _water_between_me_and(target: Node) -> bool:
	if target == null or _water_y < -1.0e19:
		return false
	var tp: Vector3 = target.global_position
	if global_position.distance_to(tp) > SWIM_CHASE_RANGE:
		return false
	var mid := (global_position + tp) * 0.5
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(mid + Vector3.UP * 80.0, mid - Vector3.UP * 200.0)
	q.collision_mask = 1  # world/terrain
	q.exclude = [get_rid()]
	var res := space.intersect_ray(q)
	if res.is_empty():
		return false
	return float(res.position.y) < _water_y - 0.5

## Adventure: float a marker over this NPC — a red ▼ if it's a kill target (active
## hunt / clear-camp / assassinate), or a gold "!" if it has a quest to offer — so the
## player can find who to fight and who to talk to.
func _update_quest_marker() -> void:
	if not Net.is_host():
		return   # clients get markers via the world's _sync_quest_markers RPC
	var text := ""
	var col := Color.WHITE
	if Game.is_adventure() and not dead:
		var qm = get_tree().get_first_node_in_group("quest_manager")
		if qm != null:
			for q in qm.quests:
				if q.get("state", "") != "active":
					continue
				var t := String(q.get("type", ""))
				if ((t == "hunt" or t == "clear_camp") and String(q.get("faction", "")) == faction) \
						or (t == "assassinate" and int(q.get("target_id", 0)) == combatant_id):
					text = "▼"
					col = Color(1.0, 0.3, 0.25)   # kill target
					break
			if text == "" and qm.has_method("offer_for") and not qm.offer_for(combatant_id).is_empty():
				text = "!"
				col = Color(1.0, 0.85, 0.2)        # quest giver
	# Only show the marker when a player is close enough to read it (avoid clutter).
	if text != "" and not _player_within(50.0):
		text = ""
	_set_marker(text, col)

func _player_within(dist: float) -> bool:
	for p in get_tree().get_nodes_in_group("player"):
		if p.get("dead") or p.get("fully_dead"):
			continue
		if global_position.distance_to(p.global_position) <= dist:
			return true
	return false

func _set_marker(text: String, col: Color) -> void:
	if text == "":
		if _quest_marker != null:
			_quest_marker.visible = false
		return
	if _quest_marker == null:
		_quest_marker = Label3D.new()
		_quest_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_quest_marker.no_depth_test = true     # visible through cover so it's findable
		_quest_marker.fixed_size = true
		_quest_marker.pixel_size = 0.0012
		_quest_marker.font_size = 64
		_quest_marker.outline_size = 12
		_quest_marker.outline_modulate = Color(0, 0, 0, 0.85)
		add_child(_quest_marker)
	if _quest_marker != null:
		# Sit clearly above the head, accounting for bigger archetypes (heavy/boss).
		_quest_marker.position = Vector3(0, 2.7 + maxf(0.0, body_model.scale.x - 1.0) * 1.8, 0)
	_quest_marker.text = text
	_quest_marker.modulate = col
	_quest_marker.visible = true

func _clear_marker() -> void:
	if _quest_marker != null:
		_quest_marker.visible = false

## Client-side marker control, driven by the host's quest state broadcast.
func set_marker_kind(kind: String) -> void:
	match kind:
		"kill":
			_set_marker("▼", Color(1.0, 0.3, 0.25))
		"giver":
			_set_marker("!", Color(1.0, 0.85, 0.2))
		_:
			_clear_marker()

## True while the next nav-path point sits well above us but horizontally close —
## i.e. we're at the bottom of a ladder navmesh-link and should climb, not walk.
func _ladder_step() -> bool:
	if nav == null or nav.is_navigation_finished():
		return false
	var next := nav.get_next_path_position()
	var dy := next.y - global_position.y
	var horiz := Vector2(next.x - global_position.x, next.z - global_position.z).length()
	return dy > 1.2 and horiz < 2.5

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
	# Easy (skill 0.6) fires at the full wide spread; only higher skill tightens it.
	var acc := clampf((skill - 0.6) / 0.8, 0.0, 1.0)
	var spread := deg_to_rad(lerpf(spread_far, spread_near, acc))
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
				var zone: String = col.part if col is Hitbox else ""
				victim.hit(shoot_damage * clampf(skill, 0.6, 1.6) * mult, combatant_id, zone)
	_fire_fx.rpc(endpoint)

@rpc("any_peer", "call_local", "unreliable")
func _fire_fx(hit_point: Vector3) -> void:
	_shoot_anim_t = 0.35   # play the shooting pose on every peer
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

func hit(amount: float, attacker_id: int, _zone: String = "") -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, attacker_id: int) -> void:
	if dead:
		return
	# Adventure: being shot by a player provokes this NPC's faction (neutral -> hostile).
	if Game.is_adventure() and is_multiplayer_authority() and attacker_id > 0:
		Game.adventure_provoke(faction)
	sync_health = max(0.0, sync_health - amount)
	if sync_health <= 0.0:
		_die(attacker_id)

func _die(attacker_id: int) -> void:
	if dead:
		return
	dead = true
	name_label.visible = false       # body stays for the death animation / corpse
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
	# Keep the body visible so the "die" animation plays and the corpse lingers; only
	# the name tag + collision come off. _update_anim plays "die" once when dead.
	name_label.visible = not is_dead
	$CollisionShape3D.disabled = is_dead
	if is_dead:
		_died_anim = false   # let _update_anim trigger the death clip
		_clear_marker()      # no kill/quest marker over a corpse
		# A body-drop thud, not the grenade explosion sound.
		Audio.play_3d("res://assets/audio/death_body.wav", global_position, -1.0, 0.08)
	else:
		body_model.visible = true
		if _anim != null and _anim.has_animation("idle"):
			_anim.play("idle")

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
