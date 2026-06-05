extends Area3D
## A Domination control point. The host computes capture (see world.gd) and pushes
## bar/owner state here for the visual; clients just display it. A point fully held
## by a team ticks score for that team.

@export var point_id: String = "A"

var bar: float = 0.0      # -1 (RED held) .. +1 (BLUE held)
var owner_team: int = -1  # -1 neutral

var _ring: MeshInstance3D
var _beam: MeshInstance3D
var _mat: StandardMaterial3D
var _beam_mat: StandardMaterial3D
var _label: Label3D

func _ready() -> void:
	add_to_group("control_point")
	collision_layer = 0
	collision_mask = 2 | 4  # detect players + bots on foot
	_build()

func _build() -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8, 5, 8)
	cs.shape = box
	cs.position.y = 2.5
	add_child(cs)
	# Floor ring.
	_ring = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 4.0
	cyl.bottom_radius = 4.0
	cyl.height = 0.12
	_ring.mesh = cyl
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.emission_enabled = true
	_ring.material_override = _mat
	_ring.position.y = 0.06
	add_child(_ring)
	# Vertical beam so the point is visible from afar.
	_beam = MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.5
	bm.bottom_radius = 0.5
	bm.height = 12.0
	_beam.mesh = bm
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.emission_enabled = true
	_beam.material_override = _beam_mat
	_beam.position.y = 6.0
	add_child(_beam)
	# Letter.
	_label = Label3D.new()
	_label.text = point_id
	_label.position = Vector3(0, 4.0, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.012
	add_child(_label)
	_update_visual()

## [blue_count, red_count] of living on-foot bodies standing in the point.
func team_counts() -> Array:
	var blue := 0
	var red := 0
	for body in get_overlapping_bodies():
		if not (body.is_in_group("player") or body.is_in_group("bot")):
			continue
		if body.get("dead") or body.get("downed") or body.get("fully_dead"):
			continue
		match int(body.get("team")):
			0: blue += 1
			1: red += 1
	return [blue, red]

@rpc("authority", "call_local", "unreliable")
func set_state(b: float, ot: int) -> void:
	bar = b
	owner_team = ot
	_update_visual()

func _update_visual() -> void:
	var c := Game.team_color(owner_team) if owner_team >= 0 else Color(0.65, 0.65, 0.65)
	_mat.albedo_color = Color(c.r, c.g, c.b, 0.45)
	_mat.emission = c
	_beam_mat.albedo_color = Color(c.r, c.g, c.b, 0.22)
	_beam_mat.emission = c
	_label.modulate = c
