extends Node3D
## The in-match scene. The host is authoritative: it loads the map, waits for all
## clients to report their world ready, then spawns every player + the bots and
## starts the selected mode (deathmatch or co-op mission).

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const BOT_SCENE := preload("res://scenes/bot.tscn")
const OBJECTIVE_RUNNER := preload("res://scripts/world/objective_runner.gd")
const QUEST_MANAGER := preload("res://scripts/world/quest_manager.gd")
const PICKUP_SCENE := preload("res://scenes/pickup.tscn")
var _loot_counter: int = 0

@onready var map_holder: Node3D = $MapHolder
@onready var combatants: Node3D = $Combatants
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var hud = $HUD

var _bot_counter: int = 0
var _expected_peers: Array = []
var _ready_peers: Dictionary = {}
var _begun: bool = false
var _story_done: bool = false
var _objective_runner: Node = null
var _quest_manager: Node = null
var _player_team: Dictionary = {}

# Adventure: the terrain build waits until the climate (LLM-classified from the theme,
# or keyword fallback) is resolved and broadcast, so every peer builds the same world.
var _adventure_map_path: String = ""
var _climate_resolved: bool = false
var _terrain_built: bool = false
const CLIMATE_SYS := "You label a game's setting with ONE climate word. Reply with exactly one of: temperate, frozen, desert, verdant, volcanic, isles, alpine."
const CLIMATE_KEYS := ["frozen", "desert", "verdant", "volcanic", "isles", "alpine", "temperate"]

func _ready() -> void:
	add_to_group("world")
	spawner.spawn_function = Callable(self, "_spawn_combatant")
	_load_map()
	Game.match_active = true

	if Net.is_host():
		Game.reset_scores()
		Game.score_changed.connect(_host_broadcast_scores)
		Game.kill_logged.connect(_host_on_kill)
		Game.match_over.connect(_host_on_match_over)
		_expected_peers = Net.players.keys()
		_ready_peers[1] = true
		# Adventure: resolve climate -> build terrain -> generate story, all before play.
		if Game.is_adventure():
			_begin_adventure()
		# Grace fallback (waits for the story in Adventure); hard cap regardless.
		get_tree().create_timer(5.0).timeout.connect(_grace_begin)
		get_tree().create_timer(70.0).timeout.connect(_hard_begin)
		_try_begin()
	else:
		_report_ready.rpc_id(1)
		# Adventure client: build terrain when the host broadcasts the climate; if it
		# never arrives, fall back so we don't hang on an empty world.
		if Game.is_adventure():
			get_tree().create_timer(30.0).timeout.connect(func(): _apply_climate(String(Game.config.get("climate", ""))))

func _load_map() -> void:
	var map_path: String = Game.config["map"]
	if Game.is_coop():
		var m := Missions.get_mission(Game.config.get("mission_id", ""))
		if not m.is_empty():
			map_path = m["map"]
	if not ResourceLoader.exists(map_path):
		map_path = "res://maps/arena.tscn"
	if Game.is_adventure():
		# Defer: built in _build_adventure_terrain once the climate is resolved so the
		# theme can shape the world (and every peer builds it identically).
		_adventure_map_path = map_path
		return
	var map: Node = load(map_path).instantiate()
	map_holder.add_child(map)

func _build_adventure_terrain() -> void:
	if _terrain_built:
		return
	_terrain_built = true
	var map: Node = load(_adventure_map_path).instantiate()
	map_holder.add_child(map)

# ---------------------------------------------------------------- start handshake

@rpc("any_peer", "reliable")
func _report_ready() -> void:
	if not Net.is_host():
		return
	_ready_peers[multiplayer.get_remote_sender_id()] = true
	_try_begin()

func _try_begin() -> void:
	if _begun or not Net.is_host():
		return
	# Begin as soon as every expected peer has reported its world ready.
	# (The 5s grace timer in _ready() calls _begin() directly as a fallback.)
	for pid in _expected_peers:
		if not _ready_peers.has(pid):
			return
	if Game.is_adventure() and not _story_done:
		return  # hold gameplay until the story has been generated
	_begin()

## Grace-timer entry: don't start Adventure until its story is ready.
func _grace_begin() -> void:
	if Game.is_adventure() and not _story_done:
		return
	_begin()

## Adventure loading (host): classify the theme's climate -> build terrain -> story.
func _begin_adventure() -> void:
	if not Story.story_ready.is_connected(_on_story_ready):
		Story.story_ready.connect(_on_story_ready)
	if not Story.phase_changed.is_connected(_on_story_phase):
		Story.phase_changed.connect(_on_story_phase)
	_set_loading_text.rpc(_loading("Preparing the world\u2026"))
	var theme := String(Game.config.get("theme", "")).strip_edges()
	# Only classify when the model is already downloaded \u2014 otherwise terrain would wait
	# on a big first-run download. First adventure uses keyword climate; later ones LLM.
	if theme != "" and LLM.embedded_ready():
		_set_loading_text.rpc(_loading("Reading the omens\u2026"))
		LLM.chat_done.connect(_on_climate_done, CONNECT_ONE_SHOT)
		if not LLM.chat(CLIMATE_SYS, "Setting / theme: \"%s\". Which one climate word fits it best?" % theme):
			_apply_climate.rpc("")
		else:
			get_tree().create_timer(8.0).timeout.connect(_climate_timeout)
	else:
		_apply_climate.rpc("")

func _on_climate_done(text: String) -> void:
	var t := text.strip_edges().to_lower()
	var key := ""
	for k in CLIMATE_KEYS:
		if t.find(k) >= 0:
			key = k
			break
	_apply_climate.rpc(key)

func _climate_timeout() -> void:
	if not _climate_resolved:
		_apply_climate.rpc("")   # LLM too slow \u2014 fall back to keyword/temperate

## Lock in the climate on every peer, build the terrain, then (host) kick the story.
@rpc("authority", "call_local", "reliable")
func _apply_climate(key: String) -> void:
	if _climate_resolved:
		return
	_climate_resolved = true
	if key != "":
		Game.config["climate"] = key
	_build_adventure_terrain()
	if Net.is_host():
		_start_story_generation()

func _start_story_generation() -> void:
	# Download the model (with progress) if needed, then generate the story.
	if LLM.embedded_available() and not LLM.has_model():
		LLM.model_ready.connect(_on_model_ready, CONNECT_ONE_SHOT)
		LLM.download_progress.connect(_on_model_progress)
		LLM.ensure_model()
	else:
		_kick_story()

func _on_model_ready(_ok: bool) -> void:
	if LLM.download_progress.is_connected(_on_model_progress):
		LLM.download_progress.disconnect(_on_model_progress)
	_set_loading_text.rpc(_loading("Loading the AI model\u2026"))
	_kick_story()

func _on_model_progress(frac: float) -> void:
	_set_loading_text.rpc(_loading("Downloading AI model\u2026  %d%%" % int(frac * 100.0)))

func _on_story_phase(text: String) -> void:
	_set_loading_text.rpc(_loading(text))

## Compose a loading-screen message: a context header (world size + theme) + phase.
func _loading(phase: String) -> String:
	var sizes := ["Tiny", "Small", "Medium", "Large"]
	var head := "Adventure \u2014 %s world" % sizes[clampi(int(Game.config.get("map_size", 2)), 0, 3)]
	var theme := String(Game.config.get("theme", "")).strip_edges()
	if theme != "":
		head += " \u00b7 \"%s\"" % theme
	var ai := _ai_label()
	if ai != "":
		head += "\n" + ai
	return "%s\n%s" % [head, phase]

## Which AI model is generating the world, for the loading screen. The on-device
## (llama.cpp) model when embedded; otherwise the local LLM server fallback.
func _ai_label() -> String:
	if LLM.embedded_available() and (LLM.has_model() or LLM.downloading):
		return "AI model: %s (on-device)" % LLM.model_name()
	return "AI model: local LLM server"

func _kick_story() -> void:
	var sfacs := (Game.ADVENTURE_VILLAGE_FACTIONS as Array).duplicate()
	sfacs.append(Game.RAIDER_FACTION)
	var hero := {}
	if Characters.has_current():
		hero = {"name": String(Characters.current.get("name", "")), "bio": String(Characters.current.get("backstory", ""))}
	Story.generate(String(Game.config.get("theme", "")), {"factions": sfacs, "points": int(Game.config.get("mission_points", 10)), "names_per_faction": 16, "hero": hero})

## Grace fallback that keeps waiting while the AI model is still downloading.
func _hard_begin() -> void:
	if Game.is_adventure() and LLM.downloading:
		get_tree().create_timer(20.0).timeout.connect(_hard_begin)
		return
	if Game.is_adventure() and not _terrain_built:
		_apply_climate(String(Game.config.get("climate", "")))   # safety: never begin without terrain
	_begin()

@rpc("authority", "call_local", "reliable")
func _set_loading_text(t: String) -> void:
	if hud and hud.has_method("set_loading_text"):
		hud.set_loading_text(t)

func _begin() -> void:
	if _begun:
		return
	_begun = true
	if Game.is_team_deathmatch() or Game.is_domination():
		_assign_teams()
	# Spawn a player for every connected peer.
	for pid in Net.players.keys():
		_spawn_player(pid)
	if Game.is_coop():
		_start_coop()
	elif Game.is_team_deathmatch():
		_start_team_deathmatch()
	elif Game.is_domination():
		_start_domination()
	elif Game.is_battle_royale():
		_start_battle_royale()
	elif Game.is_adventure():
		_start_survival()
	else:
		_start_deathmatch()

func _assign_teams() -> void:
	# Alternate connected peers between the two teams for rough balance.
	var ids := Net.players.keys()
	ids.sort()
	for i in ids.size():
		_player_team[ids[i]] = i % 2

# ---------------------------------------------------------------- spawning

func _spawn_player(peer_id: int) -> void:
	var team: int
	if Game.is_coop() or Game.is_adventure():
		team = Game.TEAM_PLAYERS
	elif Game.is_team_deathmatch() or Game.is_domination():
		team = _player_team.get(peer_id, 0)
	else:
		team = peer_id  # FFA: unique team
	var xform := get_spawn_transform(false)
	Game.register_combatant(peer_id, Net.get_player_name(peer_id), false, team)
	spawner.spawn({
		"type": "player",
		"id": peer_id,
		"team": team,
		"name": Net.get_player_name(peer_id),
		"pos": xform.origin,
	})

func spawn_enemy(skill: float, respawns: bool, at: Vector3 = Vector3.INF, etype: String = "", team_override: int = -999, faction: String = "", extra: Dictionary = {}) -> int:
	_bot_counter += 1
	var id := -1000 - _bot_counter
	var team: int
	if team_override != -999:
		team = team_override
	elif Game.is_coop() or Game.is_adventure():
		team = Game.TEAM_ENEMIES
	else:
		team = id  # FFA: unique team
	var pos := at
	if pos == Vector3.INF:
		pos = get_spawn_transform(true).origin
	if etype == "":
		etype = _random_enemy_type()
	var nm: String = String(extra.get("name", "Bot %d" % _bot_counter))
	Game.register_combatant(id, nm, true, team)
	spawner.spawn({
		"type": "bot",
		"id": id,
		"team": team,
		"name": nm,
		"skill": skill,
		"respawns": respawns,
		"pos": pos,
		"etype": etype,
		"faction": faction,
		"role": String(extra.get("role", "")),
		"persona": String(extra.get("persona", "")),
	})
	return id

const BOT_SCRIPT := preload("res://scripts/ai/bot.gd")
const TARGET_SCRIPT := preload("res://scripts/world/destructible_target.gd")
const ESCORT_SCRIPT := preload("res://scripts/world/escort_marker.gd")
const STORM_SCRIPT := preload("res://scripts/world/storm.gd")

func _random_enemy_type() -> String:
	var weights: Dictionary = BOT_SCRIPT.SPAWN_WEIGHTS
	var total := 0
	for k in weights:
		total += int(weights[k])
	var r := randi() % maxi(total, 1)
	for k in weights:
		r -= int(weights[k])
		if r < 0:
			return k
	return "soldier"

## Runs on every peer (via MultiplayerSpawner) to construct the node from data.
func _spawn_combatant(data: Dictionary) -> Node:
	match String(data["type"]):
		"player":
			var p := PLAYER_SCENE.instantiate()
			p.name = "P%d" % int(data["id"])
			p.combatant_id = int(data["id"])
			p.team = int(data["team"])
			p.display_name = String(data["name"])
			p.position = data["pos"]
			p.set_multiplayer_authority(int(data["id"]))
			return p
		"target":
			var t: Node3D = TARGET_SCRIPT.new()
			t.name = "T%d" % absi(int(data["id"]))
			t.position = data["pos"]
			t.setup(int(data["id"]), float(data["health"]))
			return t
		"escort":
			var e: Node3D = ESCORT_SCRIPT.new()
			e.name = "E%d" % absi(int(data["id"]))
			e.position = data["pos"]
			e.setup(int(data["id"]), data["dest"], float(data["speed"]))
			return e
		_:
			var b := BOT_SCENE.instantiate()
			b.name = "B%d" % absi(int(data["id"]))
			b.position = data["pos"]
			# Authority stays with the host (default), which drives the AI.
			b.configure(int(data["id"]), int(data["team"]), float(data["skill"]), bool(data["respawns"]), String(data["name"]), String(data.get("etype", "soldier")), String(data.get("faction", "")))
			b.role = String(data.get("role", ""))
			b.persona = String(data.get("persona", ""))
			if Net.is_host():
				b.died.connect(_on_bot_died)
			return b

## Host-only: spawn a destructible objective target (replicated). Returns the node.
func spawn_target(pos: Vector3, health: float) -> Node:
	_bot_counter += 1
	var id := -3000 - _bot_counter
	return spawner.spawn({"type": "target", "id": id, "pos": pos, "health": health})

## Host-only: spawn an escort VIP that walks from its spawn to `dest`. Returns the node.
func spawn_escort(from: Vector3, dest: Vector3, speed: float) -> Node:
	_bot_counter += 1
	var id := -4000 - _bot_counter
	return spawner.spawn({"type": "escort", "id": id, "pos": from, "dest": dest, "speed": speed})

func _on_bot_died(attacker_id: int, victim_id: int) -> void:
	if _objective_runner and _objective_runner.has_method("notify_enemy_killed"):
		_objective_runner.notify_enemy_killed(victim_id)
	if _quest_manager:
		_quest_manager.notify_kill(victim_id, attacker_id)
	if Game.is_adventure():
		_maybe_drop_loot(victim_id)
	check_last_standing()

## Adventure: a killed NPC sometimes drops loot (often armor) where it fell.
func _maybe_drop_loot(victim_id: int) -> void:
	if randf() > 0.3:
		return
	var b: Node = null
	for n in get_tree().get_nodes_in_group("bot"):
		if n.combatant_id == victim_id:
			b = n
			break
	if b == null:
		return
	_loot_counter += 1
	var pos: Vector3 = b.global_position + Vector3(0, 0.6, 0)
	var kind := "ammo"
	var subtype := ""
	var roll := randf()
	if roll < 0.5:
		kind = "armor"
		subtype = String(ItemDB.ARMOR_IDS[randi() % ItemDB.ARMOR_IDS.size()])
	elif roll < 0.7:
		kind = "health"
	elif roll < 0.85:
		kind = "grenade"
	_spawn_loot.rpc(_loot_counter, pos, kind, subtype)

@rpc("authority", "call_local", "reliable")
func _spawn_loot(idx: int, pos: Vector3, kind: String, subtype: String) -> void:
	var p := PICKUP_SCENE.instantiate()
	p.name = "Loot_%d" % idx
	p.kind = kind
	if subtype != "":
		p.weapon_id = subtype
	if kind == "health":
		p.amount = 50
	get_tree().current_scene.add_child(p)
	p.global_position = pos

## Host-only: spill `n` pieces of mixed loot around a point (treasure caches, rewards).
func drop_loot_at(pos: Vector3, n: int) -> void:
	if not Net.is_host():
		return
	for i in n:
		_loot_counter += 1
		var kind: String = ["weapon", "armor", "health", "ammo"][randi() % 4]
		var subtype := ""
		if kind == "weapon":
			subtype = ["rifle", "shotgun", "smg", "sniper", "pistol"][randi() % 5]
		elif kind == "armor":
			subtype = String(ItemDB.ARMOR_IDS[randi() % ItemDB.ARMOR_IDS.size()])
		var off := Vector3(randf_range(-1.4, 1.4), 0.5, randf_range(-1.4, 1.4))
		_spawn_loot.rpc(_loot_counter, pos + off, kind, subtype)

# ---------------------------------------------------------------- modes

# ---------------------------------------------------------------- adventure

const SURVIVAL_ACT_DIST := 110.0   # NPCs beyond this from every player freeze (no AI)
var _survival_rng := RandomNumberGenerator.new()
var _surv_act_t := 0.0

func _start_survival() -> void:
	# (No generic banner \u2014 the LLM briefing set in _on_story_ready stays as the intro.)
	Game.adventure_setup(int(Game.config.get("seed", 0)))
	NameGen.reseed(int(Game.config.get("seed", 0)))
	_survival_rng.seed = int(Game.config.get("seed", 0))
	var pois := get_tree().get_nodes_in_group("poi_site")
	var skill := float(Game.config["bot_skill"])
	var faction_team := {Game.RAIDER_FACTION: 1}
	var next_team := 2
	var factions: Array = Game.ADVENTURE_VILLAGE_FACTIONS
	# Populate each village (POI) with defenders of its faction.
	for i in pois.size():
		var poi: Node3D = pois[i]
		var fac: String = String(factions[i % factions.size()])
		if i == 0:
			Game.adventure_stance[fac] = "friendly"   # the start village is safe
		if not faction_team.has(fac):
			faction_team[fac] = next_team
			next_team += 1
		var team: int = int(faction_team[fac])
		var radius: float = float(poi.get_meta("radius", 24.0))
		for d in _survival_rng.randi_range(10, 16):
			var ang := _survival_rng.randf() * TAU
			var rr := _survival_rng.randf_range(2.0, radius)
			var pos := poi.global_position + Vector3(cos(ang) * rr, 1.0, sin(ang) * rr)
			var drole := "Elder" if d == 0 else ("Quartermaster" if d == 1 else "Guard")
			var dperson := NameGen.npc_person(fac)
			spawn_enemy(skill, false, pos, "", team, fac, {"name": dperson["name"], "role": drole, "persona": dperson["trait"]})
	# Roaming raiders scattered around the settlements (emergent clashes).
	for r in pois.size() * 10:
		if pois.is_empty():
			break
		var poi: Node3D = pois[_survival_rng.randi() % pois.size()]
		var radius: float = float(poi.get_meta("radius", 24.0))
		var ang := _survival_rng.randf() * TAU
		var rr := radius * _survival_rng.randf_range(1.8, 3.2)
		var x := poi.global_position.x + cos(ang) * rr
		var z := poi.global_position.z + sin(ang) * rr
		var y := _ground_y(x, z, poi.global_position.y) + 1.0
		# Snap onto the navmesh so raiders never land off-map, in the sea, or on a peak.
		var spot := _snap_to_nav(Vector3(x, y, z))
		spot.y += 1.0
		var rrole := "Raid Boss" if r % 8 == 0 else "Raider"
		var rperson := NameGen.npc_person(Game.RAIDER_FACTION)
		spawn_enemy(skill, false, spot, _random_enemy_type(), 1, Game.RAIDER_FACTION, {"name": rperson["name"], "role": rrole, "persona": rperson["trait"]})
	set_process(true)
	# Quests reference the villages/NPCs we just spawned, so build them last.
	_quest_manager = QUEST_MANAGER.new()
	_quest_manager.name = "QuestManager"
	add_child(_quest_manager)
	_quest_manager.start(self)

func _on_story_ready(s: Dictionary) -> void:
	NameGen.set_pools(s.get("names", {}))
	_sync_story.rpc(s)
	var briefing := String(s.get("briefing", ""))
	if briefing != "":
		set_objective_text.rpc(briefing)
	_set_loading_text.rpc(_loading("Populating the villages\u2026"))
	_story_done = true
	_try_begin()

@rpc("authority", "call_local", "reliable")
func _sync_story(s: Dictionary) -> void:
	Game.story = s

## World height at (x, z) via a downward ray; falls back to `approx`.
func _ground_y(x: float, z: float, approx: float) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, approx + 80.0, z), Vector3(x, approx - 200.0, z))
	q.collision_mask = 1
	var r := space.intersect_ray(q)
	return r.position.y if r else approx

## Pull a position onto the baked navmesh (nearest walkable point) so spawns never
## land off-map, in water, or on an unreachable slope.
func _snap_to_nav(pos: Vector3) -> Vector3:
	var reg := get_tree().get_first_node_in_group("nav_region")
	if reg == null or not (reg is NavigationRegion3D):
		return pos
	var navmap: RID = reg.get_navigation_map()
	if not NavigationServer3D.map_is_active(navmap):
		return pos
	return NavigationServer3D.map_get_closest_point(navmap, pos)

## Freeze NPCs that are far from every living player so only nearby ones think.
func _process_survival(delta: float) -> void:
	_surv_act_t += delta
	if _surv_act_t < 0.5:
		return
	_surv_act_t = 0.0
	var pps: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead") and not p.get("fully_dead"):
			pps.append(p.global_position)
	for b in get_tree().get_nodes_in_group("bot"):
		var near := false
		for pp in pps:
			if b.global_position.distance_to(pp) < SURVIVAL_ACT_DIST:
				near = true
				break
		b.set_active(near)
	_maybe_ambush(delta, pps)

# World event: every so often a small raider party ambushes a random player, for
# emergent encounters between missions.
var _ambush_t: float = 0.0
func _maybe_ambush(delta: float, player_positions: Array) -> void:
	if not Net.is_host() or player_positions.is_empty():
		return
	_ambush_t += delta + 0.5   # _process_survival ticks ~2x/sec; this accumulates wall time
	if _ambush_t < _survival_rng.randf_range(80.0, 140.0):
		return
	_ambush_t = 0.0
	var center: Vector3 = player_positions[_survival_rng.randi() % player_positions.size()]
	var skill := float(Game.config.get("bot_skill", 1.0))
	var n := _survival_rng.randi_range(2, 4)
	for i in n:
		var ang := _survival_rng.randf() * TAU
		var pos := _snap_to_nav(center + Vector3(cos(ang), 0, sin(ang)) * _survival_rng.randf_range(18.0, 30.0))
		pos.y += 1.0
		spawn_enemy(skill, false, pos, _random_enemy_type(), 1, Game.RAIDER_FACTION)
	broadcast_event("⚠ Raider ambush!")

func _start_deathmatch() -> void:
	set_objective_text.rpc("Deathmatch — first to %d frags" % int(Game.config["frag_limit"]))
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true)

func _start_team_deathmatch() -> void:
	set_objective_text.rpc("Team Deathmatch — %s vs %s, first to %d" % [
		Game.team_name(0), Game.team_name(1), int(Game.config["frag_limit"])])
	# Fill both teams with bots, alternating.
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true, Vector3.INF, "", i % 2)

# ---------------------------------------------------------------- domination

const DOM_CAP_RATE := 0.4
var _dom_score_t := 0.0
var _dom_sync_t := 0.0

func _start_domination() -> void:
	set_objective_text.rpc("Domination — hold the points to score, first to %d" % Game.DOM_LIMIT)
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), true, Vector3.INF, "", i % 2)
	set_process(true)

func _process(delta: float) -> void:
	if not Net.is_host() or not Game.match_active:
		return
	if Game.is_domination():
		_process_domination(delta)
	elif Game.is_battle_royale():
		_process_storm(delta)
	elif Game.is_adventure():
		_process_survival(delta)

func _process_domination(delta: float) -> void:
	_dom_sync_t += delta
	var broadcast := _dom_sync_t >= 0.25
	if broadcast:
		_dom_sync_t = 0.0
	for cp in get_tree().get_nodes_in_group("control_point"):
		var counts: Array = cp.team_counts()
		var blue: int = counts[0]
		var red: int = counts[1]
		if blue > 0 and red == 0:
			cp.bar = minf(1.0, cp.bar + DOM_CAP_RATE * delta)
		elif red > 0 and blue == 0:
			cp.bar = maxf(-1.0, cp.bar - DOM_CAP_RATE * delta)
		if cp.bar >= 0.99:
			cp.owner_team = 0
		elif cp.bar <= -0.99:
			cp.owner_team = 1
		else:
			cp.owner_team = -1
		if broadcast:
			cp.set_state.rpc(cp.bar, cp.owner_team)
	_dom_score_t += delta
	if _dom_score_t >= 1.0:
		_dom_score_t = 0.0
		for cp in get_tree().get_nodes_in_group("control_point"):
			if cp.owner_team >= 0:
				Game.add_dom_point(cp.owner_team)
		_sync_dom.rpc(Game.dom_score.duplicate())

@rpc("authority", "call_local", "reliable")
func _sync_dom(scores_arr: Array) -> void:
	if not Net.is_host():
		Game.dom_score = scores_arr
		Game.dom_changed.emit()

# ---------------------------------------------------------------- battle royale

# Safe-zone radii (m) per phase and the storm damage/sec while outside it.
const STORM_RADII := [230.0, 150.0, 90.0, 50.0, 22.0, 8.0]
const STORM_DPS := [1.0, 2.0, 3.0, 5.0, 8.0, 12.0]
const STORM_FIRST_HOLD := 18.0   # grace before the first shrink
const STORM_HOLD := 14.0         # pause between shrinks
const STORM_SHRINK := 18.0       # time to close from one ring to the next

var _storm: Node3D = null
var _storm_phase: int = 0
var _storm_state: String = "hold"   # "hold" | "shrink"
var _storm_from: float = 0.0
var _storm_to: float = 0.0
var _storm_cur: float = 0.0
var _storm_dps: float = 1.0
var _storm_t: float = 0.0
var _storm_dmg_accum: float = 0.0
var _br_sync_t: float = 0.0

func _start_battle_royale() -> void:
	set_objective_text.rpc("⚠ BATTLE ROYALE — last one standing wins. Stay inside the storm wall!")
	# Free-for-all: every bot is its own team, and nobody respawns.
	var n: int = int(Game.config["bot_count"])
	for i in n:
		spawn_enemy(float(Game.config["bot_skill"]), false)
	# Spin up the shrinking storm centred on the map origin.
	_storm = STORM_SCRIPT.new()
	_storm.name = "Storm"
	add_child(_storm)
	_storm_cur = STORM_RADII[0]
	_storm_from = _storm_cur
	_storm_to = _storm_cur
	_storm_dps = STORM_DPS[0]
	_storm_phase = 0
	_storm_state = "hold"
	_storm_t = 0.0
	_storm.set_center(Vector3.ZERO)
	_storm.set_radius(_storm_cur)
	_sync_storm.rpc(Vector3.ZERO, _storm_cur)
	set_process(true)

func _process_storm(delta: float) -> void:
	if _storm == null:
		return
	_storm_t += delta
	if _storm_state == "shrink":
		var k: float = clampf(_storm_t / STORM_SHRINK, 0.0, 1.0)
		_storm_cur = lerpf(_storm_from, _storm_to, k)
		if k >= 1.0:
			_storm_cur = _storm_to
			_storm_state = "hold"
			_storm_t = 0.0
	else:  # holding
		var hold: float = STORM_FIRST_HOLD if _storm_phase == 0 else STORM_HOLD
		if _storm_t >= hold and _storm_phase < STORM_RADII.size() - 1:
			_storm_phase += 1
			_storm_from = _storm_cur
			_storm_to = STORM_RADII[_storm_phase]
			_storm_dps = STORM_DPS[_storm_phase]
			_storm_state = "shrink"
			_storm_t = 0.0
	_storm.set_radius(_storm_cur)

	# Tick storm damage to everyone caught outside the ring (once a second).
	_storm_dmg_accum += delta
	if _storm_dmg_accum >= 1.0:
		_storm_dmg_accum = 0.0
		_apply_storm_damage(_storm_dps)

	# Replicate the ring + HUD banner to clients a few times a second.
	_br_sync_t += delta
	if _br_sync_t >= 0.4:
		_br_sync_t = 0.0
		_sync_storm.rpc(_storm.global_position, _storm_cur)
		set_objective_text.rpc(_storm_banner())
		check_last_standing()

func _apply_storm_damage(dps: float) -> void:
	for c in get_tree().get_nodes_in_group("combatant"):
		if not is_instance_valid(c) or c.get("dead") or c.get("fully_dead"):
			continue
		if _storm.is_outside(c.global_position) and c.has_method("hit"):
			c.hit(dps, -1)

func _storm_banner() -> String:
	var alive: int = _count_alive_combatants()
	var note: String
	if _storm_state == "shrink":
		note = "Storm closing!"
	elif _storm_phase < STORM_RADII.size() - 1:
		var hold: float = STORM_FIRST_HOLD if _storm_phase == 0 else STORM_HOLD
		note = "Storm shrinks in %ds" % max(0, int(ceil(hold - _storm_t)))
	else:
		note = "Final ring"
	return "⚠ %s   —   Alive: %d" % [note, alive]

@rpc("authority", "call_local", "reliable")
func _sync_storm(center: Vector3, radius: float) -> void:
	if _storm == null:
		_storm = STORM_SCRIPT.new()
		_storm.name = "Storm"
		add_child(_storm)
	_storm.set_center(center)
	_storm.set_radius(radius)

func _count_alive_combatants() -> int:
	var n := 0
	for c in get_tree().get_nodes_in_group("combatant"):
		if is_instance_valid(c) and not c.get("dead") and not c.get("fully_dead"):
			n += 1
	return n

## Host: end the battle royale the moment one (or zero) combatants remain alive.
func check_last_standing() -> void:
	if not Net.is_host() or not Game.is_battle_royale() or not Game.match_active:
		return
	var alive: Array = []
	for c in get_tree().get_nodes_in_group("combatant"):
		if is_instance_valid(c) and not c.get("dead") and not c.get("fully_dead"):
			alive.append(c)
	if alive.size() <= 1:
		var winner_id: int = int(alive[0].get("combatant_id")) if alive.size() == 1 else 0
		Game.end_match({"reason": "last_standing", "winner": winner_id})

func _start_coop() -> void:
	var mission := Missions.get_mission(Game.config.get("mission_id", ""))
	if mission.is_empty():
		set_objective_text.rpc("No mission loaded.")
		return
	_set_lives.rpc(int(mission.get("lives", 6)))
	_objective_runner = OBJECTIVE_RUNNER.new()
	_objective_runner.name = "ObjectiveRunner"
	add_child(_objective_runner)
	_objective_runner.start(self, mission)

# ---------------------------------------------------------------- co-op lives

@rpc("authority", "call_local", "reliable")
func _set_lives(n: int) -> void:
	Game.coop_lives = n
	Game.lives_changed.emit(n)

## A downed player bled out and asks the host for a shared life.
@rpc("any_peer", "reliable")
func request_life(victim_id: int) -> void:
	if not Net.is_host():
		return
	var granted := Game.coop_lives > 0
	if granted:
		Game.coop_lives -= 1
	_life_result.rpc(victim_id, granted, Game.coop_lives)

@rpc("authority", "call_local", "reliable")
func _life_result(victim_id: int, granted: bool, lives: int) -> void:
	Game.coop_lives = lives
	Game.lives_changed.emit(lives)
	var p := _player_by_id(victim_id)
	if p and p.is_multiplayer_authority():
		p.apply_life_result(granted)
	if Net.is_host():
		check_coop_wipe()

func _player_by_id(id: int) -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p.combatant_id == id:
			return p
	return null

## Host: mission fails if no one can act and there are no lives left to recover.
func check_coop_wipe() -> void:
	if not Net.is_host() or not Game.is_coop() or not Game.match_active:
		return
	if Game.coop_lives > 0:
		return
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead") and not p.get("downed") and not p.get("fully_dead"):
			return  # someone is still up
	Game.end_match({"reason": "mission_failed"})

# ---------------------------------------------------------------- helpers

func get_spawn_transform(prefer_enemy: bool) -> Transform3D:
	var group := "spawn_enemy" if prefer_enemy else "spawn_player"
	var markers := get_tree().get_nodes_in_group(group)
	if markers.is_empty():
		markers = get_tree().get_nodes_in_group("spawn_player")
	if markers.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	# Pick the marker farthest from any living combatant so two bodies never
	# spawn on top of each other (overlapping capsules get violently ejected
	# upward by depenetration). Random order breaks ties / adds variety.
	markers.shuffle()
	var combatants := get_tree().get_nodes_in_group("combatant")
	var best: Node3D = markers[0]
	var best_clearance := -1.0
	for m in markers:
		var nearest := INF
		for c in combatants:
			if not is_instance_valid(c) or c.get("dead"):
				continue
			nearest = minf(nearest, m.global_position.distance_to(c.global_position))
		if nearest > best_clearance:
			best_clearance = nearest
			best = m
	var t := best.global_transform
	# Small horizontal jitter + slight lift so simultaneous spawns never coincide.
	t.origin += Vector3(randf_range(-0.7, 0.7), 0.3, randf_range(-0.7, 0.7))
	t.basis = Basis.IDENTITY
	return t

func count_alive_enemies() -> int:
	var c := 0
	for b in get_tree().get_nodes_in_group("bot"):
		if not b.get("dead"):
			c += 1
	return c

func alive_players() -> Array:
	var out: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead"):
			out.append(p)
	return out

# ---------------------------------------------------------------- replicated UI

@rpc("authority", "call_local", "reliable")
func set_objective_text(t: String) -> void:
	if hud and hud.has_method("set_objective"):
		hud.set_objective(t)

func broadcast_objective(t: String) -> void:
	if Net.is_host():
		set_objective_text.rpc(t)

func broadcast_quests(t: String) -> void:
	if Net.is_host():
		set_quest_text.rpc(t)

@rpc("authority", "call_local", "reliable")
func set_quest_text(t: String) -> void:
	if hud and hud.has_method("set_quest_tracker"):
		hud.set_quest_tracker(t)

## Push an event-log line to every HUD. A non-empty `banner` also pops a celebration
## banner (used for quest completions).
func broadcast_event(line: String, banner: String = "") -> void:
	if Net.is_host():
		_event_feed.rpc(line, banner)

@rpc("authority", "call_local", "reliable")
func _event_feed(line: String, banner: String) -> void:
	if hud and hud.has_method("add_event"):
		hud.add_event(line)
	if banner != "" and hud and hud.has_method("celebrate"):
		hud.celebrate(banner)

## A player accepts an NPC's side quest (routed to the host).
@rpc("any_peer", "call_local", "reliable")
func accept_quest(quest_id: int) -> void:
	if Net.is_host() and _quest_manager:
		_quest_manager.accept(quest_id)

func _host_broadcast_scores() -> void:
	_recv_scores.rpc(Game.scores)

@rpc("authority", "call_local", "reliable")
func _recv_scores(data: Dictionary) -> void:
	if not Net.is_host():
		Game.scores = data
		Game.score_changed.emit()

func _host_on_kill(killer_id: int, victim_id: int) -> void:
	var killer: String = Game.scores.get(killer_id, {}).get("name", "?")
	var victim: String = Game.scores.get(victim_id, {}).get("name", "?")
	var kt: int = int(Game.scores.get(killer_id, {}).get("team", -1))
	var vt: int = int(Game.scores.get(victim_id, {}).get("team", -1))
	var suicide := killer_id == victim_id
	_kill_feed.rpc(killer, victim, suicide, kt, vt)

@rpc("authority", "call_local", "reliable")
func _kill_feed(killer: String, victim: String, suicide: bool, killer_team: int, victim_team: int) -> void:
	if hud and hud.has_method("add_kill_feed"):
		hud.add_kill_feed(killer, victim, suicide, killer_team, victim_team)

# ---------------------------------------------------------------- match end

func _host_on_match_over(result: Dictionary) -> void:
	_show_result.rpc(result)

@rpc("authority", "call_local", "reliable")
func _show_result(result: Dictionary) -> void:
	Game.match_active = false
	# Adventure: save the local character's gear + run stats into their profile.
	if Game.is_adventure() and Characters.has_current():
		Characters.capture_from_player(_local_player())
	if hud and hud.has_method("show_result"):
		hud.show_result(result)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await get_tree().create_timer(3.0).timeout
	_leave_to_menu()

func _local_player() -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p.is_multiplayer_authority():
			return p
	return null

func _leave_to_menu() -> void:
	Net.disconnect_net()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
