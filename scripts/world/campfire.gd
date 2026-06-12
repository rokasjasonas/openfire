extends Node3D
## A deployed campfire: logs + flame particles + a warm flickering light. Marks a
## "campfire" group so nearby players can cook. Cosmetic/ambient; no authority needed.

func _ready() -> void:
	add_to_group("campfire")
	_build()

var _light: OmniLight3D = null
var _flicker: float = 0.0

func _build() -> void:
	var logmat := StandardMaterial3D.new()
	logmat.albedo_color = Color(0.3, 0.2, 0.13)
	for i in 4:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.7, 0.12, 0.12)
		mi.mesh = box
		mi.material_override = logmat
		add_child(mi)
		mi.position = Vector3(0, 0.06, 0)
		mi.rotation.y = TAU * float(i) / 4.0
	# Flame particles.
	var p := GPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.7
	p.visibility_aabb = AABB(Vector3(-2, 0, -2), Vector3(4, 4, 4))
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.18
	mat.gravity = Vector3(0, 2.5, 0)
	mat.initial_velocity_min = 0.4
	mat.initial_velocity_max = 1.2
	mat.scale_min = 0.25
	mat.scale_max = 0.5
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 0.9, 0.4, 0.9), Color(1, 0.45, 0.12, 0.8), Color(0.3, 0.1, 0.05, 0.0)])
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	mat.color_ramp = gt
	p.process_material = mat
	var quad := QuadMesh.new()
	quad.size = Vector2(0.4, 0.4)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.vertex_color_use_as_albedo = true
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	quad.material = qm
	p.draw_pass_1 = quad
	add_child(p)
	p.position.y = 0.25
	_light = OmniLight3D.new()
	_light.omni_range = 10.0
	_light.light_color = Color(1.0, 0.6, 0.3)
	_light.light_energy = 3.0
	add_child(_light)
	_light.position.y = 0.6

func _process(delta: float) -> void:
	if _light != null:
		_flicker += delta * 12.0
		_light.light_energy = 2.6 + sin(_flicker) * 0.4 + sin(_flicker * 2.3) * 0.2
