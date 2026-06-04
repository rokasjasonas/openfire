extends Node
## Global match state and configuration shared by menu, lobby and world.
## The host fills `config` in the lobby; Net replicates it to clients before the
## world loads so everyone agrees on mode / map / mission / limits.

signal score_changed
signal kill_logged(killer_id: int, victim_id: int)
signal match_over(result: Dictionary)

enum Mode { DEATHMATCH, COOP }

# Team ids. In coop, humans share TEAM_PLAYERS and bots are TEAM_ENEMIES.
# In deathmatch every combatant is assigned a unique negative team (free-for-all).
const TEAM_PLAYERS := 0
const TEAM_ENEMIES := 1

var player_name: String = "Player"

# Default match configuration; overwritten by the lobby / host.
var config: Dictionary = {
	"mode": Mode.DEATHMATCH,
	"map": "res://maps/arena.tscn",
	"mission_id": "",          # used only in coop
	"bot_count": 6,
	"bot_skill": 1.0,          # 0.5 = easy, 1.0 = normal, 1.5 = hard
	"frag_limit": 25,          # deathmatch
	"time_limit": 600,         # seconds, 0 = unlimited
}

# Live per-combatant scoreboard: id -> { name, kills, deaths, is_bot, team }
var scores: Dictionary = {}

var match_active: bool = false

func reset_scores() -> void:
	scores.clear()
	score_changed.emit()

func register_combatant(id: int, cname: String, is_bot: bool, team: int) -> void:
	if not scores.has(id):
		scores[id] = {"name": cname, "kills": 0, "deaths": 0, "is_bot": is_bot, "team": team}
		score_changed.emit()

func unregister_combatant(id: int) -> void:
	if scores.erase(id):
		score_changed.emit()

func add_kill(killer_id: int, victim_id: int) -> void:
	if scores.has(victim_id):
		scores[victim_id]["deaths"] += 1
	if scores.has(killer_id) and killer_id != victim_id:
		scores[killer_id]["kills"] += 1
	elif scores.has(killer_id) and killer_id == victim_id:
		# Suicide / environment: subtract a frag.
		scores[killer_id]["kills"] = max(0, scores[killer_id]["kills"] - 1)
	kill_logged.emit(killer_id, victim_id)
	score_changed.emit()
	_check_deathmatch_end()

func _check_deathmatch_end() -> void:
	if config["mode"] != Mode.DEATHMATCH or not match_active:
		return
	var limit: int = config["frag_limit"]
	if limit <= 0:
		return
	for id in scores:
		if scores[id]["kills"] >= limit:
			end_match({"reason": "frag_limit", "winner": id})
			return

func sorted_scoreboard() -> Array:
	var rows: Array = []
	for id in scores:
		var r: Dictionary = scores[id].duplicate()
		r["id"] = id
		rows.append(r)
	rows.sort_custom(func(a, b): return a["kills"] > b["kills"])
	return rows

func is_coop() -> bool:
	return config["mode"] == Mode.COOP

func mode_name() -> String:
	return "Co-op" if is_coop() else "Deathmatch"

func end_match(result: Dictionary) -> void:
	if not match_active:
		return
	match_active = false
	match_over.emit(result)
