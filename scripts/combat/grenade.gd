extends RigidBody3D
## Thrown frag grenade. Every peer simulates a copy for visuals; only the
## thrower's copy (authoritative) computes radius damage on detonation.

const RADIUS := 6.0
const MAX_DAMAGE := 120.0
const FUSE := 2.2
const LOS_MASK := 1  # world blocks the blast

var thrower_id: int = 0
var thrower_team: int = -999
var authoritative: bool = false

var _fuse: float = FUSE
var _done: bool = false

func _physics_process(delta: float) -> void:
	if _done:
		return
	_fuse -= delta
	if _fuse <= 0.0:
		_explode()

func _explode() -> void:
	_done = true
	var pos := global_position
	_spawn_fx(pos)
	if authoritative:
		_apply_damage(pos)
	queue_free()

func _apply_damage(pos: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	for c in get_tree().get_nodes_in_group("combatant"):
		if not is_instance_valid(c) or c.get("dead"):
			continue
		if c.get("team") == thrower_team:
			continue  # no friendly fire / self damage
		var cpos: Vector3 = c.global_position + Vector3.UP
		var dist := pos.distance_to(cpos)
		if dist > RADIUS:
			continue
		# Walls block the blast.
		var q := PhysicsRayQueryParameters3D.create(pos, cpos)
		q.collision_mask = LOS_MASK
		if not space.intersect_ray(q).is_empty():
			continue
		var dmg := MAX_DAMAGE * (1.0 - dist / RADIUS)
		if c.has_method("hit"):
			c.hit(dmg, thrower_id)

func _spawn_fx(pos: Vector3) -> void:
	Audio.play_3d("res://assets/audio/death.ogg", pos, 4.0, 0.05)
	var scene := get_tree().current_scene
	if scene == null:
		return
	var fx: Node3D = load("res://scenes/fx/impact.tscn").instantiate()
	scene.add_child(fx)
	fx.global_position = pos
	fx.scale = Vector3.ONE * 4.0
	var light := OmniLight3D.new()
	light.omni_range = RADIUS * 1.5
	light.light_energy = 10.0
	light.light_color = Color(1.0, 0.65, 0.3)
	scene.add_child(light)
	light.global_position = pos + Vector3.UP * 0.5
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.4)
	tw.tween_callback(light.queue_free)
