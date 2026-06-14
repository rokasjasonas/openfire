extends StaticBody3D
## A choppable tree: shoot it down for wood; it regrows after a while. Trunk collides
## (and bakes into the navmesh); the canopy is visual. Felling is host-authoritative
## and routed through the world so it replicates + drops wood once.

var destroyed: bool = false
var tree_id: int = -1

## The weapon's destructible path calls this on the shooter's peer; forward to the
## world (host) which owns the tree's health.
func hit(amount: float, attacker_id: int) -> void:
	if destroyed:
		return
	var w := get_tree().get_first_node_in_group("world")
	if w != null and w.has_method("damage_tree"):
		w.damage_tree(tree_id, amount, attacker_id)

## Apply the felled/regrown state (called on every peer by the world).
func set_felled(felled: bool) -> void:
	destroyed = felled
	visible = not felled
	collision_layer = 0 if felled else 1
	for c in get_children():
		if c is CollisionShape3D:
			c.disabled = felled
