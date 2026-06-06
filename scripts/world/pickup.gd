extends Area3D
## A floating pickup. The first local player to touch it (on its owning peer)
## claims it, applies the effect, and broadcasts the pickup as taken; every peer
## hides it and re-enables it after respawn_time. Placed by maps via add_pickup().

@export var kind: String = "health"     # health | grenade | ammo | weapon
@export var amount: int = 25
@export var weapon_id: String = "shotgun"
@export var respawn_time: float = 18.0

var available: bool = true
var item_data: Dictionary = {}   # set when this pickup is a dropped survival item
var _visual: Node3D
var _t: float = 0.0

func _ready() -> void:
	add_to_group("pickup")
	collision_layer = 0
	collision_mask = 2  # detect players
	_build_collision()
	_build_visual()
	body_entered.connect(_on_body_entered)

func _build_collision() -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 1.8, 1.2)
	cs.shape = box
	cs.position.y = 0.7
	add_child(cs)

func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	var model_path := ""
	if kind == "weapon" and WeaponDB.has_weapon(weapon_id):
		model_path = WeaponDB.get_weapon(weapon_id)["model"]
	elif kind == "grenade":
		model_path = "res://assets/models/weapons/grenade-b.glb"
	if model_path != "" and ResourceLoader.exists(model_path):
		var m: Node3D = load(model_path).instantiate()
		m.scale = Vector3.ONE * 1.4
		_visual.add_child(m)
	else:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.5, 0.5, 0.5)
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _color()
		mat.emission_enabled = true
		mat.emission = _color()
		mat.emission_energy_multiplier = 0.6
		mi.material_override = mat
		_visual.add_child(mi)
	# A soft glow column so pickups read from a distance.
	var glow := OmniLight3D.new()
	glow.light_color = _color()
	glow.light_energy = 0.8
	glow.omni_range = 3.0
	glow.position.y = 0.7
	_visual.add_child(glow)

func _color() -> Color:
	return ItemDB.color_for(kind)

func _process(delta: float) -> void:
	if not available or _visual == null:
		return
	_t += delta
	_visual.rotation.y += delta * 1.6
	_visual.position.y = 0.7 + sin(_t * 2.0) * 0.12

func _on_body_entered(body: Node) -> void:
	if not available or not body.is_in_group("player"):
		return
	if not body.is_multiplayer_authority() or body.get("dead"):
		return
	# Survival: everything goes into the backpack instead of applying instantly, and
	# collected pickups are gone for good (no respawn).
	if Game.is_survival():
		var item: Dictionary = item_data if not item_data.is_empty() else ItemDB.from_pickup(kind, amount, weapon_id)
		if body.has_method("inv_add") and body.inv_add(item):
			Audio.play_3d("res://assets/audio/reload.ogg", global_position, 0.0, 0.05)
			_take.rpc()
		return
	# Skip if it would be wasted, so you don't burn a respawn for nothing.
	if kind == "health" and body.sync_health >= body.MAX_HEALTH:
		return
	if kind == "grenade" and body.grenades >= body.MAX_GRENADES:
		return
	_apply(body)
	Audio.play_3d("res://assets/audio/reload.ogg", global_position, 0.0, 0.05)
	_set_available.rpc(false)

## Survival: a collected/used pickup is removed for good (no respawn).
@rpc("any_peer", "call_local", "reliable")
func _take() -> void:
	available = false
	visible = false
	monitoring = false

func _apply(body: Node) -> void:
	match kind:
		"health":
			body.heal(amount)
		"grenade":
			body.add_grenades(1)
		"ammo":
			body.weapons.refill()
		"weapon":
			body.weapons.give_weapon(weapon_id)

@rpc("any_peer", "call_local", "reliable")
func _set_available(v: bool) -> void:
	available = v
	visible = v
	monitoring = v
	if not v:
		await get_tree().create_timer(respawn_time).timeout
		available = true
		visible = true
		monitoring = true
