extends Node
## Headless smoke test. Run with:
##   .tools/godot --headless res://tests/smoke.tscn
## Hosts a co-op match, spawns the world, and reports what came alive.

func _ready() -> void:
	print("SMOKE: start")
	Game.config = {
		"mode": Game.Mode.COOP,
		"map": "res://maps/facility.tscn",
		"mission_id": "clear_the_facility",
		"bot_count": 4,
		"bot_skill": 1.0,
		"frag_limit": 25,
		"time_limit": 600,
	}
	print("SMOKE: missions loaded = ", Missions.get_all().size())
	print("SMOKE: weapons = ", WeaponDB.all_ids())
	var ok := Net.host_game()
	print("SMOKE: host_game = ", ok, " is_host=", Net.is_host())

	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)

	await get_tree().create_timer(6.0).timeout

	var players := get_tree().get_nodes_in_group("player").size()
	var bots := get_tree().get_nodes_in_group("bot").size()
	var nav := get_tree().get_nodes_in_group("nav_region").size()
	var zones := get_tree().get_nodes_in_group("zone").size()
	print("SMOKE: players=", players, " bots=", bots, " nav_regions=", nav, " zones=", zones)
	print("SMOKE: scoreboard rows=", Game.scores.size())

	# Let bots think/move for a moment to exercise navigation + shooting.
	await get_tree().create_timer(4.0).timeout
	var moved := false
	for b in get_tree().get_nodes_in_group("bot"):
		if b.global_position.length() > 0.01:
			moved = true
	print("SMOKE: bots_positioned=", moved)

	# Verify the local player can actually fire (loadout equipped + ammo consumed).
	var fired_ok := false
	var me: Node = null
	for p in get_tree().get_nodes_in_group("player"):
		if p.is_multiplayer_authority():
			me = p
			break
	if me:
		var wm = me.weapons
		var wid = wm.loadout[wm.current_index] if not wm.loadout.is_empty() else ""
		var before: int = wm.ammo.get(wid, {}).get("mag", -1)
		wm.set_trigger(true)
		await get_tree().create_timer(0.6).timeout
		wm.set_trigger(false)
		var after: int = wm.ammo.get(wid, {}).get("mag", -1)
		print("SMOKE: weapon=", wid, " loadout=", wm.loadout, " ammo before/after=", before, "/", after)
		fired_ok = before > 0 and after < before
	print("SMOKE: fire_works=", fired_ok)
	print("SMOKE: DONE ok=", players >= 1 and bots >= 1 and nav >= 1 and fired_ok)
	get_tree().quit()
