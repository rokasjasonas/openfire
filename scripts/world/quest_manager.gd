extends Node
## Host-only Adventure quest system — fully dynamic. You spawn with NOTHING assigned:
## village Elders hold a few offers, new offers trickle in over time (stance-driven:
## friendly factions give more/better work, hostile ones none), unaccepted offers
## expire, some active missions can fail (timed delivery, distress calls), and urgent
## distress events pop up mid-run. Reaching the point target is a milestone, not an
## ending. Quest types: reach, collect, deliver, hunt, defend, recon, escort,
## assassinate, clear_camp, sabotage, rescue, holdout, treasure, courier, distress.

## Base point value per quest type (before the difficulty bonus).
const PTS := {
	"reach": 1, "collect": 2, "deliver": 2, "hunt": 2, "defend": 2, "recon": 2,
	"treasure": 2, "escort": 3, "assassinate": 3, "clear_camp": 3, "sabotage": 3,
	"rescue": 3, "holdout": 3, "courier": 3, "distress": 3,
}

# Per-mission difficulty: 0 Easy, 1 Normal, 2 Hard. Each level adds 1 point of reward,
# scales required amounts, and (for combat quests) spawns extra raider reinforcements
# at the objective. The menu Easy/Normal/Hard stays a flat multiplier on enemy skill.
const DIFF_NAMES := ["Easy", "Normal", "Hard"]

# Dynamics tuning.
const INITIAL_OFFERS := 3      # offers seeded at world start (you still must go ask)
const MAX_AVAILABLE := 5       # cap on outstanding unaccepted offers
const TRICKLE_SECS := 90.0     # a new offer appears roughly this often
const OFFER_TTL := 300.0       # unaccepted offers expire after this long
const DISTRESS_SECS := 240.0   # roughly how often a distress call can fire

var world: Node
var target_points: int = 10
var points: int = 0
var quests: Array = []
var _next_id: int = 0
var _won: bool = false
var _rng := RandomNumberGenerator.new()
var _type_counter: int = 0
var _trickle_t: float = 0.0
var _distress_t: float = 0.0

func start(w: Node) -> void:
	world = w
	add_to_group("quest_manager")
	target_points = maxi(1, int(Game.config.get("mission_points", 10)))
	_rng.seed = int(Game.config.get("seed", 0)) + 7
	# No mission is assigned at spawn — Elders hold a few offers; go talk to them.
	for i in INITIAL_OFFERS:
		_new_offer()
	set_process(true)
	_broadcast()

# ---------------------------------------------------------------- generation

func _make(type: String, title: String, desc: String, extra: Dictionary, main := false, giver := 0, diff := 1) -> int:
	diff = clampi(diff, 0, 2)
	var q := {
		"id": _next_id, "type": type, "title": title, "desc": desc,
		"points": int(PTS.get(type, 2)) + diff, "difficulty": diff,
		"state": "available", "main": main, "giver": giver, "progress": 0,
		"_timer": 0.0, "_age": 0.0,
	}
	q.merge(extra)
	quests.append(q)
	_next_id += 1
	return q["id"]

func difficulty_label(q: Dictionary) -> String:
	return DIFF_NAMES[clampi(int(q.get("difficulty", 1)), 0, 2)]

func _pois() -> Array:
	var arr := get_tree().get_nodes_in_group("poi_site")
	arr.sort_custom(func(a, b): return int(a.get_meta("index", 0)) < int(b.get_meta("index", 0)))
	return arr

func _stance_of(faction: String) -> String:
	return String(Game.adventure_stance.get(faction, "neutral"))

## Elders who will deal with you (hostile factions offer nothing until appeased).
func _eligible_elders() -> Array:
	var out: Array = []
	for b in get_tree().get_nodes_in_group("bot"):
		if not b.get("dead") and b.role == "Elder" and _stance_of(b.faction) != "hostile":
			out.append(b)
	return out

func _available_count() -> int:
	var n := 0
	for q in quests:
		if q["state"] == "available":
			n += 1
	return n

## Create one new offer on an eligible Elder. Friendly factions hand out harder,
## better-paying work; neutral ones easier errands. Returns the quest id or -1.
func _new_offer() -> int:
	var pois := _pois()
	var elders := _eligible_elders()
	if elders.is_empty():
		return -1
	var giver: Node = elders[_rng.randi() % elders.size()]
	var gid: int = giver.combatant_id
	# Stance-driven difficulty: friendly -> Normal/Hard, neutral -> Easy/Normal.
	var d := (1 + _rng.randi() % 2) if _stance_of(giver.faction) == "friendly" else (_rng.randi() % 2)
	var bosses: Array = []
	for b in get_tree().get_nodes_in_group("bot"):
		if not b.get("dead") and b.role == "Raid Boss":
			bosses.append(b)
	var types := ["collect", "deliver", "hunt", "recon", "assassinate", "escort",
		"clear_camp", "sabotage", "rescue", "holdout", "treasure", "courier"]
	var t: String = types[_type_counter % types.size()]
	_type_counter += 1
	match t:
		"collect":
			return _make("collect", "Gather ammunition", "Collect %d ammo boxes." % (2 + d), {"item": "ammo", "count": 2 + d}, false, gid, d)
		"deliver":
			if not pois.is_empty():
				return _make("deliver", "Run supplies", "Deliver rations to the settlement.", {"item": "food", "poi": pois[_rng.randi() % pois.size()]}, false, gid, d)
		"hunt":
			return _make("hunt", "Cull the wolves", "Kill %d raiders." % (3 + d * 2), {"faction": Game.RAIDER_FACTION, "count": 3 + d * 2}, false, gid, d)
		"recon":
			if pois.size() > 2:
				var i := _rng.randi() % pois.size()
				return _make("recon", "Scout the wilds", "Visit 2 marked sites.", {"recon_pois": [pois[i], pois[(i + 1) % pois.size()]], "visited": []}, false, gid, d)
		"assassinate":
			if not bosses.is_empty():
				var bo: Node = bosses[_rng.randi() % bosses.size()]
				return _make("assassinate", "Bounty", "Eliminate %s." % bo.display_name, {"target_id": bo.combatant_id}, false, gid, d)
		"escort":
			if pois.size() > 1:
				return _make("escort", "Escort the caravan", "Escort the VIP to the next settlement.", {"poi": pois[0], "dest": pois[1]}, false, gid, d)
		"clear_camp":
			if not pois.is_empty():
				return _make("clear_camp", "Clear the camp", "Drive the raiders away from the settlement.", {"poi": pois[_rng.randi() % pois.size()], "faction": Game.RAIDER_FACTION}, false, gid, d)
		"sabotage":
			if not pois.is_empty():
				return _make("sabotage", "Sabotage the cache", "Destroy a raider supply cache.", {"site": pois[_rng.randi() % pois.size()]}, false, gid, d)
		"rescue":
			if pois.size() > 1:
				var camp: Node3D = pois[_rng.randi() % pois.size()]
				var home: Node3D = pois[0] if pois[0] != camp else pois[1]
				return _make("rescue", "Rescue the captive", "Fight to the captive and walk them home.", {"poi": camp, "dest": home}, false, gid, d)
		"holdout":
			if not pois.is_empty():
				return _make("holdout", "Hold out", "Survive %d waves at the settlement." % (2 + d), {"poi": pois[_rng.randi() % pois.size()], "duration": 50.0 + d * 15.0, "waves": 2 + d, "_wave": 0}, false, gid, d)
		"treasure":
			if not pois.is_empty():
				return _make("treasure", "Treasure hunt", "Find and crack the buried cache in the marked area.", {"anchor": pois[_rng.randi() % pois.size()]}, false, gid, d)
		"courier":
			if not pois.is_empty():
				return _make("courier", "Urgent delivery", "Deliver rations before time runs out.", {"item": "food", "poi": pois[_rng.randi() % pois.size()], "deadline": 150.0 - d * 25.0}, false, gid, d)
	# Chosen type wasn't feasible on this map — fall back to an always-valid hunt.
	return _make("hunt", "Cull the wolves", "Kill %d raiders." % (3 + d * 2), {"faction": Game.RAIDER_FACTION, "count": 3 + d * 2}, false, gid, d)

## Mid-run event: raiders hit a settlement — an urgent, auto-active mission to save it.
func _spawn_distress() -> int:
	var pois := _pois()
	if pois.is_empty() or world == null or not world.has_method("spawn_enemy"):
		return -1
	var poi: Node3D = pois[_rng.randi() % pois.size()]
	var skill := float(Game.config.get("bot_skill", 1.0))
	var ids: Array = []
	var n := 2 + _rng.randi() % 3
	for i in n:
		var ang := _rng.randf() * TAU
		var pos := _near_nav(poi.global_position + Vector3(cos(ang), 0, sin(ang)) * 18.0, 1.0)
		ids.append(world.spawn_enemy(skill, false, pos, "", 1, Game.RAIDER_FACTION))
	var id := _make("distress", "Distress call", "The settlement is under attack — save it!", {"poi": poi, "attacker_ids": ids, "deadline": 90.0}, false, 0, 1)
	_activate(id)
	if world.has_method("broadcast_event"):
		world.broadcast_event("⚠ Distress call — a settlement is under attack!")
	return id

# ---------------------------------------------------------------- offers / accept

## The first available quest a given NPC offers (empty if none, or if their faction
## has turned hostile — no work from people who shoot you on sight).
func offer_for(giver_id: int) -> Dictionary:
	for b in get_tree().get_nodes_in_group("bot"):
		if b.combatant_id == giver_id and _stance_of(b.faction) == "hostile":
			return {}
	for q in quests:
		if int(q["giver"]) == giver_id and q["state"] == "available":
			return q
	return {}

func accept(quest_id: int) -> void:
	for q in quests:
		if int(q["id"]) == quest_id and q["state"] == "available":
			_activate(quest_id)
			if world and world.has_method("broadcast_event"):
				world.broadcast_event("◆ Quest accepted: %s" % String(q["title"]))
			return

func _activate(id: int) -> void:
	for q in quests:
		if int(q["id"]) != id:
			continue
		q["state"] = "active"
		var diff := int(q.get("difficulty", 1))
		match String(q["type"]):
			"escort":
				if not q.has("escort_node"):
					q["escort_node"] = world.spawn_escort(q["poi"].global_position, q["dest"].global_position, 2.6)
			"rescue":
				# The captive starts at the camp under guard; walk them home like a VIP.
				if not q.has("escort_node"):
					var camp: Vector3 = q["poi"].global_position
					q["escort_node"] = world.spawn_escort(camp, q["dest"].global_position, 2.6)
					_spawn_reinforcements(camp, 1 + diff)
			"sabotage":
				if not q.get("cache_spawned", false):
					var site = q.get("site")
					var pos: Vector3 = _near_nav(site.global_position if site else Vector3.ZERO)
					var node = world.spawn_target(pos + Vector3(0, 1.0, 0), 120.0 + diff * 80.0) if world.has_method("spawn_target") else null
					q["cache_node"] = node
					q["cache_spawned"] = node != null
					_spawn_reinforcements(pos, 1 + diff)
			"treasure":
				# A vague search zone is marked off in the wilds; the cache itself sits
				# somewhere inside it — find it and crack it open.
				if not q.get("cache_spawned", false):
					var anchor = q.get("anchor")
					var base: Vector3 = anchor.global_position if anchor else Vector3.ZERO
					var ang := _rng.randf() * TAU
					var zone := _near_nav(base + Vector3(cos(ang), 0, sin(ang)) * _rng.randf_range(60.0, 100.0))
					var marker := Node3D.new()
					marker.set_meta("radius", 28.0)
					world.add_child(marker)
					marker.global_position = zone
					q["poi"] = marker   # minimap shows the search zone as the objective
					var ang2 := _rng.randf() * TAU
					var dig := _near_nav(zone + Vector3(cos(ang2), 0, sin(ang2)) * _rng.randf_range(4.0, 18.0))
					q["cache_pos"] = dig
					var node = world.spawn_target(dig + Vector3(0, 0.6, 0), 80.0) if world.has_method("spawn_target") else null
					q["cache_node"] = node
					q["cache_spawned"] = node != null
			"holdout":
				q["_wave"] = 0
			"assassinate":
				var tp := _bot_pos(int(q.get("target_id", 0)))
				if tp.x < 1.0e19:
					_spawn_reinforcements(tp, diff)   # bodyguards, scaled by difficulty
			"clear_camp", "defend":
				if q.has("poi"):
					_spawn_reinforcements(q["poi"].global_position, 1 + diff)
		_broadcast()
		return

## Spawn `n` raider reinforcements around a point (harder missions = more guards).
func _spawn_reinforcements(center: Vector3, n: int) -> void:
	if world == null or n <= 0 or not world.has_method("spawn_enemy"):
		return
	var skill := float(Game.config.get("bot_skill", 1.0))
	for i in n:
		var ang := TAU * float(i) / float(maxi(n, 1)) + float(_next_id) * 0.7
		var pos := _near_nav(center + Vector3(cos(ang), 0, sin(ang)) * 10.0, 1.0)
		world.spawn_enemy(skill, false, pos, "", 1, Game.RAIDER_FACTION)

func _near_nav(pos: Vector3, lift := 0.0) -> Vector3:
	if world and world.has_method("_snap_to_nav"):
		var p: Vector3 = world._snap_to_nav(pos)
		p.y += lift
		return p
	return pos

func _bot_pos(id: int) -> Vector3:
	for b in get_tree().get_nodes_in_group("combatant"):
		if int(b.get("combatant_id")) == id and not b.get("dead"):
			return b.global_position
	return Vector3(1.0e20, 0, 0)

# ---------------------------------------------------------------- completion

func notify_kill(victim_id: int, attacker_id: int = 0) -> void:
	# Only kills by a player count toward hunts (player combatant_ids are positive;
	# bots/targets are negative) — otherwise villagers/ambushes/falls finish it for you.
	var by_player := attacker_id > 0
	var vfac := ""
	for b in get_tree().get_nodes_in_group("bot"):
		if b.combatant_id == victim_id:
			vfac = b.faction
			break
	var changed := false
	for q in quests:
		if q["state"] != "active":
			continue
		if q["type"] == "assassinate" and int(q.get("target_id", 0)) == victim_id:
			changed = _complete(q) or changed   # target down by any means — mission met
		elif q["type"] == "hunt" and by_player and vfac == String(q.get("faction", "")):
			q["progress"] = int(q["progress"]) + 1
			if int(q["progress"]) >= int(q["count"]):
				changed = _complete(q) or changed
		elif q["type"] == "distress":
			# Any attacker down counts (defenders helping is fine — the village is saved).
			var ids: Array = q.get("attacker_ids", [])
			ids.erase(victim_id)
			q["attacker_ids"] = ids
			if ids.is_empty():
				changed = _complete(q) or changed
	if changed:
		_broadcast()

func _process(delta: float) -> void:
	if not Net.is_host() or not Game.match_active:
		return
	var players: Array = []
	for p in get_tree().get_nodes_in_group("player"):
		if not p.get("dead") and not p.get("fully_dead"):
			players.append(p)
	var changed := false
	for q in quests:
		if q["state"] != "active":
			continue
		match q["type"]:
			"reach":
				if _player_near(players, q["poi"]):
					changed = _complete(q) or changed
			"defend":
				if _player_near(players, q["poi"]):
					q["_timer"] = float(q["_timer"]) + delta
					if float(q["_timer"]) >= float(q["duration"]):
						changed = _complete(q) or changed
			"deliver":
				if _player_near(players, q["poi"]):
					var p = _player_with_item(players, String(q["item"]))
					if p != null:
						_remove_item(p, String(q["item"]))
						changed = _complete(q) or changed
			"collect":
				if _player_with_count(players, String(q["item"]), int(q["count"])) != null:
					changed = _complete(q) or changed
			"escort":
				if q.has("escort_node") and is_instance_valid(q["escort_node"]) and q["escort_node"].get("arrived"):
					changed = _complete(q) or changed
			"clear_camp":
				if _camp_clear(q["poi"], String(q["faction"])):
					changed = _complete(q) or changed
			"recon":
				var rp: Array = q.get("recon_pois", [])
				var vis: Array = q.get("visited", [])
				for i in rp.size():
					if not vis.has(i) and is_instance_valid(rp[i]) and _player_near(players, rp[i]):
						vis.append(i)
				q["visited"] = vis
				if rp.size() > 0 and vis.size() >= rp.size():
					changed = _complete(q) or changed
			"sabotage":
				if q.get("cache_spawned", false):
					var node = q.get("cache_node")
					if not is_instance_valid(node) or node.get("destroyed"):
						changed = _complete(q) or changed
			"treasure":
				if q.get("cache_spawned", false):
					var node = q.get("cache_node")
					if not is_instance_valid(node) or node.get("destroyed"):
						# Cracked open — spill loot at the dig site.
						if world and world.has_method("drop_loot_at"):
							world.drop_loot_at(q.get("cache_pos", Vector3.ZERO), 2 + int(q.get("difficulty", 1)))
						changed = _complete(q) or changed
			"rescue":
				if q.has("escort_node") and is_instance_valid(q["escort_node"]) and q["escort_node"].get("arrived"):
					changed = _complete(q) or changed
			"courier":
				q["_timer"] = float(q["_timer"]) + delta
				if _player_near(players, q["poi"]) and _player_with_item(players, String(q["item"])) != null:
					_remove_item(_player_with_item(players, String(q["item"])), String(q["item"]))
					changed = _complete(q) or changed
				elif float(q["_timer"]) >= float(q["deadline"]):
					_fail(q)
			"holdout":
				if _player_near(players, q["poi"]):
					q["_timer"] = float(q["_timer"]) + delta
					var waves := int(q.get("waves", 2))
					var dur := float(q.get("duration", 50.0))
					# Spawn the next attack wave as the timer crosses each threshold.
					if int(q["_wave"]) < waves and float(q["_timer"]) >= dur * float(int(q["_wave"]) + 1) / float(waves + 1):
						q["_wave"] = int(q["_wave"]) + 1
						_spawn_reinforcements(q["poi"].global_position, 2 + int(q.get("difficulty", 1)))
					if float(q["_timer"]) >= dur:
						changed = _complete(q) or changed
			"distress":
				q["_timer"] = float(q["_timer"]) + delta
				if float(q["_timer"]) >= float(q.get("deadline", 90.0)):
					_fail(q)
	if changed:
		_broadcast()

	# ------------------------------------------------------------ world dynamics
	# New offers trickle in, stale ones expire, and distress calls fire mid-run.
	_expire_offers(delta)
	_trickle_t += delta
	if _trickle_t >= TRICKLE_SECS:
		_trickle_t = 0.0
		if _available_count() < MAX_AVAILABLE:
			var nid := _new_offer()
			if nid >= 0 and world and world.has_method("broadcast_event"):
				world.broadcast_event("◆ New work is available — check the village Elders.")
	_distress_t += delta
	if _distress_t >= DISTRESS_SECS:
		_distress_t = 0.0
		if _rng.randf() < 0.7:
			_spawn_distress()

## Unaccepted offers go stale and rotate away — the world moves on without you.
func _expire_offers(delta: float) -> void:
	for q in quests:
		if q["state"] != "available":
			continue
		q["_age"] = float(q["_age"]) + delta
		if float(q["_age"]) >= OFFER_TTL:
			q["state"] = "expired"

## An active mission that can be lost (timed delivery, distress) fails quietly-ish.
func _fail(q: Dictionary) -> void:
	if q["state"] != "active":
		return
	q["state"] = "failed"
	if world and world.has_method("broadcast_event"):
		world.broadcast_event("✗ %s — failed" % String(q["title"]))
	_broadcast()

func _complete(q: Dictionary) -> bool:
	if q["state"] == "complete":
		return false
	q["state"] = "complete"
	points += int(q["points"])
	# Log it in the events feed and pop a celebration banner with the quest title.
	if world and world.has_method("broadcast_event"):
		world.broadcast_event("✓ %s   +%d pt" % [String(q["title"]), int(q["points"])], String(q["title"]))
	# Reaching the point goal is a milestone, not a forced end — keep exploring; leave
	# via the pause menu whenever you're done (your character is saved on the way out).
	if points >= target_points and not _won:
		_won = true
		if world and world.has_method("broadcast_event"):
			world.broadcast_event("★ Goal reached (%d pts)! Keep exploring — leave when you're ready." % points, "Goal reached!")
	return true

# ---------------------------------------------------------------- helpers

func _player_near(players: Array, poi: Node3D) -> bool:
	var r := float(poi.get_meta("radius", 24.0)) + 4.0
	for p in players:
		if p.global_position.distance_to(poi.global_position) < r:
			return true
	return false

func _player_with_item(players: Array, kind: String) -> Node:
	for p in players:
		for it in p.inventory:
			if String(it.get("kind", "")) == kind:
				return p
	return null

func _player_with_count(players: Array, kind: String, n: int) -> Node:
	for p in players:
		var c := 0
		for it in p.inventory:
			if String(it.get("kind", "")) == kind:
				c += 1
		if c >= n:
			return p
	return null

func _remove_item(p: Node, kind: String) -> void:
	for i in p.inventory.size():
		if String((p.inventory[i] as Dictionary).get("kind", "")) == kind:
			p.inventory.remove_at(i)
			p.inventory_changed.emit()
			return

func _camp_clear(poi: Node3D, faction: String) -> bool:
	var r := float(poi.get_meta("radius", 24.0)) + 8.0
	for b in get_tree().get_nodes_in_group("bot"):
		if b.get("dead"):
			continue
		if b.faction == faction and b.global_position.distance_to(poi.global_position) < r:
			return false
	return true

# ---------------------------------------------------------------- HUD log

func _qprog(q: Dictionary) -> String:
	match q["type"]:
		"hunt":
			return "  (%d/%d)" % [int(q["progress"]), int(q["count"])]
		"collect":
			return "  (need %d)" % int(q["count"])
		"defend":
			return "  (%ds)" % max(0, int(ceil(float(q["duration"]) - float(q["_timer"]))))
		"recon":
			return "  (%d/%d)" % [int((q.get("visited", []) as Array).size()), int((q.get("recon_pois", []) as Array).size())]
		"courier", "distress":
			return "  (%ds left)" % max(0, int(ceil(float(q.get("deadline", 0.0)) - float(q["_timer"]))))
		"holdout":
			return "  (wave %d/%d, %ds)" % [int(q.get("_wave", 0)), int(q.get("waves", 2)), max(0, int(ceil(float(q.get("duration", 0.0)) - float(q["_timer"]))))]
		_:
			return ""

func _tracker_text() -> String:
	var lines: Array = ["QUESTS  %d/%d pts" % [points, target_points]]
	var shown := 0
	for q in quests:
		if q["state"] == "active" and shown < 5:
			lines.append("• [%s] %s%s" % [difficulty_label(q), String(q["title"]), _qprog(q)])
			shown += 1
	if shown == 0:
		lines.append("• Talk to village Elders for tasks")
	return "\n".join(lines)

func _broadcast() -> void:
	if world and world.has_method("broadcast_quests"):
		world.broadcast_quests(_tracker_text())
