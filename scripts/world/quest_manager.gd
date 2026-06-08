extends Node
## Host-only Survival quest system. Generates a pool of point-bearing quests (more
## than the player needs), runs an auto-advancing main chain, lets named NPCs offer
## side quests, tracks completion and ends the match once the player reaches the
## point target (Game.config.mission_points). The quest log is pushed to every HUD
## through the world. Eight quest types: reach, defend, deliver, collect, hunt,
## assassinate, escort, clear_camp.

const PTS := {
	"reach": 1, "collect": 2, "deliver": 2, "hunt": 2, "defend": 2,
	"escort": 3, "assassinate": 3, "clear_camp": 3,
}

var world: Node
var target_points: int = 10
var points: int = 0
var quests: Array = []
var _next_id: int = 0
var _main_order: Array = []
var _main_idx: int = 0

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

func _make(type: String, title: String, desc: String, extra: Dictionary, main := false, giver := 0) -> int:
	var q := {
		"id": _next_id, "type": type, "title": title, "desc": desc,
		"points": int(PTS.get(type, 2)), "state": "available", "main": main,
		"giver": giver, "progress": 0, "_timer": 0.0,
	}
	q.merge(extra)
	quests.append(q)
	_next_id += 1
	return q["id"]

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

	# Main chain — active from the start, advancing one at a time.
	if pois.size() > 1:
		_main_order.append(_make("reach", "Scout the outpost", "Travel to the marked settlement.", {"poi": pois[1]}, true))
	_main_order.append(_make("hunt", "Thin the raiders", "Kill 5 raiders.", {"faction": Game.RAIDER_FACTION, "count": 5}, true))
	if not bosses.is_empty():
		_main_order.append(_make("assassinate", "Behead the warband", "Hunt down %s." % bosses[0].display_name, {"target_id": bosses[0].combatant_id}, true))
	if pois.size() > 2:
		_main_order.append(_make("defend", "Hold the line", "Defend the settlement for 30 seconds.", {"poi": pois[2], "duration": 30.0}, true))

	# Side quests offered by village Elders — generate plenty (more than needed).
	var types := ["collect", "deliver", "hunt", "assassinate", "escort", "clear_camp"]
	var ti := 0
	var ei := 0
	var guard := 0
	while _total_pool_points() < target_points * 2 + 4 and guard < 80:
		guard += 1
		var giver = elders[ei % elders.size()] if not elders.is_empty() else null
		var gid: int = giver.combatant_id if giver != null else 0
		var t: String = types[ti % types.size()]
		ti += 1
		ei += 1
		match t:
			"collect":
				_make("collect", "Gather ammunition", "Collect 3 ammo boxes.", {"item": "ammo", "count": 3}, false, gid)
			"deliver":
				if not pois.is_empty():
					_make("deliver", "Run supplies", "Deliver rations to the settlement.", {"item": "food", "poi": pois[ti % pois.size()]}, false, gid)
			"hunt":
				_make("hunt", "Cull the wolves", "Kill 4 raiders.", {"faction": Game.RAIDER_FACTION, "count": 4}, false, gid)
			"assassinate":
				if not bosses.is_empty():
					var bo = bosses[ti % bosses.size()]
					_make("assassinate", "Bounty", "Eliminate %s." % bo.display_name, {"target_id": bo.combatant_id}, false, gid)
			"escort":
				if pois.size() > 1:
					_make("escort", "Escort the caravan", "Escort the VIP to the next settlement.", {"poi": pois[0], "dest": pois[1]}, false, gid)
			"clear_camp":
				if not pois.is_empty():
					_make("clear_camp", "Clear the camp", "Drive the raiders away from the settlement.", {"poi": pois[(ti + 1) % pois.size()], "faction": Game.RAIDER_FACTION}, false, gid)

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
		if int(q["id"]) == id:
			q["state"] = "active"
			if q["type"] == "escort" and not q.has("escort_node"):
				q["escort_node"] = world.spawn_escort(q["poi"].global_position, q["dest"].global_position, 2.6)
			_broadcast()
			return

# ---------------------------------------------------------------- completion

func notify_kill(victim_id: int) -> void:
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
			changed = _complete(q) or changed
		elif q["type"] == "hunt" and vfac == String(q.get("faction", "")):
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
	if points >= target_points and Game.match_active:
		Game.end_match({"reason": "survival_win", "points": points})
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
		_:
			return ""

func _tracker_text() -> String:
	var lines: Array = ["QUESTS  %d/%d pts" % [points, target_points]]
	var shown := 0
	for q in quests:
		if q["state"] == "active" and shown < 5:
			lines.append("• %s%s" % [String(q["title"]), _qprog(q)])
			shown += 1
	if shown == 0:
		lines.append("• Talk to village Elders for tasks")
	return "\n".join(lines)

func _broadcast() -> void:
	if world and world.has_method("broadcast_quests"):
		world.broadcast_quests(_tracker_text())
