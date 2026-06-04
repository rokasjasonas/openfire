extends Node
## Loads co-op mission definitions from JSON files in res://missions/.
##
## To add a mission: drop a new .json file in that folder (see docs/missions.md).
## No code changes are required — it is discovered automatically at launch.
##
## Mission schema (all objective runtime lives in scripts/world/objective_runner.gd):
## {
##   "id": "unique_id",
##   "name": "Display Name",
##   "description": "One-line briefing.",
##   "map": "res://maps/facility.tscn",
##   "enemy_skill": 1.0,
##   "objectives": [ { "type": "...", "description": "...", ...params } ]
## }

const MISSIONS_DIR := "res://missions/"

var _missions: Array[Dictionary] = []

func _ready() -> void:
	reload()

func reload() -> void:
	_missions.clear()
	var dir := DirAccess.open(MISSIONS_DIR)
	if dir == null:
		push_warning("Missions: cannot open %s" % MISSIONS_DIR)
		return
	var files := dir.get_files()
	files.sort()  # filenames prefixed 01_, 02_ control display order
	for f in files:
		if not f.to_lower().ends_with(".json"):
			continue
		var path := MISSIONS_DIR + f
		var m := _load_file(path)
		if not m.is_empty():
			_missions.append(m)
	print("Missions: loaded %d mission(s)" % _missions.size())

func _load_file(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt == "":
		push_warning("Missions: empty/unreadable %s" % path)
		return {}
	var json := JSON.new()
	if json.parse(txt) != OK:
		push_error("Missions: JSON error in %s at line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return {}
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Missions: %s is not a JSON object" % path)
		return {}
	if not _validate(data, path):
		return {}
	data["_path"] = path
	return data

func _validate(m: Dictionary, path: String) -> bool:
	for key in ["id", "name", "map", "objectives"]:
		if not m.has(key):
			push_error("Missions: %s missing required key '%s'" % [path, key])
			return false
	if typeof(m["objectives"]) != TYPE_ARRAY or (m["objectives"] as Array).is_empty():
		push_error("Missions: %s must have a non-empty 'objectives' array" % path)
		return false
	if not ResourceLoader.exists(m["map"]):
		push_warning("Missions: %s references missing map %s" % [path, m["map"]])
	return true

func get_all() -> Array[Dictionary]:
	return _missions

func get_mission(id: String) -> Dictionary:
	for m in _missions:
		if m["id"] == id:
			return m
	return {}

func first_id() -> String:
	return _missions[0]["id"] if not _missions.is_empty() else ""
