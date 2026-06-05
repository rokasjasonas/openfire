extends Node
## Global match state and configuration shared by menu, lobby and world.
## The host fills `config` in the lobby; Net replicates it to clients before the
## world loads so everyone agrees on mode / map / mission / limits.

signal score_changed
signal kill_logged(killer_id: int, victim_id: int)
signal lives_changed(lives: int)
signal match_over(result: Dictionary)

# Shared co-op respawn tickets (host-authoritative, replicated to clients).
var coop_lives: int = 6

enum Mode { DEATHMATCH, COOP, TEAM_DEATHMATCH }

# Team ids. In coop, humans share TEAM_PLAYERS and bots are TEAM_ENEMIES.
# In team deathmatch, teams 0 and 1 are BLUE and RED (each holds players + bots).
# In free-for-all deathmatch every combatant gets a unique team.
const TEAM_PLAYERS := 0
const TEAM_ENEMIES := 1

const TEAM_NAMES := { 0: "BLUE", 1: "RED" }
const TEAM_COLORS := { 0: Color(0.35, 0.6, 1.0), 1: Color(1.0, 0.4, 0.3) }

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
	_check_score_end()

func _check_score_end() -> void:
	if not match_active:
		return
	var limit: int = config["frag_limit"]
	if limit <= 0:
		return
	if config["mode"] == Mode.DEATHMATCH:
		for id in scores:
			if scores[id]["kills"] >= limit:
				end_match({"reason": "frag_limit", "winner": id})
				return
	elif config["mode"] == Mode.TEAM_DEATHMATCH:
		for team in [TEAM_PLAYERS, TEAM_ENEMIES]:
			if team_score(team) >= limit:
				end_match({"reason": "frag_limit", "winner_team": team})
				return

func team_score(team: int) -> int:
	var total := 0
	for id in scores:
		if scores[id]["team"] == team:
			total += scores[id]["kills"]
	return total

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

func is_team_deathmatch() -> bool:
	return config["mode"] == Mode.TEAM_DEATHMATCH

## True when combatants share teams (coop or TDM) — used for friendly fire and
## team-coloured nameplates. Plain deathmatch is free-for-all.
func is_team_mode() -> bool:
	return is_coop() or is_team_deathmatch()

func team_color(team: int) -> Color:
	return TEAM_COLORS.get(team, Color(1, 1, 1))

func team_name(team: int) -> String:
	return TEAM_NAMES.get(team, "Team %d" % team)

func mode_name() -> String:
	match config["mode"]:
		Mode.COOP: return "Co-op"
		Mode.TEAM_DEATHMATCH: return "Team Deathmatch"
		_: return "Deathmatch"

func end_match(result: Dictionary) -> void:
	if not match_active:
		return
	match_active = false
	match_over.emit(result)
