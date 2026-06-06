extends Node
## Survival item definitions + factory (autoload "ItemDB").
##
## Items do NOT stack — each carried item is a self-contained Dictionary instance.
## A backpack has a `capacity`; each item has a `size` (the space it occupies); some
## items are bulkier than others. Effects are applied by Player.inv_use().
##
## Item dict shape: { id, name, kind, size, ...effect fields }
##   kind: food | water | health | ammo | grenade | weapon | backpack
##   effect fields: amount (food/water/health/grenade), weapon_id (weapon),
##                  capacity (backpack)

const DEFAULT_CAPACITY := 16.0
const WEAPON_SIZE := 4.0

const DEFS := {
	"food":           {"name": "Rations",    "kind": "food",     "size": 1.0, "amount": 40},
	"water":          {"name": "Water",      "kind": "water",    "size": 1.0, "amount": 50},
	"medkit":         {"name": "Medkit",     "kind": "health",   "size": 2.0, "amount": 50},
	"ammo":           {"name": "Ammo Box",   "kind": "ammo",     "size": 1.0},
	"grenade":        {"name": "Grenade",    "kind": "grenade",  "size": 1.0, "amount": 1},
	"backpack_small": {"name": "Small Pack", "kind": "backpack", "size": 0.0, "capacity": 12.0},
	"backpack_large": {"name": "Large Pack", "kind": "backpack", "size": 0.0, "capacity": 28.0},
}

## Build an item instance from a definition id.
func make(id: String) -> Dictionary:
	if not DEFS.has(id):
		return {}
	var d: Dictionary = (DEFS[id] as Dictionary).duplicate()
	d["id"] = id
	return d

func make_weapon(weapon_id: String) -> Dictionary:
	var wname := weapon_id.capitalize()
	if WeaponDB.has_weapon(weapon_id):
		wname = String(WeaponDB.get_weapon(weapon_id)["name"])
	return {"id": "weapon", "name": wname, "kind": "weapon", "size": WEAPON_SIZE, "weapon_id": weapon_id}

## Convert a world pickup (kind + amount + weapon_id) into a carried item.
func from_pickup(kind: String, amount: int, weapon_id: String) -> Dictionary:
	match kind:
		"health":
			var m := make("medkit")
			if amount > 0:
				m["amount"] = amount
			return m
		"ammo":
			return make("ammo")
		"grenade":
			return make("grenade")
		"weapon":
			return make_weapon(weapon_id)
		"food":
			var f := make("food")
			if amount > 0:
				f["amount"] = amount
			return f
		"water":
			var w := make("water")
			if amount > 0:
				w["amount"] = amount
			return w
		_:
			return {"id": kind, "name": kind.capitalize(), "kind": kind, "size": 1.0}

func color_for(kind: String) -> Color:
	match kind:
		"food": return Color(0.85, 0.6, 0.3)
		"water": return Color(0.3, 0.6, 1.0)
		"health": return Color(0.3, 1.0, 0.4)
		"ammo": return Color(1.0, 0.7, 0.2)
		"grenade": return Color(0.9, 0.9, 0.35)
		"weapon": return Color(0.7, 0.8, 1.0)
		"backpack": return Color(0.6, 0.5, 0.35)
		_: return Color(1, 1, 1)
