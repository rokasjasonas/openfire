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
	# Also damage vehicles in range.
	for v in get_tree().get_nodes_in_group("vehicle"):
		if not is_instance_valid(v) or v.get("destroyed"):
			continue
		var vd := pos.distance_to(v.global_position)
		if vd < RADIUS and v.has_method("hit"):
			v.hit(MAX_DAMAGE * (1.0 - vd / RADIUS), thrower_id)

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
	# Fireball: a fast, bright orange burst that rises and fades.
	_burst(scene, pos + Vector3.UP * 0.3, {
		"count": 28, "life": 0.55, "vmin": 4.0, "vmax": 11.0, "gravity": Vector3(0, 3.0, 0),
		"size": 0.9, "grow": 1.6, "additive": true,
		"colors": [Color(1.0, 0.95, 0.6, 1.0), Color(1.0, 0.5, 0.15, 0.9), Color(0.4, 0.12, 0.05, 0.0)],
	})
	# Smoke: slower, grey, drifts upward and lingers after the flash.
	_burst(scene, pos + Vector3.UP * 0.4, {
		"count": 22, "life": 2.2, "vmin": 0.8, "vmax": 3.2, "gravity": Vector3(0, 1.1, 0),
		"size": 1.1, "grow": 2.6, "additive": false,
		"colors": [Color(0.32, 0.32, 0.32, 0.0), Color(0.28, 0.28, 0.28, 0.6), Color(0.18, 0.18, 0.18, 0.0)],
	})

## Build a one-shot GPUParticles3D burst from a spec dict, parent it, and free it
## once it has finished. Purely cosmetic, so it runs on every peer.
func _burst(scene: Node, at: Vector3, spec: Dictionary) -> void:
	var p := GPUParticles3D.new()
	p.amount = int(spec["count"])
	p.lifetime = float(spec["life"])
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.4
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 180.0
	mat.gravity = spec["gravity"]
	mat.initial_velocity_min = float(spec["vmin"])
	mat.initial_velocity_max = float(spec["vmax"])
	mat.damping_min = 1.0
	mat.damping_max = 3.0
	mat.scale_min = float(spec["size"]) * 0.6
	mat.scale_max = float(spec["size"])
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.4))
	grow.add_point(Vector2(1.0, float(spec["grow"])))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow
	mat.scale_curve = grow_tex
	mat.color_ramp = _ramp(spec["colors"])
	p.process_material = mat
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color.WHITE
	if bool(spec["additive"]):
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	quad.material = m
	p.draw_pass_1 = quad
	scene.add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(float(spec["life"]) + 0.4).timeout.connect(p.queue_free)

## A GradientTexture1D over the given colors, for a particle color ramp (fade in/out).
func _ramp(colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.colors = PackedColorArray(colors)
	var offs := PackedFloat32Array()
	for i in colors.size():
		offs.append(float(i) / float(maxi(1, colors.size() - 1)))
	g.offsets = offs
	var tex := GradientTexture1D.new()
	tex.gradient = g
	return tex
