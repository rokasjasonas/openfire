extends Node
## Central, data-driven weapon catalog.
## Add a weapon by appending a dictionary to WEAPONS — no other code changes needed.
## All weapons here are hitscan for responsive LAN play; `pellets` > 1 makes a shotgun.

const WEAPONS: Array[Dictionary] = [
	{
		"id": "rifle",
		"name": "Assault Rifle",
		"model": "res://assets/models/weapons/blaster-a.glb",
		"slot": 0,
		"damage": 17.0,
		"fire_rate": 9.0,        # shots per second
		"automatic": true,
		"mag_size": 30,
		"reserve": 120,
		"reload_time": 1.9,
		"spread_deg": 1.3,       # cone half-angle while hip-firing
		"aim_spread_deg": 0.3,
		"range": 120.0,
		"pellets": 1,
		"zoom_fov": 55.0,
	},
	{
		"id": "smg",
		"name": "SMG",
		"model": "res://assets/models/weapons/blaster-e.glb",
		"slot": 0,
		"damage": 12.0,
		"fire_rate": 14.0,
		"automatic": true,
		"mag_size": 25,
		"reserve": 150,
		"reload_time": 1.6,
		"spread_deg": 2.2,
		"aim_spread_deg": 0.8,
		"range": 80.0,
		"pellets": 1,
		"zoom_fov": 60.0,
	},
	{
		"id": "shotgun",
		"name": "Shotgun",
		"model": "res://assets/models/weapons/blaster-h.glb",
		"slot": 1,
		"damage": 9.0,           # per pellet
		"fire_rate": 1.2,
		"automatic": false,
		"mag_size": 6,
		"reserve": 36,
		"reload_time": 2.4,
		"spread_deg": 6.0,
		"aim_spread_deg": 4.0,
		"range": 35.0,
		"pellets": 9,
		"zoom_fov": 65.0,
	},
	{
		"id": "sniper",
		"name": "Sniper",
		"model": "res://assets/models/weapons/blaster-r.glb",
		"slot": 1,
		"damage": 95.0,
		"fire_rate": 1.0,
		"automatic": false,
		"mag_size": 5,
		"reserve": 30,
		"reload_time": 2.8,
		"spread_deg": 0.4,
		"aim_spread_deg": 0.02,
		"range": 300.0,
		"pellets": 1,
		"zoom_fov": 25.0,
	},
	{
		"id": "pistol",
		"name": "Pistol",
		"model": "res://assets/models/weapons/blaster-c.glb",
		"slot": 2,
		"damage": 24.0,
		"fire_rate": 5.0,
		"automatic": false,
		"mag_size": 12,
		"reserve": 72,
		"reload_time": 1.3,
		"spread_deg": 1.0,
		"aim_spread_deg": 0.4,
		"range": 90.0,
		"pellets": 1,
		"zoom_fov": 60.0,
	},
]

var _by_id: Dictionary = {}

func _ready() -> void:
	for w in WEAPONS:
		_by_id[w["id"]] = w

func get_weapon(id: String) -> Dictionary:
	return _by_id.get(id, WEAPONS[0])

func has_weapon(id: String) -> bool:
	return _by_id.has(id)

func all_ids() -> Array:
	return _by_id.keys()

## Default 3-weapon loadout players and bots spawn with.
func default_loadout() -> Array:
	return ["rifle", "shotgun", "pistol"]
