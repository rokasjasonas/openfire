extends Area3D
class_name Hitbox
## A body-part hit volume on the "hitbox" physics layer (layer 5 / bit 16).
## Hitscan rays (with collide_with_areas) resolve which part was hit and apply
## the matching damage multiplier before routing damage to the owning combatant.

@export var part: String = "torso"
@export var multiplier: float = 1.0

func combatant() -> Node:
	# `owner` is the root of the instanced player/bot scene this hitbox belongs to.
	return owner
