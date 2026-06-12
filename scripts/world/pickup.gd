extends Area3D
## A floating pickup. The first local player to touch it (on its owning peer)
## claims it, applies the effect, and broadcasts the pickup as taken; every peer
## hides it and re-enables it after respawn_time. Placed by maps via add_pickup().

@export var kind: String = "health"     # health | grenade | ammo | weapon
@export var amount: int = 25
@export var weapon_id: String = "shotgun"
@export var respawn_time: float = 18.0

var available: bool = true
var item_data: Dictionary = {}   # set when this pickup is a dropped adventure item
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
		_build_item_shape(_visual)
	# A soft glow column so pickups read from a distance.
	var glow := OmniLight3D.new()
	glow.light_color = _color()
	glow.light_energy = 0.8
	glow.omni_range = 3.0
	glow.position.y = 0.7
	_visual.add_child(glow)

func _color() -> Color:
	return ItemDB.color_for(kind)

func _mat(col: Color, emit: float = 0.45) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.7
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = emit
	return m

func _box(parent: Node3D, size: Vector3, pos: Vector3, col: Color, emit: float = 0.45) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(col, emit)
	mi.position = pos
	parent.add_child(mi)

func _cyl(parent: Node3D, r: float, h: float, pos: Vector3, col: Color, emit: float = 0.45) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	mi.mesh = cm
	mi.material_override = _mat(col, emit)
	mi.position = pos
	parent.add_child(mi)

## A small recognisable shape per item kind (instead of an identical box).
func _build_item_shape(parent: Node3D) -> void:
	match kind:
		"health":  # white medkit with a red cross
			_box(parent, Vector3(0.5, 0.34, 0.4), Vector3.ZERO, Color(0.95, 0.95, 0.97), 0.2)
			_box(parent, Vector3(0.32, 0.1, 0.02), Vector3(0, 0.04, 0.21), Color(0.85, 0.2, 0.2), 0.7)
			_box(parent, Vector3(0.1, 0.26, 0.02), Vector3(0, 0.04, 0.21), Color(0.85, 0.2, 0.2), 0.7)
		"water":   # blue bottle
			_cyl(parent, 0.16, 0.46, Vector3.ZERO, Color(0.3, 0.6, 1.0), 0.35)
			_cyl(parent, 0.07, 0.12, Vector3(0, 0.28, 0), Color(0.2, 0.45, 0.8), 0.35)
		"food":    # tan can with a label band
			_cyl(parent, 0.18, 0.34, Vector3.ZERO, Color(0.85, 0.6, 0.3), 0.35)
			_cyl(parent, 0.185, 0.07, Vector3.ZERO, Color(0.6, 0.4, 0.2), 0.35)
		"ammo":    # ammo box with brass rounds on top
			_box(parent, Vector3(0.4, 0.24, 0.3), Vector3.ZERO, Color(0.3, 0.27, 0.2), 0.25)
			for i in 3:
				_cyl(parent, 0.05, 0.2, Vector3((i - 1) * 0.12, 0.2, 0), Color(1.0, 0.8, 0.3), 0.5)
		"armor":   # chest plate with shoulder pads
			_box(parent, Vector3(0.46, 0.5, 0.16), Vector3(0, 0.05, 0), Color(0.55, 0.58, 0.65), 0.25)
			_box(parent, Vector3(0.16, 0.14, 0.16), Vector3(-0.28, 0.2, 0), Color(0.5, 0.53, 0.6), 0.25)
			_box(parent, Vector3(0.16, 0.14, 0.16), Vector3(0.28, 0.2, 0), Color(0.5, 0.53, 0.6), 0.25)
		"backpack":  # pack with a flap
			_box(parent, Vector3(0.4, 0.5, 0.28), Vector3.ZERO, Color(0.6, 0.5, 0.35), 0.25)
			_box(parent, Vector3(0.42, 0.14, 0.06), Vector3(0, 0.1, 0.16), Color(0.45, 0.37, 0.25), 0.25)
		_:
			_box(parent, Vector3(0.5, 0.5, 0.5), Vector3.ZERO, _color(), 0.6)

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
	# Adventure: nothing is auto-collected — the player picks it up manually with E
	# (Player calls collect()). Outside Adventure, touching still grabs it.
	if Game.is_adventure():
		return
	# Skip if it would be wasted, so you don't burn a respawn for nothing.
	if kind == "health" and body.sync_health >= body.MAX_HEALTH:
		return
	if kind == "grenade" and body.grenades >= body.MAX_GRENADES:
		return
	_apply(body)
	Audio.play_3d("res://assets/audio/reload.ogg", global_position, 0.0, 0.05)
	_set_available.rpc(false)

## Adventure: collect into the backpack (called by the player pressing E nearby).
func collect(body: Node) -> bool:
	if not available or not Game.is_adventure():
		return false
	if not body.is_multiplayer_authority() or body.get("dead"):
		return false
	var item: Dictionary = item_data if not item_data.is_empty() else ItemDB.from_pickup(kind, amount, weapon_id)
	if body.has_method("inv_add") and body.inv_add(item):
		if body.is_multiplayer_authority():
			Audio.play_ui("res://assets/audio/pickup.wav", -8.0)   # local collect chime
		_take.rpc()
		return true
	return false

## Display name for the [E] pick-up prompt.
func label() -> String:
	if not item_data.is_empty():
		return String(item_data.get("name", "Item"))
	if kind == "weapon" and WeaponDB.has_weapon(weapon_id):
		return String(WeaponDB.get_weapon(weapon_id)["name"])
	if kind == "armor" and ItemDB.DEFS.has(weapon_id):
		return String(ItemDB.DEFS[weapon_id]["name"])
	return kind.capitalize()

## Adventure: a collected/used pickup is removed for good (no respawn).
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
