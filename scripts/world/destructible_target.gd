extends StaticBody3D
## A networked destructible objective (a glowing console/reactor) that players must
## shoot to pieces. Built procedurally — no scene file. Host-authoritative health,
## synced via RPC like the bots; when destroyed it explodes and the objective
## runner advances. Sits on the world collision layer so hitscan rounds strike it.

var combatant_id: int = 0
var max_health: float = 600.0
var sync_health: float = 600.0
var destroyed: bool = false
var team: int = 99  # neutral: not a combatant, anyone's fire damages it

var _mesh: MeshInstance3D
var _label: Label3D

func setup(id: int, hp: float) -> void:
	combatant_id = id
	max_health = hp
	sync_health = hp

func _ready() -> void:
	add_to_group("destructible")
	collision_layer = 1   # world — player/bot HIT_MASK includes layer 1
	collision_mask = 0
	_build_visual()

func _build_visual() -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.6, 2.6, 2.6)
	cs.shape = box
	cs.position = Vector3(0, 1.3, 0)
	add_child(cs)

	_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.6, 2.6, 2.6)
	_mesh.mesh = bm
	_mesh.position = Vector3(0, 1.3, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.18, 0.16)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.15, 0.1)
	mat.emission_energy_multiplier = 0.8
	_mesh.material_override = mat
	add_child(_mesh)

	_label = Label3D.new()
	_label.text = "TARGET"
	_label.position = Vector3(0, 3.2, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(1, 0.55, 0.4)
	_label.font_size = 56
	_label.outline_size = 8
	_label.no_depth_test = true
	add_child(_label)

func health_fraction() -> float:
	return clampf(sync_health / maxf(max_health, 1.0), 0.0, 1.0)

func hit(amount: float, attacker_id: int, _zone: String = "") -> void:
	receive_damage.rpc_id(get_multiplayer_authority(), amount, attacker_id)

@rpc("any_peer", "call_local", "reliable")
func receive_damage(amount: float, _attacker_id: int) -> void:
	if destroyed:
		return
	sync_health = maxf(0.0, sync_health - amount)
	_flash.rpc(health_fraction())
	if sync_health <= 0.0:
		_explode_net.rpc()

## Brief hit reaction + colour-shift toward white as it nears destruction.
@rpc("authority", "call_local", "unreliable")
func _flash(frac: float) -> void:
	if _mesh == null or destroyed:
		return
	var mat: StandardMaterial3D = _mesh.material_override
	mat.emission_energy_multiplier = lerpf(2.4, 0.8, frac)
	mat.albedo_color = Color(0.85, 0.18, 0.16).lerp(Color(1, 0.9, 0.4), 1.0 - frac)

@rpc("authority", "call_local", "reliable")
func _explode_net() -> void:
	if destroyed:
		return
	destroyed = true
	for c in get_children():
		if c is CollisionShape3D:
			c.set_deferred("disabled", true)
	if _mesh:
		_mesh.visible = false
	if _label:
		_label.visible = false
	_spawn_explosion()
	Audio.play_3d("res://assets/audio/impact.ogg", global_position, 4.0, 0.0)
	await get_tree().create_timer(2.5).timeout
	queue_free()

func _spawn_explosion() -> void:
	var p := CPUParticles3D.new()
	p.emitting = true
	p.one_shot = true
	p.amount = 48
	p.lifetime = 1.1
	p.explosiveness = 0.95
	p.direction = Vector3.UP
	p.spread = 90.0
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 14.0
	p.gravity = Vector3(0, -9.0, 0)
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.2
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.6, 0.15)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1)
	p.mesh = BoxMesh.new()
	p.mesh.material = mat
	p.position = Vector3(0, 1.3, 0)
	add_child(p)
