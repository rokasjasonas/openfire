extends Node
## Global match state and configuration shared by menu, lobby and world.
## The host fills `config` in the lobby; Net replicates it to clients before the
## world loads so everyone agrees on mode / map / mission / limits.

signal score_changed
signal kill_logged(killer_id: int, victim_id: int)
signal lives_changed(lives: int)
signal dom_changed
signal match_over(result: Dictionary)

# Shared co-op respawn tickets (host-authoritative, replicated to clients).
var coop_lives: int = 6

# Domination: ticket score per team (0=BLUE, 1=RED). First to DOM_LIMIT wins.
const DOM_LIMIT := 250
var dom_score: Array = [0, 0]

enum Mode { DEATHMATCH, COOP, TEAM_DEATHMATCH, DOMINATION, BATTLE_ROYALE, ADVENTURE }

# Team ids. In coop, humans share TEAM_PLAYERS and bots are TEAM_ENEMIES.
# In team deathmatch, teams 0 and 1 are BLUE and RED (each holds players + bots).
# In free-for-all deathmatch every combatant gets a unique team.
const TEAM_PLAYERS := 0
const TEAM_ENEMIES := 1

const TEAM_NAMES := { 0: "BLUE", 1: "RED" }
const TEAM_COLORS := { 0: Color(0.35, 0.6, 1.0), 1: Color(1.0, 0.4, 0.3) }

var player_name: String = "Player"

# Adventure continue: a saved world snapshot to restore once the world rebuilds
# (set by the menu's Continue button; consumed and cleared by the world).
var continue_data: Dictionary = {}

# Default match configuration; overwritten by the lobby / host.
var config: Dictionary = {
	"mode": Mode.ADVENTURE,
	"map": "res://maps/arena.tscn",
	"mission_id": "",          # used only in coop
	"bot_count": 6,
	"bot_skill": 1.0,          # 0.5 = easy, 1.0 = normal, 1.5 = hard
	"frag_limit": 25,          # deathmatch
	"time_limit": 600,         # seconds, 0 = unlimited
	# Adventure mode (most take effect in later chunks).
	"mission_points": 10,      # adventure point target (2-100)
	"seed": 0,                 # world generation seed (0 = random at host time)
	"map_size": 1,             # 0 = small, 1 = medium, 2 = large
	"theme": "",               # adventure story theme (drives LLM/offline generation)
}

# Adventure narrative (host generates via Story; replicated to clients).
var story: Dictionary = {}

# Live per-combatant scoreboard: id -> { name, kills, deaths, is_bot, team }
var scores: Dictionary = {}

var match_active: bool = false

func _ready() -> void:
	# Run at the screen's refresh rate (vsync), with max_fps matched as a backstop.
	if DisplayServer.get_name() != "headless":
		var hz := DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen())
		if hz > 0.0:
			Engine.max_fps = int(round(hz))
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)

func reset_scores() -> void:
	scores.clear()
	dom_score = [0, 0]
	score_changed.emit()
	dom_changed.emit()

## Domination: award a control-point tick to a team; ends the match at DOM_LIMIT.
func add_dom_point(team: int) -> void:
	if team != 0 and team != 1:
		return
	dom_score[team] += 1
	dom_changed.emit()
	if match_active and dom_score[team] >= DOM_LIMIT:
		end_match({"reason": "domination", "winner_team": team})

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

func is_domination() -> bool:
	return config["mode"] == Mode.DOMINATION

func is_battle_royale() -> bool:
	return config["mode"] == Mode.BATTLE_ROYALE

func is_adventure() -> bool:
	return config["mode"] == Mode.ADVENTURE

## True when combatants share teams (coop / TDM / domination) — used for friendly
## fire and team-coloured nameplates. Plain deathmatch is free-for-all.
func is_team_mode() -> bool:
	# Adventure: humans share a team vs the NPC world (friendly fire off).
	return is_coop() or is_team_deathmatch() or is_domination() or is_adventure()

func team_color(team: int) -> Color:
	return TEAM_COLORS.get(team, Color(1, 1, 1))

func team_name(team: int) -> String:
	return TEAM_NAMES.get(team, "Team %d" % team)

func mode_name() -> String:
	match config["mode"]:
		Mode.COOP: return "Co-op"
		Mode.TEAM_DEATHMATCH: return "Team Deathmatch"
		Mode.DOMINATION: return "Domination"
		Mode.BATTLE_ROYALE: return "Battle Royale"
		Mode.ADVENTURE: return "Adventure"
		_: return "Deathmatch"

# ---------------------------------------------------------------- adventure factions
# Each village belongs to a faction with a per-world stance toward the player
# (friendly / neutral / hostile). Raiders are hostile to everyone. Factions fight
# each other (so raiders attack villages, etc.). Stances live host-side (the AI runs
# on the host); provoking a neutral village flips it hostile.

# Default clan names used only as a last-resort fallback; each world normally gets its
# own themed faction names (LLM-invented, procedurally seeded if no LLM) via
# set_adventure_factions() before the villages spawn — see world.gd _kick_story.
const DEFAULT_VILLAGE_FACTIONS := ["Ridgeback Clan", "Verdant Pact", "Ashfall Brotherhood"]
var adventure_village_factions: Array = DEFAULT_VILLAGE_FACTIONS.duplicate()
const RAIDER_FACTION := "raiders"
const TITAN_FACTION := "titans"   # roaming giants: hostile to everyone, friendly to no one
var adventure_stance: Dictionary = {}   # faction -> "friendly" | "neutral" | "hostile"

# Parts for procedurally-seeded faction names (the offline fallback when no LLM themes
# the world). Combined as "<Prefix><Core> <Kind>", e.g. "Ashmoor Clan".
const _FAC_PREFIX := ["Iron", "Ash", "Frost", "Dust", "Ember", "Grey", "Red", "Salt", "Thorn",
	"Storm", "Rust", "Bone", "Black", "Gold", "Pale", "Night", "Sun", "Blood", "Stone", "Green"]
const _FAC_CORE := ["wake", "moor", "vale", "hold", "reach", "fall", "root", "cliff", "mere",
	"marsh", "ridge", "haven", "forge", "crest", "gate", "wood", "spire", "hollow"]
const _FAC_KIND := ["Clan", "Pact", "Host", "Kin", "Circle", "Covenant", "Order", "Band",
	"Coalition", "League", "Brotherhood", "Tribe"]

## Deterministically build `n` distinct faction names from a world seed (co-op peers and
## saves reproduce the same set). Used as the offline fallback for faction naming.
func generate_faction_names(seed_val: int, n: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val ^ 0x5AF7   # decorrelate from other seed uses
	var out: Array = []
	var guard := 0
	while out.size() < n and guard < 200:
		guard += 1
		var nm := "%s%s %s" % [_FAC_PREFIX[rng.randi() % _FAC_PREFIX.size()],
			_FAC_CORE[rng.randi() % _FAC_CORE.size()], _FAC_KIND[rng.randi() % _FAC_KIND.size()]]
		if not out.has(nm):
			out.append(nm)
	return out

## Install this world's village faction names (themed, from the generated story). Drops
## blanks / the reserved "raiders" key / duplicates and sorts them so every peer derives
## an identical ordered list (stances + team numbers stay in sync). Empty -> defaults.
func set_adventure_factions(names: Array) -> void:
	var clean: Array = []
	for n in names:
		var s := String(n).strip_edges()
		if s != "" and s.to_lower() != RAIDER_FACTION and not clean.has(s):
			clean.append(s)
	clean.sort()
	adventure_village_factions = clean if not clean.is_empty() else DEFAULT_VILLAGE_FACTIONS.duplicate()

func adventure_setup(seed_val: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	adventure_stance.clear()
	for f in adventure_village_factions:
		var r := rng.randf()
		adventure_stance[f] = "friendly" if r < 0.34 else ("neutral" if r < 0.67 else "hostile")
	adventure_stance[RAIDER_FACTION] = "hostile"

## True if faction `a` will fight faction `b`. Same faction / co-op players never.
func adventure_hostile(a: String, b: String) -> bool:
	if a == "" or b == "" or a == b:
		return false
	# Titans are hostile to every other faction (and everyone is hostile to them).
	if a == TITAN_FACTION or b == TITAN_FACTION:
		return true
	if a == RAIDER_FACTION or b == RAIDER_FACTION:
		return true
	if a == "player":
		return adventure_stance.get(b, "neutral") == "hostile"
	if b == "player":
		return adventure_stance.get(a, "neutral") == "hostile"
	return false  # village vs village: neutral by default

## A village turns hostile to the player once provoked (e.g. you shot one of them).
func adventure_provoke(faction: String) -> void:
	if faction != "" and faction != "player" and faction != RAIDER_FACTION:
		adventure_stance[faction] = "hostile"

func end_match(result: Dictionary) -> void:
	if not match_active:
		return
	match_active = false
	match_over.emit(result)
