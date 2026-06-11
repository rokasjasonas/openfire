extends Node3D
## A lingering area left by a grenade: drifting smoke (cover), a burning patch
## (damage over time), or a void well (pulls combatants inward). Every peer spawns one
## for the visuals; only the authoritative copy applies gameplay effects.

var mode: String = "smoke"        # smoke | fire | void
var authoritative: bool = false
var thrower_id: int = 0
var thrower_team: int = -999
var life: float = 7.0

const FIRE_RADIUS := 4.2
const FIRE_DPS := 22.0
const VOID_RADIUS := 9.0
const VOID_PULL := 14.0

var _dmg_t: float = 0.0

func _ready() -> void:
	_build_visual()

func _process(delta: float) -> void:
	life -= delta
	if life <= 0.0:
		queue_free()
		return
	if not authoritative:
		return
	match mode:
		"fire": _tick_fire(delta)
		"void": _tick_void(delta)

func _enemies():
	var out: Array = []
	for c in get_tree().get_nodes_in_group("combatant"):
		if is_instance_valid(c) and not c.get("dead") and c.get("team") != thrower_team:
			out.append(c)
	return out

func _tick_fire(delta: float) -> void:
	_dmg_t += delta
	if _dmg_t < 0.4:
		return
	_dmg_t = 0.0
	for c in _enemies():
		if c.global_position.distance_to(global_position) < FIRE_RADIUS and c.has_method("hit"):
			c.hit(FIRE_DPS * 0.4, thrower_id)

func _tick_void(delta: float) -> void:
	for c in _enemies():
		var to: Vector3 = global_position - c.global_position
		var d: float = to.length()
		if d < VOID_RADIUS and d > 0.3:
			var pull: Vector3 = to.normalized() * VOID_PULL * (1.0 - d / VOID_RADIUS)
			if "velocity" in c:
				c.velocity += pull * delta * 12.0
	# A short, sharp implosion of damage at the very end.
	if life < 0.25:
		for c in _enemies():
			if c.global_position.distance_to(global_position) < 3.0 and c.has_method("hit"):
				c.hit(60.0, thrower_id)

func _build_visual() -> void:
	match mode:
		"smoke":
			add_child(_particles(Color(0.7, 0.7, 0.72, 0.0), Color(0.6, 0.6, 0.62, 0.55), Color(0.5, 0.5, 0.52, 0.0),
				120, 6.0, 2.2, Vector3(0, 0.5, 0), 3.5, false))
		"fire":
			add_child(_particles(Color(1.0, 0.9, 0.4, 0.9), Color(1.0, 0.45, 0.1, 0.85), Color(0.3, 0.1, 0.04, 0.0),
				90, 1.0, 1.1, Vector3(0, 2.0, 0), FIRE_RADIUS, true))
			var l := OmniLight3D.new()
			l.omni_range = FIRE_RADIUS * 2.0
			l.light_color = Color(1.0, 0.5, 0.2)
			l.light_energy = 2.5
			add_child(l)
		"void":
			add_child(_particles(Color(0.6, 0.2, 0.9, 0.0), Color(0.35, 0.1, 0.6, 0.8), Color(0.05, 0.0, 0.1, 0.9),
				120, 1.2, 2.6, Vector3.ZERO, VOID_RADIUS, true))

func _particles(c0: Color, c1: Color, c2: Color, amount: int, life_s: float, size: float, gravity: Vector3, radius: float, additive: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life_s
	p.visibility_aabb = AABB(Vector3.ONE * -radius * 2.0, Vector3.ONE * radius * 4.0)
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = radius
	mat.gravity = gravity
	mat.initial_velocity_min = 0.2
	mat.initial_velocity_max = 1.4
	mat.scale_min = size * 0.6
	mat.scale_max = size
	var g := Gradient.new()
	g.colors = PackedColorArray([c0, c1, c2])
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	mat.color_ramp = gt
	p.process_material = mat
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	quad.material = m
	p.draw_pass_1 = quad
	return p
