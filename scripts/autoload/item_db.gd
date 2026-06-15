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
	# Hunting: raw meat barely helps (and risks nothing fancy); cook it at a campfire.
	"raw_meat":       {"name": "Raw Meat",    "kind": "food", "w": 1, "h": 1, "amount": 15, "cookable": true},
	"cooked_meat":    {"name": "Cooked Meat", "kind": "food", "w": 1, "h": 1, "amount": 55},
	"hide":           {"name": "Animal Hide", "kind": "material", "w": 1, "h": 1},
	"wood":           {"name": "Wood",        "kind": "material", "w": 1, "h": 1},
	"scrap":          {"name": "Scrap Metal", "kind": "material", "w": 1, "h": 1},
	"stone":          {"name": "Stone",       "kind": "material", "w": 1, "h": 1},
	"medkit":         {"name": "Medkit",     "kind": "health",   "w": 1, "h": 2, "amount": 50},
	"ammo":           {"name": "Ammo Box",   "kind": "ammo",     "w": 1, "h": 1},
	# Grenades all share kind "grenade" (one throw slot + one count); "gtype" picks the
	# behaviour. The equipped grenade's gtype is what G throws.
	"grenade":           {"name": "Frag Grenade",   "kind": "grenade", "gtype": "frag",       "w": 1, "h": 1, "amount": 1},
	"grenade_smoke":     {"name": "Smoke Grenade",  "kind": "grenade", "gtype": "smoke",      "w": 1, "h": 1, "amount": 1},
	"grenade_flash":     {"name": "Flashbang",      "kind": "grenade", "gtype": "flashbang",  "w": 1, "h": 1, "amount": 1},
	"grenade_incendiary":{"name": "Incendiary",     "kind": "grenade", "gtype": "incendiary", "w": 1, "h": 1, "amount": 1},
	"grenade_impact":    {"name": "Impact Grenade", "kind": "grenade", "gtype": "impact",     "w": 1, "h": 1, "amount": 1},
	"grenade_shock":     {"name": "Shockwave Charge","kind": "grenade","gtype": "shockwave",  "w": 1, "h": 1, "amount": 1},
	"grenade_void":      {"name": "Void Grenade",   "kind": "grenade", "gtype": "blackhole",  "w": 1, "h": 1, "amount": 1},
	# Gadgets — special-slot gear, activated with Q.
	"flashlight":     {"name": "Flashlight",      "kind": "gadget", "gadget": "flashlight", "w": 1, "h": 1},
	"binoculars":     {"name": "Binoculars",      "kind": "gadget", "gadget": "binoculars", "w": 1, "h": 1},
	"nvg":            {"name": "Night Vision",    "kind": "gadget", "gadget": "nvg",        "w": 1, "h": 1},
	"scanner":        {"name": "Motion Scanner",  "kind": "gadget", "gadget": "scanner",    "w": 1, "h": 1},
	# Torch: a light that burns down (fuel) and is consumed when spent. Jetpack: hold jump
	# to thrust upward, draining fuel that recharges on the ground.
	"torch":          {"name": "Torch",   "kind": "gadget", "gadget": "torch",   "fuel": 35.0, "w": 1, "h": 1},
	"jetpack":        {"name": "Jetpack",  "kind": "gadget", "gadget": "jetpack", "fuel": 100.0, "w": 2, "h": 2},
	# Shovel: Q digs a covered tunnel segment ahead of you (carve your own passage).
	"shovel":         {"name": "Shovel",  "kind": "gadget", "gadget": "shovel",  "w": 1, "h": 2},
	# Money — a droppable currency item (used to hire follower NPCs).
	"money":          {"name": "Cash",    "kind": "money", "amount": 25, "w": 1, "h": 1},
	"backpack_small": {"name": "Small Pack", "kind": "backpack", "w": 2, "h": 2, "grid_w": 3, "grid_h": 4},
	"backpack_large": {"name": "Large Pack", "kind": "backpack", "w": 2, "h": 3, "grid_w": 4, "grid_h": 7},
	# Armor: "slot" maps to an equip slot; "armor_hp" is a pool of EXTRA hit points for
	# that body zone (head->head, body->torso, pants->legs). Damage to the zone drains the
	# armor first; when it hits 0 the piece breaks and is removed. cur_hp tracks the
	# remaining durability of a specific instance (set in make()).
	"helmet":     {"name": "Helmet",     "kind": "armor", "slot": "head",  "armor_hp": 45, "w": 1, "h": 1},
	"vest":       {"name": "Body Armor", "kind": "armor", "slot": "body",  "armor_hp": 80, "w": 2, "h": 2},
	"leg_armor":  {"name": "Leg Guards", "kind": "armor", "slot": "pants", "armor_hp": 55, "w": 1, "h": 2},
}

const ARMOR_IDS := ["helmet", "vest", "leg_armor"]

# Crafting recipes: consume material/food items from the backpack, produce an item
# (or a deployable like "_campfire"). "fire" recipes need a lit campfire nearby.
const RECIPES := [
	{"id": "cook",     "name": "Cook Meat",   "in": {"raw_meat": 1}, "out": "cooked_meat", "fire": true},
	{"id": "bandage",  "name": "Bandage",     "in": {"hide": 2},     "out": "medkit",      "fire": false},
	{"id": "makeammo", "name": "Craft Ammo",  "in": {"scrap": 1},    "out": "ammo",        "fire": false},
	{"id": "campfire", "name": "Campfire",    "in": {"wood": 3},     "out": "_campfire",   "fire": false},
	{"id": "stonehelm","name": "Improvised Helmet", "in": {"stone": 2, "hide": 1}, "out": "helmet", "fire": false},
	{"id": "torch",    "name": "Torch",      "in": {"wood": 1, "scrap": 1}, "out": "torch",   "fire": true},
	{"id": "jetpack",  "name": "Jetpack",    "in": {"scrap": 5, "wood": 1}, "out": "jetpack", "fire": false},
	{"id": "shovel",   "name": "Shovel",     "in": {"scrap": 2, "wood": 1}, "out": "shovel",  "fire": false},
]
const GRENADE_IDS := ["grenade", "grenade_smoke", "grenade_flash", "grenade_incendiary", "grenade_impact", "grenade_shock", "grenade_void"]
const GADGET_IDS := ["flashlight", "binoculars", "nvg", "scanner"]

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
	if d.has("armor_hp"):
		d["cur_hp"] = int(d["armor_hp"])   # a fresh piece starts at full durability
	if d.has("fuel"):
		d["cur_fuel"] = float(d["fuel"])   # torches/jetpacks start with a full tank
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

# ---------------------------------------------------------------- trade values

const WEAPON_VALUE := {"pistol": 8, "smg": 14, "shotgun": 16, "rifle": 18, "sniper": 24}
const ARMOR_VALUE := {"helmet": 10, "vest": 12, "leg_armor": 8}
const GRENADE_VALUE := {"frag": 5, "smoke": 4, "flashbang": 5, "incendiary": 7, "impact": 7, "shockwave": 8, "blackhole": 12}
const GADGET_VALUE := {"flashlight": 6, "binoculars": 9, "nvg": 14, "scanner": 12, "torch": 4, "jetpack": 30, "shovel": 7}

## Coin value of an item (Quartermaster trading). Buy at value, sell at half.
func value_of(item: Dictionary) -> int:
	match String(item.get("kind", "")):
		"weapon": return int(WEAPON_VALUE.get(String(item.get("weapon_id", "")), 14))
		"armor": return int(ARMOR_VALUE.get(String(item.get("id", "")), 10))
		"grenade": return int(GRENADE_VALUE.get(String(item.get("gtype", "frag")), 5))
		"gadget": return int(GADGET_VALUE.get(String(item.get("gadget", "")), 8))
		"health": return 6
		"ammo": return 4
		"food": return 3
		"water": return 3
		"material": return 2
		"money": return int(item.get("amount", 25))
		"backpack": return 12
		_: return 2

func sell_value(item: Dictionary) -> int:
	return maxi(1, value_of(item) / 2)

## Per-item display colour (distinguishes subtypes — wood vs scrap, grenade types,
## gadget types — so backpack items read uniquely). Falls back to color_for(kind).
func item_color(item: Dictionary) -> Color:
	match String(item.get("kind", "")):
		"material":
			match String(item.get("id", "")):
				"wood": return Color(0.5, 0.35, 0.2)
				"scrap": return Color(0.56, 0.58, 0.63)
				"stone": return Color(0.62, 0.61, 0.58)
				"hide": return Color(0.64, 0.47, 0.3)
		"grenade":
			match String(item.get("gtype", "frag")):
				"smoke": return Color(0.7, 0.72, 0.75)
				"flashbang": return Color(1.0, 0.95, 0.6)
				"incendiary": return Color(1.0, 0.5, 0.2)
				"shockwave": return Color(0.5, 0.8, 1.0)
				"blackhole": return Color(0.6, 0.3, 0.9)
				_: return Color(0.85, 0.85, 0.35)
		"gadget":
			match String(item.get("gadget", "")):
				"torch": return Color(1.0, 0.7, 0.4)
				"jetpack": return Color(0.8, 0.85, 0.95)
				"shovel": return Color(0.7, 0.6, 0.45)
				"nvg": return Color(0.4, 1.0, 0.5)
				_: return Color(0.4, 0.85, 0.9)
	return color_for(String(item.get("kind", "")))

func color_for(kind: String) -> Color:
	match kind:
		"food": return Color(0.85, 0.6, 0.3)
		"water": return Color(0.3, 0.6, 1.0)
		"health": return Color(0.3, 1.0, 0.4)
		"ammo": return Color(1.0, 0.7, 0.2)
		"grenade": return Color(0.9, 0.9, 0.35)
		"gadget": return Color(0.4, 0.85, 0.9)
		"material": return Color(0.7, 0.6, 0.45)
		"money": return Color(0.35, 0.8, 0.4)
		"weapon": return Color(0.7, 0.8, 1.0)
		"backpack": return Color(0.6, 0.5, 0.35)
		"armor": return Color(0.55, 0.58, 0.65)
		_: return Color(1, 1, 1)
