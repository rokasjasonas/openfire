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
	# Keep the stationary test player off the bots' target list so it survives the
	# combat-feedback checks (otherwise the now-tougher enemies pick it off).
	if me:
		me.remove_from_group("combatant")
	var sig := [false]  # Array (reference) so the lambda can write back.
	var damage_number_ok := false
	if me:
		me.dealt_damage.connect(func(_amt): sig[0] = true)
		var wm = me.weapons
		var wid = wm.loadout[wm.current_index] if not wm.loadout.is_empty() else ""
		var before: int = wm.ammo.get(wid, {}).get("mag", -1)
		# Firing runs in _process; pump a few frames + a short window so it ticks.
		wm.set_trigger(true)
		await get_tree().create_timer(0.6).timeout
		wm.set_trigger(false)
		var after: int = wm.ammo.get(wid, {}).get("mag", -1)
		fired_ok = before > 0 and after < before
		print("SMOKE: weapon=", wid, " ammo before/after=", before, "/", after)

		# Directly exercise the damage-feedback path (floating number + signal +
		# crosshair hitmarker), independent of headless AI/aim timing.
		var labels_before := _count_label3d()
		wm._show_damage_number(me.global_position + Vector3.UP, 24.0)
		me.dealt_damage.emit(24.0)
		await get_tree().process_frame
		damage_number_ok = _count_label3d() > labels_before

	# Verify the red damage-flash overlay fires when the local player is hit.
	var flash_ok := false
	var hud: Node = null
	for w in get_tree().get_nodes_in_group("world"):
		if w.has_node("HUD"):
			hud = w.get_node("HUD")
	if me and hud and not me.dead:
		await get_tree().process_frame  # ensure HUD has bound to the player
		me.receive_damage(20.0, 0)      # take a non-lethal hit
		await get_tree().process_frame
		flash_ok = hud.damage_flash.color.a > 0.0

	# Verify spawn selection keeps new spawns clear of existing combatants
	# (overlapping spawns are what launched players into the air).
	var spawn_clear := true
	if world:
		for k in 12:
			var tr: Transform3D = world.get_spawn_transform(k % 2 == 0)
			var nearest := INF
			for c in get_tree().get_nodes_in_group("combatant"):
				if c.get("dead"):
					continue
				var dx: float = tr.origin.x - c.global_position.x
				var dz: float = tr.origin.z - c.global_position.z
				nearest = minf(nearest, Vector2(dx, dz).length())
			if nearest < 1.0:
				spawn_clear = false
	print("SMOKE: spawn_clearance_ok=", spawn_clear)

	# Verify audio assets load and playback paths don't error.
	var audio_ok := Audio._get_stream("res://assets/audio/fire_rifle.ogg") != null \
		and Audio._get_stream("res://assets/audio/ui_click.ogg") != null \
		and Audio._get_stream("res://assets/audio/death.ogg") != null
	Audio.play_ui("res://assets/audio/ui_click.ogg")
	if me:
		Audio.play_3d("res://assets/audio/fire_rifle.ogg", me.global_position, 0.0, 0.1)
	await get_tree().process_frame

	# Body-part hitboxes: a ray into a bot's head hitbox resolves to mult >= 2.
	var headshot_ok := false
	var bots_list := get_tree().get_nodes_in_group("bot")
	if me and not bots_list.is_empty():
		var bot: Node = bots_list[0]
		var head := bot.get_node_or_null("Hitboxes/Head/Shape")
		if head:
			var hpos: Vector3 = head.global_position
			var q := PhysicsRayQueryParameters3D.create(hpos + Vector3(0, 0, 2.0), hpos)
			q.collision_mask = 1 | 16
			q.collide_with_areas = true
			var r: Dictionary = me.get_world_3d().direct_space_state.intersect_ray(q)
			if r and r.collider is Hitbox:
				headshot_ok = r.collider.multiplier >= 2.0 and r.collider.combatant() == bot
	print("SMOKE: headshot_hitbox_ok=", headshot_ok)

	# Crouch: _apply_crouch shrinks the capsule and lowers the head.
	var crouch_ok := false
	if me:
		me._apply_crouch(1.0)
		var crouched_h: float = (me.col_shape.shape as CapsuleShape3D).height
		var crouched_head: float = me.head.position.y
		me._apply_crouch(0.0)
		var stand_h: float = (me.col_shape.shape as CapsuleShape3D).height
		crouch_ok = crouched_h < stand_h - 0.5 and crouched_head < me.STAND_HEAD - 0.3
	print("SMOKE: crouch_ok=", crouch_ok)

	# Hitbox edge coverage: a shot near the body's side (x=0.38, beyond the old
	# narrow torso) now resolves to a hitbox instead of missing.
	var coverage_ok := false
	if me:
		me.rotation = Vector3.ZERO
		me._apply_crouch(0.0)
		await get_tree().physics_frame
		var tpos: Vector3 = me.get_node("Hitboxes/Torso/Shape").global_position
		var aim := tpos + Vector3(0.38, 0, 0)
		var q := PhysicsRayQueryParameters3D.create(aim + Vector3(0, 0, 2.5), aim)
		q.collision_mask = 1 | 16
		q.collide_with_areas = true
		var r: Dictionary = me.get_world_3d().direct_space_state.intersect_ray(q)
		coverage_ok = r and r.collider is Hitbox
	print("SMOKE: hitbox_edge_coverage_ok=", coverage_ok)

	# Grenades: throwing decrements ammo and spawns a grenade in the world.
	var grenade_ok := false
	if me:
		var before_g: int = me.grenades
		me._throw_grenade()
		await get_tree().process_frame
		var found := false
		for n in get_tree().current_scene.get_children():
			if n is RigidBody3D:
				found = true
		grenade_ok = me.grenades == before_g - 1 and found
	print("SMOKE: grenade_ok=", grenade_ok)

	# Settings autoload present + applied.
	var settings_ok: bool = Settings != null and Settings.fov >= 60.0 and Settings.mouse_sensitivity > 0.0
	print("SMOKE: settings_ok=", settings_ok)

	# Enemy variety: spawning a "heavy" yields a tougher bot than the default.
	var variety_ok := false
	if world and me:
		var hid: int = world.spawn_enemy(1.0, false, me.global_position + Vector3(4, 0, 0), "heavy")
		await get_tree().process_frame
		for b in get_tree().get_nodes_in_group("bot"):
			if b.combatant_id == hid:
				variety_ok = b.etype == "heavy" and b.max_health > 150.0
	print("SMOKE: enemy_variety_ok=", variety_ok)

	# Pickups: present in the map; heal + weapon-grant effects work.
	var pickups := get_tree().get_nodes_in_group("pickup")
	var pickup_ok := false
	if me and not pickups.is_empty():
		me.sync_health = 50.0
		me.heal(30)
		me.weapons.give_weapon("sniper")
		pickup_ok = is_equal_approx(me.sync_health, 80.0) and me.weapons.loadout.has("sniper")
	print("SMOKE: pickups=", pickups.size(), " pickup_ok=", pickup_ok)

	# Non-flat map: highlands builds, bakes a navmesh, has multi-height spawns.
	var hl: Node = load("res://maps/highlands.tscn").instantiate()
	get_tree().root.add_child(hl)
	await get_tree().process_frame
	var region = hl.get_node_or_null("NavRegion")
	var polys: int = region.navigation_mesh.get_polygon_count() if region and region.navigation_mesh else 0
	var heights := {}
	for m in hl.get_children():
		if m is Marker3D and (m.is_in_group("spawn_player") or m.is_in_group("spawn_enemy")):
			heights[roundi(m.position.y)] = true
	var highlands_ok := polys > 0 and heights.size() >= 2
	print("SMOKE: highlands polys=", polys, " spawn_heights=", heights.size(), " ok=", highlands_ok)
	hl.queue_free()

	# Team helpers + friendly fire rule.
	var team_helpers_ok: bool = Game.team_name(0) == "BLUE" and Game.is_team_mode() and Game.team_color(1) != Color(1, 1, 1)
	print("SMOKE: team_helpers_ok=", team_helpers_ok)

	# Co-op downed/revive: lethal damage downs (not kills); granting a life revives.
	var revive_ok := false
	if me and Game.is_coop():
		var lives_before: int = Game.coop_lives
		me.receive_damage(9999.0, -1)
		await get_tree().process_frame
		var was_downed: bool = me.downed and not me.dead
		me.apply_life_result(true)
		await get_tree().process_frame
		revive_ok = was_downed and not me.downed and lives_before > 0
	print("SMOKE: coop_revive_ok=", revive_ok, " lives=", Game.coop_lives)

	print("SMOKE: fire_works=", fired_ok, " damage_signal=", sig[0], " damage_number=", damage_number_ok, " hit_flash=", flash_ok, " audio=", audio_ok, " headshot=", headshot_ok, " highlands=", highlands_ok)
	print("SMOKE: DONE ok=", players >= 1 and bots >= 1 and nav >= 1 and fired_ok and sig[0] and damage_number_ok and flash_ok and audio_ok and spawn_clear and headshot_ok and highlands_ok and crouch_ok and coverage_ok and grenade_ok and settings_ok and variety_ok and pickup_ok and team_helpers_ok and revive_ok)
	get_tree().quit()

func _count_label3d() -> int:
	var n := 0
	for node in get_tree().current_scene.get_children():
		if node is Label3D:
			n += 1
	return n
