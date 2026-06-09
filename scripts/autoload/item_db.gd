extends Node
## Adventure item definitions + factory (autoload "ItemDB").
##
## Items do NOT stack and occupy a rectangular footprint (w x h cells) in a spatial
## grid backpack (a la Tarkov). The backpack itself is a grid (grid_w x grid_h);
## items keep a fixed orientation. Effects are applied by Player.inv_use().
##
## Item dict shape: { id, name, kind, w, h, size, ...effect fields, gx, gy }
##   kind: food | water | health | ammo | grenade | weapon | backpack
##   size = w * h (cells). gx/gy are the placed grid position (set when stored).

const DEFAULT_GRID_W := 4
const DEFAULT_GRID_H := 4   # default backpack = 4x4 = 16 cells

const DEFS := {
	"food":           {"name": "Rations",    "kind": "food",     "w": 1, "h": 1, "amount": 40},
	"water":          {"name": "Water",      "kind": "water",    "w": 1, "h": 1, "amount": 50},
	"medkit":         {"name": "Medkit",     "kind": "health",   "w": 1, "h": 2, "amount": 50},
	"ammo":           {"name": "Ammo Box",   "kind": "ammo",     "w": 1, "h": 1},
	"grenade":        {"name": "Grenade",    "kind": "grenade",  "w": 1, "h": 1, "amount": 1},
	"backpack_small": {"name": "Small Pack", "kind": "backpack", "w": 2, "h": 2, "grid_w": 3, "grid_h": 4},
	"backpack_large": {"name": "Large Pack", "kind": "backpack", "w": 2, "h": 3, "grid_w": 4, "grid_h": 7},
	# Armor: "slot" maps to an equip slot; "armor" is the fraction of damage cut on
	# that body zone (head armor -> head zone, body -> torso, pants -> legs).
	"helmet":     {"name": "Helmet",     "kind": "armor", "slot": "head",  "armor": 0.35, "w": 1, "h": 1},
	"vest":       {"name": "Body Armor", "kind": "armor", "slot": "body",  "armor": 0.40, "w": 2, "h": 2},
	"leg_armor":  {"name": "Leg Guards", "kind": "armor", "slot": "pants", "armor": 0.30, "w": 1, "h": 2},
}

const ARMOR_IDS := ["helmet", "vest", "leg_armor"]

func _finalize(d: Dictionary) -> Dictionary:
	d["w"] = int(d.get("w", 1))
	d["h"] = int(d.get("h", 1))
	d["size"] = d["w"] * d["h"]
	return d

## Build an item instance from a definition id.
func make(id: String) -> Dictionary:
	if not DEFS.has(id):
		return {}
	var d: Dictionary = (DEFS[id] as Dictionary).duplicate()
	d["id"] = id
	return _finalize(d)

## Footprint per weapon (w, h). Pistol is compact; long guns are 2x1.
const WEAPON_FOOTPRINT := {
	"pistol": Vector2i(1, 1),
}

func make_weapon(weapon_id: String) -> Dictionary:
	var wname := weapon_id.capitalize()
	if WeaponDB.has_weapon(weapon_id):
		wname = String(WeaponDB.get_weapon(weapon_id)["name"])
	var fp: Vector2i = WEAPON_FOOTPRINT.get(weapon_id, Vector2i(2, 1))
	return _finalize({"id": "weapon", "name": wname, "kind": "weapon", "w": fp.x, "h": fp.y, "weapon_id": weapon_id})

var _icon_cache: Dictionary = {}

## A 2D icon image for an item (weapon preview render), or null to draw a glyph.
func icon_texture(item: Dictionary) -> Texture2D:
	if String(item.get("kind", "")) != "weapon":
		return null
	var wid := String(item.get("weapon_id", ""))
	if _icon_cache.has(wid):
		return _icon_cache[wid]
	var tex: Texture2D = null
	if WeaponDB.has_weapon(wid):
		var base := String(WeaponDB.get_weapon(wid)["model"]).get_file().get_basename()
		var path := "res://assets/kenney/blaster-kit/Previews/%s.png" % base
		if ResourceLoader.exists(path):
			tex = load(path)
	_icon_cache[wid] = tex
	return tex

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
		"armor":
			return make(weapon_id) if DEFS.has(weapon_id) else make("vest")
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
			return _finalize({"id": kind, "name": kind.capitalize(), "kind": kind, "w": 1, "h": 1})

func color_for(kind: String) -> Color:
	match kind:
		"food": return Color(0.85, 0.6, 0.3)
		"water": return Color(0.3, 0.6, 1.0)
		"health": return Color(0.3, 1.0, 0.4)
		"ammo": return Color(1.0, 0.7, 0.2)
		"grenade": return Color(0.9, 0.9, 0.35)
		"weapon": return Color(0.7, 0.8, 1.0)
		"backpack": return Color(0.6, 0.5, 0.35)
		"armor": return Color(0.55, 0.58, 0.65)
		_: return Color(1, 1, 1)
