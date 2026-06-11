extends Node
## Persistent player-character profiles for Adventure mode (autoload "Characters").
##
## Each character is a JSON file in a "characters/" folder NEXT TO THE EXECUTABLE
## (so saves travel with the build and are easy to find), falling back to
## user://characters/ if that location isn't writable. A profile carries the
## player's name, appearance tint, chosen starting kit and backstory, and — the
## point of it all — the gear and lifetime stats that PERSIST across adventures:
## the backpack, equipped armor/grenade, and gun loadout. Adventures themselves are
## still generated fresh from a seed; the character is what you carry between them.

signal profiles_changed

var _dir: String = "user://characters/"   # resolved in _ready to sit by the executable

# Starting kits seed a brand-new character's loadout + backpack.
const KITS := {
	"scout":   {"name": "Scout",   "loadout": ["pistol"], "items": ["medkit", "food"]},
	"soldier": {"name": "Soldier", "loadout": ["rifle"],  "items": ["ammo", "ammo"]},
	"forager": {"name": "Forager", "loadout": ["pistol"], "items": ["food", "food", "water", "backpack_small"]},
}
const KIT_IDS := ["scout", "soldier", "forager"]

# Perks bought with perk points (1 point per 3 lifetime quest points). One-time buys,
# applied to the player on spawn.
const PERKS := {
	"reload": {"name": "Fast hands", "desc": "Reload 25% faster"},
	"carry":  {"name": "Pack mule", "desc": "Bigger backpack (5x4)"},
	"tough":  {"name": "Thick skin", "desc": "Take 10% less damage"},
	"lungs":  {"name": "Deep lungs", "desc": "Air lasts 40% longer underwater"},
}
const PERK_IDS := ["reload", "carry", "tough", "lungs"]

var profiles: Array = []      # Array[Dictionary], oldest first
var current: Dictionary = {}  # the chosen character for the next/active adventure

func _ready() -> void:
	_dir = _resolve_dir()
	_load_all()

## Prefer a "characters/" folder next to the game executable; if it can't be created
## or written (e.g. a read-only install), fall back to user://characters/.
func _resolve_dir() -> String:
	var candidate := OS.get_executable_path().get_base_dir().path_join("characters")
	if DirAccess.make_dir_recursive_absolute(candidate) == OK:
		var probe := candidate.path_join(".write_test")
		var f := FileAccess.open(probe, FileAccess.WRITE)
		if f != null:
			f.close()
			DirAccess.remove_absolute(probe)
			return candidate.path_join("")   # ensure a trailing separator
	var fallback := "user://characters/"
	DirAccess.make_dir_recursive_absolute(fallback)
	return fallback

func _load_all() -> void:
	profiles.clear()
	var d := DirAccess.open(_dir)
	if d == null:
		return
	for f in d.get_files():
		if not f.ends_with(".json"):
			continue
		var p: Variant = JSON.parse_string(FileAccess.get_file_as_string(_dir + f))
		if p is Dictionary and p.has("id"):
			profiles.append(p)
	profiles.sort_custom(func(a, b): return float(a.get("created", 0.0)) < float(b.get("created", 0.0)))

func _default_stats() -> Dictionary:
	return {"kills": 0, "deaths": 0, "adventures": 0, "quests": 0, "points": 0, "meters": 0.0, "shots": 0, "hits": 0}

## Create, persist, and return a new character profile from the creation screen.
func create(cname: String, color: Color, kit: String, backstory: String) -> Dictionary:
	var clean := cname.strip_edges()
	if clean == "":
		clean = "Wanderer"
	var k: Dictionary = KITS.get(kit, KITS["scout"])
	var inv: Array = []
	for item_id in k["items"]:
		inv.append(ItemDB.make(String(item_id)))
	var p := {
		"id": _slug(clean) + "_" + str(int(Time.get_unix_time_from_system())),
		"name": clean,
		"color": [color.r, color.g, color.b],
		"kit": kit,
		"backstory": backstory.strip_edges(),
		"created": Time.get_unix_time_from_system(),
		"loadout": _pad_loadout(k["loadout"]),
		"inventory": inv,
		"equip": {"head": {}, "body": {}, "pants": {}, "extra": {}},
		"stats": _default_stats(),
		"perks": [],
		"coins": 15,
	}
	save(p)
	profiles.append(p)
	current = p
	profiles_changed.emit()
	return p

func _pad_loadout(ids: Array) -> Array:
	var out := ["", "", ""]
	for i in mini(ids.size(), 3):
		out[i] = String(ids[i])
	return out

func save(p: Dictionary) -> void:
	if p.is_empty():
		return
	var f := FileAccess.open(_dir + String(p["id"]) + ".json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(p, "\t"))

func delete(id: String) -> void:
	if FileAccess.file_exists(_dir + id + ".json"):
		DirAccess.remove_absolute(_dir + id + ".json")
	profiles = profiles.filter(func(p): return String(p.get("id", "")) != id)
	if String(current.get("id", "")) == id:
		current = {}
	profiles_changed.emit()

func set_current(id: String) -> void:
	current = {}
	for p in profiles:
		if String(p.get("id", "")) == id:
			current = p
			return

func has_current() -> bool:
	return not current.is_empty()

func color_of(p: Dictionary) -> Color:
	var c: Array = p.get("color", [0.6, 0.7, 0.9])
	return Color(float(c[0]), float(c[1]), float(c[2]))

func kit_name(kit: String) -> String:
	return String((KITS.get(kit, KITS["scout"]) as Dictionary)["name"])

# ---------------------------------------------------------------- perks

## Perk points earned over the character's lifetime: 1 per 3 quest points.
func perk_points(p: Dictionary) -> int:
	var st: Dictionary = p.get("stats", {})
	return int(st.get("points", 0)) / 3 - (p.get("perks", []) as Array).size()

func has_perk(id: String) -> bool:
	return (current.get("perks", []) as Array).has(id)

## Buy a perk for the current character (1 perk point each). Saves immediately.
func buy_perk(id: String) -> bool:
	if current.is_empty() or not PERKS.has(id) or has_perk(id) or perk_points(current) <= 0:
		return false
	var owned: Array = current.get("perks", [])
	owned.append(id)
	current["perks"] = owned
	save(current)
	profiles_changed.emit()
	return true

## Push the current character's perks onto a live player (also used mid-run on buy).
func apply_perks(player: Node) -> void:
	var owned: Array = current.get("perks", [])
	player.perks = owned.duplicate()
	if owned.has("carry") and int(player.backpack_w) <= ItemDB.DEFAULT_GRID_W:
		player.backpack_w = 5   # Pack mule: one extra column

## Apply the current character to the freshly-spawned local player (Adventure start).
func apply_to_player(player: Node) -> void:
	if current.is_empty():
		return
	player.display_name = String(current["name"])
	player.inventory = (current.get("inventory", []) as Array).duplicate(true)
	player.equip = (current.get("equip", {}) as Dictionary).duplicate(true)
	player.weapons.set_loadout((current.get("loadout", ["pistol"]) as Array).duplicate())
	if player.has_method("set_body_tint"):
		player.set_body_tint(color_of(current))
	player.coins = int(current.get("coins", 0))
	apply_perks(player)
	player.inventory_changed.emit()
	player.equipment_changed.emit()

## Read the local player's gear + this run's stats back into the profile and save.
## Call once when an adventure ends (win or leave).
func capture_from_player(player: Node) -> void:
	if current.is_empty() or player == null or not is_instance_valid(player):
		return
	current["inventory"] = player.inventory.duplicate(true)
	current["equip"] = player.equip.duplicate(true)
	current["loadout"] = player.weapons.loadout.duplicate()
	current["coins"] = int(player.get("coins"))
	var st: Dictionary = current.get("stats", _default_stats())
	var sc: Dictionary = Game.scores.get(player.combatant_id, {})
	st["kills"] = int(st.get("kills", 0)) + int(sc.get("kills", 0))
	st["deaths"] = int(st.get("deaths", 0)) + int(sc.get("deaths", 0))
	st["meters"] = float(st.get("meters", 0.0)) + float(player.get("meters_walked"))
	st["shots"] = int(st.get("shots", 0)) + int(player.get("shots_fired"))
	st["hits"] = int(st.get("hits", 0)) + int(player.get("shots_hit"))
	var qm = player.get_tree().get_first_node_in_group("quest_manager")
	if qm != null:
		st["points"] = int(st.get("points", 0)) + int(qm.points)
		for q in qm.quests:
			if q.get("state", "") == "complete":
				st["quests"] = int(st.get("quests", 0)) + 1
	st["adventures"] = int(st.get("adventures", 0)) + 1
	current["stats"] = st
	save(current)

func _slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out if out != "" else "char"
