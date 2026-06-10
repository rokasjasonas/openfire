extends Node
## Host-only Adventure quest system. Generates a pool of point-bearing quests (more
## than the player needs), runs an auto-advancing main chain, lets named NPCs offer
## side quests, tracks completion and ends the match once the player reaches the
## point target (Game.config.mission_points). The quest log is pushed to every HUD
## through the world. Eight quest types: reach, defend, deliver, collect, hunt,
## assassinate, escort, clear_camp.

## Base point value per quest type (before the difficulty bonus).
const PTS := {
	"reach": 1, "collect": 2, "deliver": 2, "hunt": 2, "defend": 2, "recon": 2,
	"escort": 3, "assassinate": 3, "clear_camp": 3, "sabotage": 3,
}

# Per-mission difficulty: 0 Easy, 1 Normal, 2 Hard. Each level adds 1 point of reward,
# scales required amounts, and (for combat quests) spawns extra raider reinforcements
# at the objective. The menu Easy/Normal/Hard stays a flat multiplier on enemy skill.
const DIFF_NAMES := ["Easy", "Normal", "Hard"]

var world: Node
var target_points: int = 10
var points: int = 0
var quests: Array = []
var _next_id: int = 0
var _main_order: Array = []
var _main_idx: int = 0
var _won: bool = false

func start(w: Node) -> void:
	world = w
	add_to_group("quest_manager")
	target_points = maxi(1, int(Game.config.get("mission_points", 10)))
	_generate()
	if not _main_order.is_empty():
		_activate(_main_order[0])
	set_process(true)
	_broadcast()

# ---------------------------------------------------------------- generation

func _make(type: String, title: String, desc: String, extra: Dictionary, main := false, giver := 0, diff := 1) -> int:
	diff = clampi(diff, 0, 2)
	var q := {
		"id": _next_id, "type": type, "title": title, "desc": desc,
		"points": int(PTS.get(type, 2)) + diff, "difficulty": diff,
		"state": "available", "main": main, "giver": giver, "progress": 0, "_timer": 0.0,
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

func _total_pool_points() -> int:
	var p := 0
	for q in quests:
		p += int(q["points"])
	return p

func _generate() -> void:
	var pois := _pois()
	var elders: Array = []
	var bosses: Array = []
	for b in get_tree().get_nodes_in_group("bot"):
		if b.role == "Elder":
			elders.append(b)
		elif b.role == "Raid Boss":
			bosses.append(b)

	# Main chain — active from the start, advancing one at a time, ramping Easy -> Hard
	# for a smooth curve. New types (recon, sabotage) add variety.
	if pois.size() > 1:
		_main_order.append(_make("reach", "Scout the outpost", "Travel to the marked settlement.", {"poi": pois[1]}, true, 0, 0))
	if pois.size() > 3:
		_main_order.append(_make("recon", "Survey the frontier", "Scout 3 settlements.",
			{"recon_pois": [pois[1], pois[2], pois[3]], "visited": []}, true, 0, 0))
	_main_order.append(_make("hunt", "Thin the raiders", "Kill 6 raiders.", {"faction": Game.RAIDER_FACTION, "count": 6}, true, 0, 1))
	if not pois.is_empty():
		_main_order.append(_make("sabotage", "Burn the raider cache", "Destroy the raiders' supply cache.",
			{"site": pois[pois.size() - 1]}, true, 0, 1))
	if not bosses.is_empty():
		_main_order.append(_make("assassinate", "Behead the warband", "Hunt down %s." % bosses[0].display_name, {"target_id": bosses[0].combatant_id}, true, 0, 2))
	if pois.size() > 2:
		_main_order.append(_make("defend", "Hold the line", "Defend the settlement for 45 seconds.", {"poi": pois[2], "duration": 45.0}, true, 0, 2))

	# Side quests offered by village Elders — generate plenty (more than needed), with
	# rotating difficulty and amounts scaled to it.
	var types := ["collect", "deliver", "hunt", "recon", "assassinate", "escort", "clear_camp", "sabotage"]
	var ti := 0
	var ei := 0
	var guard := 0
	while _total_pool_points() < target_points * 2 + 4 and guard < 80:
		guard += 1
		var giver = elders[ei % elders.size()] if not elders.is_empty() else null
		var gid: int = giver.combatant_id if giver != null else 0
		var t: String = types[ti % types.size()]
		var d := ti % 3   # rotate Easy / Normal / Hard
		ti += 1
		ei += 1
		match t:
			"collect":
				_make("collect", "Gather ammunition", "Collect %d ammo boxes." % (2 + d), {"item": "ammo", "count": 2 + d}, false, gid, d)
			"deliver":
				if not pois.is_empty():
					_make("deliver", "Run supplies", "Deliver rations to the settlement.", {"item": "food", "poi": pois[ti % pois.size()]}, false, gid, d)
			"hunt":
				_make("hunt", "Cull the wolves", "Kill %d raiders." % (3 + d * 2), {"faction": Game.RAIDER_FACTION, "count": 3 + d * 2}, false, gid, d)
			"recon":
				if pois.size() > 2:
					var rp := [pois[ti % pois.size()], pois[(ti + 1) % pois.size()]]
					_make("recon", "Scout the wilds", "Visit %d marked sites." % rp.size(), {"recon_pois": rp, "visited": []}, false, gid, d)
			"assassinate":
				if not bosses.is_empty():
					var bo = bosses[ti % bosses.size()]
					_make("assassinate", "Bounty", "Eliminate %s." % bo.display_name, {"target_id": bo.combatant_id}, false, gid, d)
			"escort":
				if pois.size() > 1:
					_make("escort", "Escort the caravan", "Escort the VIP to the next settlement.", {"poi": pois[0], "dest": pois[1]}, false, gid, d)
			"clear_camp":
				if not pois.is_empty():
					_make("clear_camp", "Clear the camp", "Drive the raiders away from the settlement.", {"poi": pois[(ti + 1) % pois.size()], "faction": Game.RAIDER_FACTION}, false, gid, d)
			"sabotage":
				if not pois.is_empty():
					_make("sabotage", "Sabotage the cache", "Destroy a raider supply cache.", {"site": pois[ti % pois.size()]}, false, gid, d)

# ---------------------------------------------------------------- offers / accept

## The first available quest a given NPC offers (empty if none).
func offer_for(giver_id: int) -> Dictionary:
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
			"sabotage":
				if not q.get("cache_spawned", false):
					var site = q.get("site")
					var pos: Vector3 = _near_nav(site.global_position if site else Vector3.ZERO)
					var node = world.spawn_target(pos + Vector3(0, 1.0, 0), 120.0 + diff * 80.0) if world.has_method("spawn_target") else null
					q["cache_node"] = node
					q["cache_spawned"] = node != null
					_spawn_reinforcements(pos, 1 + diff)
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
	if changed:
		_broadcast()

func _complete(q: Dictionary) -> bool:
	if q["state"] == "complete":
		return false
	q["state"] = "complete"
	points += int(q["points"])
	# Log it in the events feed and pop a celebration banner with the quest title.
	if world and world.has_method("broadcast_event"):
		world.broadcast_event("✓ %s   +%d pt" % [String(q["title"]), int(q["points"])], String(q["title"]))
	if q["main"]:
		_advance_main()
	# Reaching the point goal is a milestone, not a forced end — keep exploring; leave
	# via the pause menu whenever you're done (your character is saved on the way out).
	if points >= target_points and not _won:
		_won = true
		if world and world.has_method("broadcast_event"):
			world.broadcast_event("★ Goal reached (%d pts)! Keep exploring — leave when you're ready." % points, "Goal reached!")
	return true

func _advance_main() -> void:
	_main_idx += 1
	if _main_idx < _main_order.size():
		_activate(_main_order[_main_idx])

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
