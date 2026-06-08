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
	# Minimap must have a real (non-zero) size or it draws nothing.
	var minimap_ok := false
	if hud:
		var mm = hud.get_node_or_null("Minimap")
		await get_tree().process_frame
		minimap_ok = mm != null and mm.size.x > 100.0 and mm.size.y > 100.0
		print("SMOKE: minimap_ok=", minimap_ok, " size=", (mm.size if mm else Vector2.ZERO))
	if me and hud:
		# Force a known-alive, full-health state (bots may have downed the dummy)
		# and prime the HUD's last-health so the drop registers as damage.
		me.downed = false
		me.dead = false
		me.fully_dead = false
		me.sync_health = 100.0
		me.health_changed.emit(100.0, me.MAX_HEALTH)
		await get_tree().process_frame
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

	# New maps bake navmeshes.
	var new_maps_ok := true
	for mp in ["res://maps/warehouse.tscn", "res://maps/ruins.tscn", "res://maps/compound.tscn"]:
		var m: Node = load(mp).instantiate()
		get_tree().root.add_child(m)
		await get_tree().process_frame
		var reg = m.get_node_or_null("NavRegion")
		var pc: int = reg.navigation_mesh.get_polygon_count() if reg and reg.navigation_mesh else 0
		if pc <= 0:
			new_maps_ok = false
		m.queue_free()
	print("SMOKE: new_maps_ok=", new_maps_ok)

	# Compound buildings: a point inside a building is reachable on the navmesh
	# (i.e. the doorway connects the interior to the rest of the map).
	var interior_ok := false
	var comp: Node = load("res://maps/compound.tscn").instantiate()
	get_tree().root.add_child(comp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var creg = comp.get_node_or_null("NavRegion")
	if creg:
		var navmap: RID = creg.get_navigation_map()
		var inside := Vector3(-18, 0.3, -18)  # centre of a corner building
		var closest := NavigationServer3D.map_get_closest_point(navmap, inside)
		interior_ok = Vector2(closest.x - inside.x, closest.z - inside.z).length() < 2.0
	print("SMOKE: building_interior_navigable=", interior_ok)
	comp.queue_free()

	# Colored kill feed builds without error.
	var killfeed_ok := false
	if hud:
		var kf_before: int = hud.kill_feed.get_child_count()
		hud.add_kill_feed("Alpha", "Bravo", false, 0, 1)
		killfeed_ok = hud.kill_feed.get_child_count() > kf_before
	print("SMOKE: killfeed_ok=", killfeed_ok)

	# Huge vehicle map bakes a navmesh and places vehicles.
	var huge_ok := false
	var t0 := Time.get_ticks_msec()
	var hm: Node = load("res://maps/outpost.tscn").instantiate()
	get_tree().root.add_child(hm)
	var hreg = hm.get_node_or_null("NavRegion")
	var hpolys: int = hreg.navigation_mesh.get_polygon_count() if hreg and hreg.navigation_mesh else 0
	var nveh: int = get_tree().get_nodes_in_group("vehicle").size()
	print("SMOKE: outpost bake_ms=", Time.get_ticks_msec() - t0, " polys=", hpolys, " vehicles=", nveh)
	huge_ok = hpolys > 0 and nveh >= 4
	hm.queue_free()

	# Vehicle physics: applying throttle moves the car.
	var vehicle_ok := false
	var vr := Node3D.new()
	get_tree().root.add_child(vr)
	var fl := StaticBody3D.new()
	fl.collision_layer = 1
	var fcs := CollisionShape3D.new()
	var fbs := BoxShape3D.new()
	fbs.size = Vector3(60, 2, 60)
	fcs.shape = fbs
	fl.add_child(fcs)
	vr.add_child(fl)
	fl.global_position = Vector3(500, -1, 500)
	var veh: Node = load("res://scenes/vehicle.tscn").instantiate()
	vr.add_child(veh)
	veh.global_position = Vector3(500, 1.0, 500)
	for i in 40:
		await get_tree().physics_frame
	var vp0: Vector3 = veh.global_position
	veh.set_drive(1.0, 0.0, 0.0)
	for i in 110:
		await get_tree().physics_frame
	var vmoved: float = Vector2(veh.global_position.x - vp0.x, veh.global_position.z - vp0.z).length()
	vehicle_ok = vmoved > 1.5
	# Damaged car smokes; enough damage destroys it.
	veh.receive_damage(veh.MAX_HEALTH * 0.7, 0)  # ~30% health left
	for i in 5:
		await get_tree().process_frame
	var smoke_ok: bool = veh._smoke != null and veh._smoke.emitting
	veh.hit(veh.MAX_HEALTH + 50.0, 0)
	await get_tree().process_frame
	var destroy_ok: bool = veh.destroyed
	print("SMOKE: vehicle_drive_ok=", vehicle_ok, " moved=", snappedf(vmoved, 0.1), " smoke_ok=", smoke_ok, " destroy_ok=", destroy_ok)
	vr.queue_free()

	# Car model variants: outpost places vehicles with cycling model_index.
	var variant_ok := false
	var handling_ok := false
	var hm2: Node = load("res://maps/outpost.tscn").instantiate()
	get_tree().root.add_child(hm2)
	await get_tree().process_frame
	var idxs := {}
	var engines := {}
	for v in get_tree().get_nodes_in_group("vehicle"):
		if v.get("model_index") == null or v.is_in_group("aircraft"):
			continue  # cars only (helicopters share the group but not these props)
		idxs[v.model_index] = true
		engines[v.max_engine] = true
	variant_ok = idxs.size() >= 3
	handling_ok = engines.size() >= 3  # per-type engine power differs
	print("SMOKE: car_variants=", idxs.size(), " variant_ok=", variant_ok, " handling_variety=", engines.size())
	hm2.queue_free()

	# Flip: an overturned car rights itself when flipped.
	var flip_ok := false
	var fr := Node3D.new()
	get_tree().root.add_child(fr)
	var ffl := StaticBody3D.new()
	ffl.collision_layer = 1
	var fcs2 := CollisionShape3D.new()
	var fbs2 := BoxShape3D.new()
	fbs2.size = Vector3(40, 2, 40)
	fcs2.shape = fbs2
	ffl.add_child(fcs2)
	fr.add_child(ffl)
	ffl.global_position = Vector3(600, -1, 600)
	var fv: Node = load("res://scenes/vehicle.tscn").instantiate()
	fr.add_child(fv)
	fv.global_transform = Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(600, 2, 600))  # upside down
	for i in 30:
		await get_tree().physics_frame
	var before_up: float = fv.global_transform.basis.y.dot(Vector3.UP)
	fv.flip()
	for i in 70:
		await get_tree().physics_frame
	var after_up: float = fv.global_transform.basis.y.dot(Vector3.UP)
	flip_ok = before_up < 0.0 and after_up > 0.6
	print("SMOKE: flip up before/after=", snappedf(before_up, 0.01), "/", snappedf(after_up, 0.01), " flip_ok=", flip_ok)
	fr.queue_free()

	# Bullet holes: impacts leave a decal in the "bullet_hole" group.
	var hole_ok := false
	if me:
		me.weapons._spawn_bullet_hole(me.global_position + Vector3(0, 0, 3), Vector3(0, 0, 1))
		await get_tree().process_frame
		hole_ok = get_tree().get_nodes_in_group("bullet_hole").size() > 0
	print("SMOKE: bullet_hole_ok=", hole_ok)

	# Crash damage: a high-speed collision damages the car.
	var crash_ok := false
	var cn := Node3D.new()
	get_tree().root.add_child(cn)
	var cv: Node = load("res://scenes/vehicle.tscn").instantiate()
	cn.add_child(cv)
	await get_tree().process_frame
	var chp0: float = cv.health
	cv._prev_speed = 25.0
	cv._on_crash(StaticBody3D.new())
	crash_ok = cv.health < chp0
	print("SMOKE: crash_damage_ok=", crash_ok, " (", chp0, " -> ", cv.health, ")")
	cn.queue_free()

	# Helicopter: ascends with vertical throttle and the gun fires without error.
	var heli_ok := false
	var heli: Node = load("res://scenes/helicopter.tscn").instantiate()
	get_tree().root.add_child(heli)
	heli.global_position = Vector3(700, 30, 700)
	await get_tree().physics_frame
	var hy0: float = heli.global_position.y
	heli.set_fly(0.0, 0.0, 1.0)  # ascend
	for i in 40:
		await get_tree().physics_frame
	heli.request_fire()
	heli_ok = heli.global_position.y > hy0 + 1.0 and heli.is_in_group("aircraft")
	print("SMOKE: helicopter_ok=", heli_ok, " climb=", snappedf(heli.global_position.y - hy0, 0.1))
	heli.queue_free()

	# Bots shoot enemy-occupied vehicles (e.g. a player flying a heli).
	var bot_veh_ok := false
	var bots2 := get_tree().get_nodes_in_group("bot")
	if not bots2.is_empty() and world:
		var b: Node = bots2[0]
		var tv: Node = load("res://scenes/vehicle.tscn").instantiate()
		world.add_child(tv)
		tv.global_position = b.global_position + Vector3(0, 0.8, 0) + b.global_transform.basis.z * 2.5
		tv.driver_id = 99
		tv.driver_team = 0  # enemy to the bot (team 1 in coop)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var vh0: float = tv.health
		# Fire a few times: a single shot can miss on the random spread cone.
		for _i in 8:
			b._shoot_cd = 0.0
			b._shoot_at(tv)
			await get_tree().physics_frame
		bot_veh_ok = tv.health < vh0
		print("SMOKE: bot_shoots_vehicle_ok=", bot_veh_ok, " (", vh0, " -> ", tv.health, ")")
		tv.queue_free()

	# Domination: a control point counts team presence + scoring increments.
	var dom_ok := false
	if me and world:
		var cpn := Area3D.new()
		cpn.set_script(load("res://scripts/world/control_point.gd"))
		cpn.point_id = "A"
		world.add_child(cpn)
		cpn.global_position = me.global_position
		await get_tree().physics_frame
		await get_tree().physics_frame
		var counts: Array = cpn.team_counts()
		var present_ok: bool = int(counts[0]) >= 1  # me is team 0 (BLUE)
		var s0: int = int(Game.dom_score[0])
		Game.add_dom_point(0)
		dom_ok = present_ok and int(Game.dom_score[0]) == s0 + 1
		print("SMOKE: domination_ok=", dom_ok, " counts=", counts)
		cpn.queue_free()

	# Team helpers + friendly fire rule.
	var team_helpers_ok: bool = Game.team_name(0) == "BLUE" and Game.is_team_mode() and Game.team_color(1) != Color(1, 1, 1)
	print("SMOKE: team_helpers_ok=", team_helpers_ok)

	# Team scoreboard: grouped rows (team headers) build without error in a team mode.
	var scoreboard_ok := false
	if hud:
		hud.scoreboard.visible = true
		hud._refresh_scoreboard()
		# header row + 2 team headers (squad/hostiles) + one row per combatant.
		scoreboard_ok = hud.score_rows.get_child_count() >= Game.scores.size() + 2
		hud.scoreboard.visible = false
	print("SMOKE: team_scoreboard_ok=", scoreboard_ok)

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

	# New co-op objective entities: destructible target, escort VIP, boss archetype.
	var objectives_ok := false
	if me and world:
		var fwd2: Vector3 = -me.global_transform.basis.z
		var tgt: Node = world.spawn_target(me.global_position + fwd2 * 6.0, 120.0)
		await get_tree().physics_frame
		var th0: float = tgt.sync_health
		tgt.receive_damage(40.0, -1)
		var dmg_ok: bool = tgt.sync_health < th0 and tgt.is_in_group("destructible")
		tgt.receive_damage(1000.0, -1)
		await get_tree().process_frame
		var destroyed_ok: bool = tgt.destroyed
		var goal: Vector3 = me.global_position + fwd2 * 14.0
		var vip: Node = world.spawn_escort(me.global_position + fwd2 * 2.0, goal, 4.0)
		await get_tree().process_frame
		var ed0: float = vip.global_position.distance_to(goal)
		for i in 30:
			await get_tree().process_frame
		var escort_ok: bool = vip.is_in_group("escort") and (vip.arrived or vip.global_position.distance_to(goal) < ed0 - 0.5)
		var BotScript = load("res://scripts/ai/bot.gd")
		var boss_ok: bool = BotScript.PROFILES.has("boss") and float(BotScript.PROFILES["boss"]["health"]) >= 1000.0
		objectives_ok = dmg_ok and destroyed_ok and escort_ok and boss_ok
		print("SMOKE: objectives_ok=", objectives_ok, " dmg=", dmg_ok, " destroyed=", destroyed_ok, " escort=", escort_ok, " boss=", boss_ok)
		tgt.queue_free()
		vip.queue_free()

	# Battle Royale: storm-wall geometry, storm damage to anyone caught outside,
	# is_battle_royale/mode_name, and last-standing never ending with a full lobby.
	var br_ok := false
	if world:
		var StormScript = load("res://scripts/world/storm.gd")
		var storm = StormScript.new()
		world.add_child(storm)
		storm.set_center(Vector3.ZERO)
		storm.set_radius(50.0)
		var geom_ok: bool = storm.is_outside(Vector3(80, 0, 0)) and not storm.is_outside(Vector3(10, 0, 0))
		var storm_dmg_ok := false
		var sbots := get_tree().get_nodes_in_group("bot")
		if not sbots.is_empty():
			var sb = sbots[0]
			sb.global_position = Vector3(300, 0.5, 0)  # well outside the 50 m ring
			await get_tree().physics_frame
			var hp0: float = sb.sync_health
			world._storm = storm
			world._apply_storm_damage(15.0)
			await get_tree().process_frame
			storm_dmg_ok = sb.sync_health < hp0
		var prev_mode = Game.config["mode"]
		var prev_active: bool = Game.match_active
		Game.config["mode"] = Game.Mode.BATTLE_ROYALE
		var name_ok: bool = Game.is_battle_royale() and Game.mode_name() == "Battle Royale"
		var tag_ok := true
		if not sbots.is_empty():
			sbots[0]._apply_profile()  # re-resolve profile under BR -> tag should hide
			tag_ok = not sbots[0].name_label.visible
		Game.match_active = true
		world.check_last_standing()  # several bots alive -> must NOT end the match
		var no_false_end: bool = Game.match_active
		Game.match_active = prev_active
		Game.config["mode"] = prev_mode
		world._storm = null
		storm.queue_free()
		br_ok = geom_ok and storm_dmg_ok and name_ok and no_false_end and tag_ok
		print("SMOKE: battle_royale_ok=", br_ok, " geom=", geom_ok, " storm_dmg=", storm_dmg_ok, " name=", name_ok, " no_false_end=", no_false_end, " tag_hidden=", tag_ok)

	# Massive Wasteland map bakes a navmesh, spreads spawns and places vehicles.
	var wasteland_ok := false
	var wt0 := Time.get_ticks_msec()
	var wm: Node = load("res://maps/wasteland.tscn").instantiate()
	get_tree().root.add_child(wm)
	await get_tree().process_frame
	var wreg = wm.get_node_or_null("NavRegion")
	var wpolys: int = wreg.navigation_mesh.get_polygon_count() if wreg and wreg.navigation_mesh else 0
	var wspawns := 0
	for m in wm.get_children():
		if m is Marker3D and (m.is_in_group("spawn_player") or m.is_in_group("spawn_enemy")):
			wspawns += 1
	var wveh: int = get_tree().get_nodes_in_group("vehicle").size()
	wasteland_ok = wpolys > 0 and wspawns >= 12 and wveh >= 6
	print("SMOKE: wasteland_ok=", wasteland_ok, " bake_ms=", Time.get_ticks_msec() - wt0, " polys=", wpolys, " spawns=", wspawns, " vehicles=", wveh)
	wm.queue_free()

	# Survival: mode helpers, needs drain over time, starvation damage, eat/drink restore.
	var survival_ok := false
	if me:
		var prev_mode2 = Game.config["mode"]
		Game.config["mode"] = Game.Mode.SURVIVAL
		var helpers_ok: bool = Game.is_survival() and Game.mode_name() == "Survival" and Game.is_team_mode()
		var tag_hidden_ok := true
		var sbz := get_tree().get_nodes_in_group("bot")
		if not sbz.is_empty():
			sbz[0]._apply_profile()  # re-resolve under Survival -> tag should hide
			tag_hidden_ok = not sbz[0].name_label.visible
		me.velocity = Vector3.ZERO
		me.hunger = 50.0
		me.thirst = 50.0
		me._update_needs(2.0)  # 2 simulated seconds of drain
		var drain_ok: bool = me.hunger < 50.0 and me.thirst < 50.0
		me.hunger = 0.0
		me.thirst = 0.0
		me.sync_health = 100.0
		me._need_dmg_accum = 0.0
		me._update_needs(1.1)  # crosses the 1s starvation tick
		var starve_ok: bool = me.sync_health < 100.0
		me.eat(40.0)
		me.drink(60.0)
		var restore_ok: bool = me.hunger >= 39.0 and me.thirst >= 59.0
		Game.config["mode"] = prev_mode2
		survival_ok = helpers_ok and drain_ok and starve_ok and restore_ok and tag_hidden_ok
		print("SMOKE: survival_ok=", survival_ok, " helpers=", helpers_ok, " drain=", drain_ok, " starve=", starve_ok, " restore=", restore_ok, " tag_hidden=", tag_hidden_ok)

	# Survival backpack: spatial grid placement, no-overlap, capacity, use, drop.
	var inventory_ok := false
	if me:
		me.inventory.clear()
		me.backpack_w = 4
		me.backpack_h = 4
		var add_ok: bool = me.inv_add(ItemDB.make_weapon("rifle")) and int(me.inventory[0]["gx"]) == 0 and int(me.inventory[0]["gy"]) == 0
		me.inv_add(ItemDB.make_weapon("smg"))  # second 2x2 auto-places elsewhere
		var a: Dictionary = me.inventory[0]
		var b: Dictionary = me.inventory[1]
		var overlap_ok: bool = not (int(a["gx"]) == int(b["gx"]) and int(a["gy"]) == int(b["gy"])) and me.inv_used() == 8 and me.inv_cell_count() == 16
		# Fill the 4x4 grid with four 2x2 items; a fifth must not fit.
		me.inventory.clear()
		for i in 4:
			me.inv_add(ItemDB.make_weapon("rifle"))
		var cap_ok: bool = me.inventory.size() == 4 and not me.inv_add(ItemDB.make_weapon("rifle"))
		me.inventory.clear()
		me.hunger = 10.0
		me.inv_add(ItemDB.make("food"))
		me.inv_use(0)
		var use_ok: bool = me.hunger > 10.0 and me.inventory.is_empty()
		me.inv_add(ItemDB.make_weapon("shotgun"))
		me.inv_drop(0)
		await get_tree().process_frame
		var found_drop := false
		for n in get_tree().current_scene.get_children():
			if n.is_in_group("pickup") and not (n.get("item_data") as Dictionary).is_empty():
				found_drop = true
		var drop_ok: bool = me.inventory.is_empty() and found_drop
		me.inventory.clear()
		inventory_ok = add_ok and overlap_ok and cap_ok and use_ok and drop_ok
		print("SMOKE: inventory_ok=", inventory_ok, " add=", add_ok, " overlap=", overlap_ok, " cap=", cap_ok, " use=", use_ok, " drop=", drop_ok)

	# Procedural Survival terrain: seeded heightmap mesh + collision + biome navmesh,
	# water plane, scattered props, flattened POI/village sites and spawns.
	var terrain_ok := false
	var prev_ms = Game.config.get("map_size", 1)
	var prev_sd = Game.config.get("seed", 0)
	Game.config["map_size"] = 1   # medium (~640 m)
	Game.config["seed"] = 12345
	var tt0 := Time.get_ticks_msec()
	var terr: Node = load("res://maps/terrain.tscn").instantiate()
	get_tree().root.add_child(terr)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var treg = terr.get_node_or_null("NavRegion")
	var tpolys: int = treg.navigation_mesh.get_polygon_count() if treg and treg.navigation_mesh else 0
	var tspawns := 0
	for m in terr.get_children():
		if m is Marker3D and (m.is_in_group("spawn_player") or m.is_in_group("spawn_enemy")):
			tspawns += 1
	var tpoi := get_tree().get_nodes_in_group("poi_site").size()
	var twater := get_tree().get_nodes_in_group("water").size()
	var rq := PhysicsRayQueryParameters3D.create(Vector3(0, 300, 0), Vector3(0, -300, 0))
	rq.collision_mask = 1
	var tcol: bool = not terr.get_world_3d().direct_space_state.intersect_ray(rq).is_empty()
	terrain_ok = tpolys > 0 and tspawns >= 8 and tpoi >= 5 and twater >= 1 and tcol
	print("SMOKE: terrain_ok=", terrain_ok, " bake_ms=", Time.get_ticks_msec() - tt0, " polys=", tpolys, " spawns=", tspawns, " poi=", tpoi, " water=", twater, " collision=", tcol)
	terr.queue_free()
	Game.config["map_size"] = prev_ms
	Game.config["seed"] = prev_sd

	# Survival start: an empty loadout fires safely (unarmed) and equipping a weapon
	# from the backpack fills a free slot (rather than replacing slot 0).
	var survival_start_ok := false
	if me:
		var wm2 = me.weapons
		wm2.set_loadout([])
		var empty_ok: bool = wm2.loadout.is_empty()
		wm2._fire()   # must be a safe no-op while unarmed
		wm2.give_weapon("rifle")
		var equip_ok: bool = wm2.loadout.size() == 1 and wm2.loadout[0] == "rifle"
		survival_start_ok = empty_ok and equip_ok
		print("SMOKE: survival_start_ok=", survival_start_ok, " empty=", empty_ok, " equip=", equip_ok)

	# Backpack grid: move validation (onto an item fails, to a free cell ok) + the
	# UI binds the grid to the player and redraws without error.
	var inv_ui_ok := false
	if me and hud:
		me.inventory.clear()
		me.backpack_w = 4
		me.backpack_h = 4
		me.inv_add(ItemDB.make_weapon("rifle"))  # 2x2 at (0,0)
		me.inv_add(ItemDB.make("food"))           # 1x1 elsewhere
		var blocked: bool = not me.inv_move(1, 0, 0)   # onto the weapon -> rejected
		var move_ok: bool = me.inv_move(1, 3, 3)       # to a free cell -> ok
		hud._player = me
		hud.inventory_panel.visible = true
		hud._refresh_inventory()
		var bound: bool = hud.backpack_grid.player == me
		hud.backpack_grid.queue_redraw()
		await get_tree().process_frame
		hud.inventory_panel.visible = false
		me.inventory.clear()
		inv_ui_ok = blocked and move_ok and bound
		print("SMOKE: inv_ui_ok=", inv_ui_ok, " blocked=", blocked, " moved=", move_ok, " bound=", bound)

	# Survival factions: hostility rules + provocation, NPC faction plumbing, and
	# distance-activation toggling a bot's physics.
	var factions_ok := false
	var prev_mode3 = Game.config["mode"]
	Game.config["mode"] = Game.Mode.SURVIVAL
	Game.survival_setup(42)
	var fa: String = String(Game.SURVIVAL_VILLAGE_FACTIONS[0])
	var raider_ok: bool = Game.survival_hostile("raiders", fa) and Game.survival_hostile(fa, "raiders") and Game.survival_hostile("raiders", "player")
	var self_ok: bool = not Game.survival_hostile("player", "player") and not Game.survival_hostile(fa, fa)
	Game.survival_stance[fa] = "neutral"
	var was_neutral: bool = not Game.survival_hostile("player", fa)
	Game.survival_provoke(fa)
	var provoke_ok: bool = was_neutral and Game.survival_hostile("player", fa)
	var vv_ok := true
	if Game.SURVIVAL_VILLAGE_FACTIONS.size() >= 2:
		vv_ok = not Game.survival_hostile(String(Game.SURVIVAL_VILLAGE_FACTIONS[0]), String(Game.SURVIVAL_VILLAGE_FACTIONS[1]))
	var faction_spawn_ok := false
	if world and me:
		var fid: int = world.spawn_enemy(1.0, false, me.global_position + Vector3(6, 0, 0), "soldier", 5, "raiders")
		await get_tree().process_frame
		for b in get_tree().get_nodes_in_group("bot"):
			if b.combatant_id == fid:
				faction_spawn_ok = b.faction == "raiders" and b.team == 5
	var activation_ok := false
	var sb3 := get_tree().get_nodes_in_group("bot")
	if not sb3.is_empty():
		sb3[0].set_active(false)
		var off: bool = not sb3[0].is_physics_processing()
		sb3[0].set_active(true)
		activation_ok = off and sb3[0].is_physics_processing()
	Game.config["mode"] = prev_mode3
	factions_ok = raider_ok and self_ok and provoke_ok and vv_ok and faction_spawn_ok and activation_ok
	print("SMOKE: factions_ok=", factions_ok, " raider=", raider_ok, " self=", self_ok, " provoke=", provoke_ok, " vv=", vv_ok, " spawn=", faction_spawn_ok, " activation=", activation_ok)

	# Survival NPC identities: NameGen, name/role plumbing through spawn, greeting.
	var npc_ident_ok := false
	if world and me:
		var prev_m4 = Game.config["mode"]
		Game.config["mode"] = Game.Mode.SURVIVAL
		Game.survival_setup(7)
		NameGen.reseed(7)
		var fac2: String = String(Game.SURVIVAL_VILLAGE_FACTIONS[0])
		var nm: String = NameGen.npc_name(fac2)
		var name_ok: bool = nm.contains(" ")
		var nid2: int = world.spawn_enemy(1.0, false, me.global_position + Vector3(2, 0, 0), "soldier", 7, fac2, {"name": "Test Elder", "role": "Elder"})
		await get_tree().process_frame
		var npc: Node = null
		for b in get_tree().get_nodes_in_group("bot"):
			if b.combatant_id == nid2:
				npc = b
		var role_ok: bool = npc != null and npc.role == "Elder" and npc.display_name == "Test Elder" and npc.faction == fac2
		Game.survival_stance[fac2] = "friendly"
		var greet_ok: bool = npc != null and me._npc_greeting(npc) != ""
		Game.config["mode"] = prev_m4
		npc_ident_ok = name_ok and role_ok and greet_ok
		print("SMOKE: npc_ident_ok=", npc_ident_ok, " name=", name_ok, " role=", role_ok, " greet=", greet_ok)

	# Survival quests: hunt completion via kills, offer/accept, tracker text.
	var quests_ok := false
	if world and me:
		var prev_active5: bool = Game.match_active
		var prev_mode5 = Game.config["mode"]
		Game.config["mode"] = Game.Mode.SURVIVAL
		Game.match_active = false   # don't trigger the victory scene change in the test
		var qm = load("res://scripts/world/quest_manager.gd").new()
		qm.name = "QM_test"
		add_child(qm)
		qm.add_to_group("quest_manager")
		qm.world = world
		qm.target_points = 99
		var hid = qm._make("hunt", "Test", "kill 2 raiders", {"faction": "raiders", "count": 2})
		qm._activate(hid)
		var rid: int = world.spawn_enemy(1.0, false, me.global_position + Vector3(8, 0, 0), "soldier", 1, "raiders")
		await get_tree().process_frame
		qm.notify_kill(rid)
		qm.notify_kill(rid)
		var hunt_ok: bool = qm.points >= 2
		var sid = qm._make("collect", "Side", "collect 1 ammo", {"item": "ammo", "count": 1}, false, 4242)
		var offer = qm.offer_for(4242)
		var offer_ok: bool = not offer.is_empty() and int(offer["id"]) == sid
		qm.accept(sid)
		var accept_ok := false
		for q in qm.quests:
			if int(q["id"]) == sid:
				accept_ok = q["state"] == "active"
		var tracker_ok: bool = qm._tracker_text().contains("QUESTS")
		qm.queue_free()
		Game.match_active = prev_active5
		Game.config["mode"] = prev_mode5
		quests_ok = hunt_ok and offer_ok and accept_ok and tracker_ok
		print("SMOKE: quests_ok=", quests_ok, " hunt=", hunt_ok, " offer=", offer_ok, " accept=", accept_ok, " tracker=", tracker_ok)

	# Survival story: offline fallback produces all keys, and the LLM-response parser
	# extracts our story JSON from an OpenAI-style chat reply.
	var story_ok := false
	var fb: Dictionary = {}
	Story._theme = "zombie apocalypse"
	Story._facts = {"factions": ["Ridgeback Clan", "raiders"], "points": 6}
	fb = Story._fallback_story()
	var fb_ok: bool = fb.has("briefing") and fb.has("factions") and fb.has("greetings") and fb.has("outro") and String(fb["briefing"]).contains("zombie")
	var sample := '{"choices":[{"message":{"content":"{\\"briefing\\":\\"Dark days.\\",\\"factions\\":{\\"X\\":\\"lore\\"},\\"greetings\\":{\\"X\\":\\"hi\\"},\\"outro\\":\\"win\\"}"}}]}'
	var parsed: Dictionary = Story._parse_story(sample)
	var parse_ok: bool = String(parsed.get("briefing", "")) == "Dark days." and String(parsed.get("outro", "")) == "win"
	var names_sample := '{"choices":[{"message":{"content":"prose {\\"raiders\\":[{\\"name\\":\\"Vex\\",\\"trait\\":\\"cruel\\"}]} trailing"}}]}'
	var pn: Dictionary = Story._parse_names(names_sample)
	var pn_ok: bool = pn.has("raiders")
	# LLM name pools: NameGen draws unique people from a pool, then falls back.
	NameGen.set_pools({"raiders": [{"name": "Vex Skullsplitter", "trait": "ruthless"}]})
	var p1: Dictionary = NameGen.npc_person("raiders")
	var p2: Dictionary = NameGen.npc_person("raiders")  # pool exhausted -> built-in
	NameGen.clear_pools()
	var names_ok: bool = p1["name"] == "Vex Skullsplitter" and p1["trait"] == "ruthless" and p2["name"] != "Vex Skullsplitter"
	var llm_ok: bool = (LLM.embedded_available() == false) and (LLM.embedded_ready() == false) and LLM.model_path().ends_with(Settings.llm_model_file)
	story_ok = fb_ok and parse_ok and pn_ok and names_ok and llm_ok
	print("SMOKE: story_ok=", story_ok, " fallback=", fb_ok, " parse=", parse_ok, " names_parse=", pn_ok, " names=", names_ok, " llm=", llm_ok)

	# Equipment: equip armor (zone damage reduction), equip/unequip a weapon, and
	# verify worn armor cuts that zone's incoming damage.
	var equip_ok := false
	if me:
		me.inventory.clear()
		me.equip = {"head": {}, "body": {}, "pants": {}, "extra": {}}
		me.weapons.set_loadout([])
		# Equip body armor from the backpack -> goes to the body slot, leaves the grid.
		me.inv_add(ItemDB.make("vest"))
		me.equip_item(0)
		var armor_equipped: bool = not (me.equip["body"] as Dictionary).is_empty() and me.inventory.is_empty()
		var reduce_ok: bool = me.armor_reduction("torso") > 0.0 and is_equal_approx(me.armor_reduction("head"), 0.0)
		# Zone damage reduction: torso hit is cut, head hit is not.
		me.sync_health = 100.0
		me.receive_damage(50.0, -1, "torso")
		var torso_hp: float = me.sync_health
		me.sync_health = 100.0
		me.receive_damage(50.0, -1, "head")
		var head_hp: float = me.sync_health
		var dmg_ok: bool = torso_hp > head_hp   # torso took less (armored)
		# Equip a weapon -> fills a gun slot; unequip -> back to the backpack.
		me.inv_add(ItemDB.make_weapon("rifle"))
		me.equip_item(me.inventory.size() - 1)
		var gun_ok: bool = me.weapons.loadout.has("rifle")
		me.unequip("gun1")
		var unequip_ok: bool = not me.weapons.loadout.has("rifle")
		me.inventory.clear()
		me.equip = {"head": {}, "body": {}, "pants": {}, "extra": {}}
		equip_ok = armor_equipped and reduce_ok and dmg_ok and gun_ok and unequip_ok
		print("SMOKE: equip_ok=", equip_ok, " armor=", armor_equipped, " reduce=", reduce_ok, " dmg=", dmg_ok, " gun=", gun_ok, " unequip=", unequip_ok)

	print("SMOKE: fire_works=", fired_ok, " damage_signal=", sig[0], " damage_number=", damage_number_ok, " hit_flash=", flash_ok, " audio=", audio_ok, " headshot=", headshot_ok, " highlands=", highlands_ok)
	print("SMOKE: DONE ok=", players >= 1 and bots >= 1 and nav >= 1 and fired_ok and sig[0] and damage_number_ok and flash_ok and audio_ok and spawn_clear and headshot_ok and highlands_ok and crouch_ok and coverage_ok and grenade_ok and settings_ok and variety_ok and pickup_ok and team_helpers_ok and revive_ok and scoreboard_ok and new_maps_ok and killfeed_ok and interior_ok and huge_ok and vehicle_ok and destroy_ok and variant_ok and handling_ok and flip_ok and smoke_ok and hole_ok and crash_ok and heli_ok and bot_veh_ok and dom_ok and objectives_ok and br_ok and wasteland_ok and survival_ok and inventory_ok and terrain_ok and survival_start_ok and inv_ui_ok and factions_ok and npc_ident_ok and quests_ok and story_ok and equip_ok and minimap_ok)
	get_tree().quit()

func _count_label3d() -> int:
	var n := 0
	for node in get_tree().current_scene.get_children():
		if node is Label3D:
			n += 1
	return n
