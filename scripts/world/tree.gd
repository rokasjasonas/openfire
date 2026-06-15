extends StaticBody3D
## A harvestable prop — a tree or a rock. Shoot it to break it for materials; it regrows
## after a while. Trunk/boulder collides (and bakes into the navmesh); foliage/chips are
## visual. Breaking is host-authoritative and routed through the world so it replicates +
## drops materials once. (Filename kept as tree.gd for history; now generic.)

var destroyed: bool = false
var prop_id: int = -1
var drop_item: String = "wood"     # what it yields when broken (wood / stone)
var regrow_secs: float = 120.0     # how long until it regrows

## The weapon's destructible path calls this on the shooter's peer; forward to the
## world (host) which owns the prop's health.
func hit(amount: float, attacker_id: int) -> void:
	if destroyed:
		return
	var w := get_tree().get_first_node_in_group("world")
	if w != null and w.has_method("damage_prop"):
		w.damage_prop(prop_id, amount, attacker_id)

## Apply the broken/regrown state (called on every peer by the world).
func set_felled(felled: bool) -> void:
	destroyed = felled
	visible = not felled
	collision_layer = 0 if felled else 1
	for c in get_children():
		if c is CollisionShape3D:
			c.disabled = felled
